;; bfly-socket.lisp
;; --------------------------------------------------------------------------------------
;; Butterfly -- a system for easy distributed computing, going beyond what is available
;; in Erlang with the full power of Common Lisp.
;;
;; Copyright (C) 2008,2009 by Refined Audiometrics Laboratory, LLC. All rights reserved.
;;
;; DM/SD  08/08, 06-12/09
;; --------------------------------------------------------------------------------------

(in-package #:actors.network)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(um:if-let
            um:when-let
            um:dlambda
            um:dlambda*
            um:dcase
            um:dcase*
            um:nlet
            um:nlet-tail
            um:mcapture-ans-or-exn
            
            actors.lfm:log-info
            actors.lfm:log-error

            actors.base:actor
            actors.base:become
            actors.base:inject-into-actor
            actors.base:perform-in-actor
            actors.base:recv
            actors.base:spawn-worker
            actors.base:with-as-current-actor
            actors.base:send
            actors.base:assemble-ask-message
            
            actors.directory:find-actor
            
            actors.security:secure-encoding
            actors.security:secure-decoding
            actors.security:insecure-decoding
            actors.security:client-crypto
            actors.security:server-crypto
            actors.security:unexpected
            actors.security:make-u8-vector
            actors.security:convert-vector-to-integer
            actors.security:+MAX-FRAGMENT-SIZE+
            actors.security:server-negotiate-security
            actors.security:client-negotiate-security

            actors.bridge:bridge-register
            actors.bridge:bridge-unregister
            actors.bridge:bridge-handle-reply
            actors.bridge:bridge-reset

            actors.lfm:ensure-system-logger
            
            cps:=bind
            cps:=wait
            cps:=values
            cps:=defun
            cps:=bind-cont
            cps:=wait-cont
            cps:with-cont
            cps:=flet
            cps:=cont
            cps:=apply

            ref:ref
            ref:cas
            ref:atomic-incf
            ref:atomic-decf
            ref:atomic-exch
            )))

;; -----------------------------------------------------------------------

(defvar *default-port*            65001)
(defvar *socket-timeout-period*   60)
(defvar *ws-collection*           nil)
(defvar *aio-accepting-handle*    nil)

;; -------------------------------------------------------------
;; For link debugging...

(defvar *watch-input*  nil)
(defvar *watch-output* nil)

(defun watch-io (t/f)
  (setf *watch-input*  t/f
        *watch-output* t/f))

(defun watch-input (data)
  (when *watch-input*
    (let ((*watch-input* nil)) ;; in case logging is remote
      (log-info :SYSTEM-LOG (format nil "INP: ~A" data)))))

(defun watch-output (data)
  (when *watch-output*
    (let ((*watch-output* nil)) ;; in case logging is remote
      (log-info :SYSTEM-LOG (format nil "OUT: ~A" data)))))

;; -------------------------------------------------------------
;; Channel Handler
;; ----------------------------------------------------------------

(defstruct queue
  hd tl)

(defun push-queue (queue item)
  (let* ((cell     (queue-hd queue))
         (new-cell (cons item cell)))
    (setf (queue-hd queue) new-cell)
    (unless cell
      (setf (queue-tl queue) new-cell))
    ))

(defun add-queue (queue item)
  (let ((cell     (queue-tl queue))
        (new-cell (list item)))
    (if cell
        (setf (queue-tl queue)
              (setf (cdr cell) new-cell))
      ;; else
      (setf (queue-hd queue)
            (setf (queue-tl queue) new-cell))
      )))

(defun pop-queue (queue)
  (let ((cell (queue-hd queue)))
    (when cell
      (setf (queue-hd queue) (cdr cell))
      (when (eq cell (queue-tl queue))
          (setf (queue-tl queue) nil)))
    (values (car cell) cell)))

;; ----------------------------------------------------------------

(defmacro expect (intf &rest clauses)
  `(do-expect ,intf (make-expect-handler ,@clauses)))

(defmacro make-expect-handler (&rest clauses)
  `(dlambda*
     ,@clauses
     ,@(unless (find 't clauses
                     :key 'first)
         `((t (&rest msg)
              (unexpected msg)))
         )))
  
#+:LISPWORKS
(editor:setup-indent "expect" 1)

(defun become-null-monitor (name)
  (become (lambda (&rest msg)
            (log-info :SYSTEM-LOG
                      "Null Monitor ~A Msg: ~A" name msg))))

;; -------------------------------------------------------------------------

(defclass message-reader (actor)
  ((crypto     :initarg :crypto)
   (dispatcher :initarg :dispatcher)
   (queue      :initform (make-queue))
   (len-buf    :initform (make-u8-vector 4))
   (hmac-buf   :initform (make-u8-vector 32))))

(defmethod initialize-instance :after ((reader message-reader) &key &allow-other-keys)
  (with-slots (crypto dispatcher queue len-buf hmac-buf) reader
    (labels
        ((extract-bytes (buf start end)
           (nlet-tail iter ()
             (destructuring-bind
                 (&whole frag &optional frag-start frag-end . frag-bytes)
                 (pop-queue queue)
               (if frag
                   (let ((nb   (- frag-end frag-start))
                         (need (- end start)))
                     (cond
                      ((< nb need)
                       (when (plusp nb)
                         (replace buf frag-bytes
                                  :start1 start
                                  :start2 frag-start)
                         (incf start nb))
                       (iter))
                      
                      ((= nb need)
                       (when (plusp need)
                         (replace buf frag-bytes
                                  :start1 start
                                  :start2 frag-start))
                       end)
                      
                      (t ;; (> nb need)
                         (when (plusp need)
                           (replace buf frag-bytes
                                    :start1 start
                                    :start2 frag-start
                                    :end1   end)
                           (incf (car frag) need))
                         (push-queue queue frag)
                         end)
                      ))
                 ;; else
                 start)))))
      
      (=flet
          ((read-buf (buf)
             ;; incoming byte stuffer and buffer reader
             (let ((len (length buf)))
               (nlet rd-wait ((start 0))
                 (let ((pos (extract-bytes buf start len)))
                   (cond
                    ((= pos len)
                     (=values))
                    
                    (t
                     (recv ()
                       (actor-internal-message:rd-incoming (frag)
                          (add-queue queue frag)
                          (rd-wait pos))
                       
                       (actor-internal-message:rd-error ()
                          (become-null-monitor :rd-actor))
                       ))
                    )))
               )))
        
        ;; message asssembly and decoding from (len, payload, hmac)
        (with-as-current-actor reader
          (nlet read-next-message ()
            (=bind ()
                (read-buf len-buf)
              (let ((len (convert-vector-to-integer len-buf)))
                (if (> len +MAX-FRAGMENT-SIZE+)
                    ;; and we are done... just hang up.
                    (handle-message dispatcher '(actor-internal-message:discard))
                  ;; else
                  (let ((enc-buf  (make-u8-vector len)))
                    (=bind ()
                        (read-buf enc-buf)
                      (=bind ()
                          (read-buf hmac-buf)
                        (handle-message dispatcher (secure-decoding crypto len len-buf enc-buf hmac-buf))
                        (read-next-message))
                      ))
                  )))))))))

;; -------------------------------------------------------------------------

(defclass message-writer (actor)
  ((io-state      :initarg :io-state)
   (io-running    :initarg :io-running)
   (decr-io-count :initarg :decr-io-count)))

(defmethod write-message ((writer message-writer) buffers)
  (with-slots (io-state io-running decr-io-count) writer
    (labels
        ((we-are-done ()
           (become-null-monitor :wr-actor))
         
         (write-next-buffer (state &rest ignored)
           (declare (ignore ignored))
           (if-let (next-buffer (pop buffers))
               (comm:async-io-state-write-buffer state next-buffer #'write-next-buffer)
             (send writer (if (or (funcall decr-io-count state)
                                  (comm:async-io-state-write-status state))
                              'actor-internal-message:wr-fail
                            'actor-internal-message:wr-done)))))
      
      (perform-in-actor writer
        (cond
         ((cas io-running 1 2) ;; still running recieve?
          (write-next-buffer io-state)
          (recv ()
            (actor-internal-message:wr-done ())
            (actor-internal-message:wr-fail ()
                                            (we-are-done))
            ))
         (t
          (we-are-done))
         )))))

;; -------------------------------------------------------------------------

(defclass kill-timer (actor)
  (timer))

(defmethod initialize-instance :after ((kt kill-timer) &key timer-fn &allow-other-keys)
  (with-slots (timer) kt
    (setf timer (mp:make-timer timer-fn))))

(defmethod resched ((kt kill-timer))
  (with-slots (timer) kt
    (perform-in-actor kt
      (when timer
        (mp:schedule-timer-relative timer *socket-timeout-period*)))))

(defmethod discard ((kt kill-timer))
  (with-slots (timer) kt
    (perform-in-actor kt
      (when timer
        (mp:unschedule-timer timer)
        (setf timer nil)))))

;; ------------------------------------------------------------------------

(defclass message-dispatcher (actor)
  ((accum :initform nil)
   (kill-timer :initarg :kill-timer)
   (intf       :initarg :intf)
   (title      :initarg :title)
   (crypto     :initarg :crypto)))

(defmethod handle-message ((dispatcher message-dispatcher) whole-msg)
  (with-slots (accum kill-timer intf #|title|# crypto) dispatcher
    (resched kill-timer)
    (perform-in-actor dispatcher
      (dcase* whole-msg
        
        (actor-internal-message:discard (&rest msg)
          (declare (ignore msg))
          (shutdown intf))
        
        (actor-internal-message:frag (frag)
          (push frag accum))
        
        (actor-internal-message:last-frag (frag)
           (push frag accum)
           (handle-message dispatcher (insecure-decoding
                                       (apply 'concatenate 'vector
                                              (nreverse (shiftf accum nil))
                                              ))
                           ))
            
        (actor-internal-message:srp-node-id (node-id)
           ;; Client is requesting security negotiation
           (spawn-worker 'server-negotiate-security crypto intf node-id))

        (actor-internal-message:forwarding-send (service &rest msg)
           (if-let (actor (find-actor service))
               (apply 'send actor msg)
             (socket-send intf 'actor-internal-message:no-service service (machine-instance))))

        (actor-internal-message:no-service (service node)
           ;; sent to us on send to non-existent service
           (mp:funcall-async 'no-service-alert service node))
        
        (actor-internal-message:forwarding-ask (service id &rest msg)
           (=bind (&rest ans)
               (if-let (actor (find-actor service))                                    
                   (apply 'send actor (apply 'assemble-ask-message =bind-cont msg))
                 (=values (mcapture-ans-or-exn
                            (no-service-alert service (machine-instance)))))
             (apply 'socket-send intf 'actor-internal-message:forwarding-reply id ans)))
           
        (actor-internal-message:forwarding-reply (id &rest ans)
           (apply 'bridge-handle-reply id ans))

        (t (&rest msg)
           ;; other out-of-band messages
           #|
            (log-info :SYSTEM-LOG
                      "Incoming ~A Msg: ~A" title msg)
            |#
           (apply 'send intf 'actor-internal-message:incoming-msg msg))
        ))))

(defun no-service-alert (service node)
  (error "No Service ~A on Node ~A" service node))

;; ------------------------------------------------------------------------

(defclass socket-interface (actor)
  ((title    :initarg :title)
   (io-state :initarg :io-state)
   (crypto   :initarg :crypto)
   (srp-ph2-begin :reader intf-srp-ph2-begin)
   (srp-ph2-reply :reader intf-srp-ph2-reply)
   (srp-ph3-begin :reader intf-srp-ph3-begin)
   writer
   kill-timer
   (io-running :initform (ref 1))))

(defmethod do-expect ((intf socket-interface) handler)
  (perform-in-actor intf
    (recv ()
      (actor-internal-message:incoming-msg (&rest msg)
         (handler-bind ((error (lambda (err)
                                 (declare (ignore err))
                                 (log-error :SYSTEM-LOG "Expect Failure: ~A" msg)
                                 (shutdown intf))
                               ))
           (apply handler msg))
         ))))

(defmethod socket-send ((intf socket-interface) &rest msg)
  (with-slots (crypto writer kill-timer) intf
    (perform-in-actor intf
      (resched kill-timer)
      (write-message writer (secure-encoding crypto msg)))))

(defmethod shutdown ((intf socket-interface))
  ;; define as a Continuation to get past any active RECV
  (with-slots (kill-timer io-running io-state title) intf
    (inject-into-actor intf ;; as a continuation, preempting RECV filtering
      (discard kill-timer)
      (atomic-exch io-running 0)
      (comm:async-io-state-abort-and-close io-state)
      (bridge-unregister intf)
      (log-info :SYSTEM-LOG "Socket ~A shutting down: ~A" title intf)
      (become-null-monitor :socket-interface))))

(defmethod client-request-negotiation ((intf socket-interface) cont node-id)
  ;; Called by Client for crypto negotiation. Make it a continuation so
  ;; it can be initiated by message reader when deemed appropriate.
  (inject-into-actor intf
    (socket-send intf 'actor-internal-message:srp-node-id node-id)
    (expect intf
      (actor-internal-message:srp-phase2 (p-key g-key salt bb)
         (funcall cont p-key g-key salt bb))
      )))

(defmethod initialize-instance :after ((intf socket-interface) &key &allow-other-keys)
  (with-slots (title
               io-state
               crypto
               kill-timer
               writer
               io-running
               srp-ph2-begin
               srp-ph2-reply
               srp-ph3-begin) intf
    (with-as-current-actor intf ;; for =cont
      (flet
          ((start-phase2 (cont p-key g-key salt bb)
             (socket-send intf 'actor-internal-message:srp-phase2 p-key g-key salt bb)
             (expect intf
               (actor-internal-message:srp-phase2-reply (aa m1)
                  (funcall cont aa m1))
               ))
           
           (phase2-reply (cont aa m1)
             (socket-send intf 'actor-internal-message:srp-phase2-reply aa m1)
             (expect intf
               (actor-internal-message:srp-phase3 (m2)
                  (funcall cont m2))
               ))
           
           (start-phase3 (m2 final-fn)
             (let ((enc (secure-encoding crypto `(actor-internal-message:srp-phase3 ,m2))))
               (write-message writer enc)
               (funcall final-fn))))
        
        (setf srp-ph2-begin (=cont #'start-phase2)
              srp-ph2-reply (=cont #'phase2-reply)
              srp-ph3-begin (=cont #'start-phase3)
              kill-timer    (make-instance 'kill-timer
                                           :timer-fn #'(lambda ()
                                                         (mp:funcall-async 'shutdown intf))
                                           )))
    
      (let ((reader (make-instance 'message-reader
                                   :crypto     crypto
                                   :dispatcher (make-instance 'message-dispatcher
                                                              :title      title
                                                              :intf       intf
                                                              :crypto     crypto
                                                              :kill-timer kill-timer)
                                   )))
        (labels
            ((rd-callback-fn (state buffer end)
               ;; callback for I/O thread - on continuous async read
               #|
               (log-info :SYSTEM-LOG "Socket Reader Callback (STATUS = ~A, END = ~A)"
                         (comm:async-io-state-read-status state)
                         end)
               |#
               (when (plusp end)
                 ;; (log-info :SYSTEM-LOG "~A Incoming bytes: ~A" title buffer)
                 (send reader 'actor-internal-message:rd-incoming (list* 0 end (subseq buffer 0 end)))
                 (comm:async-io-state-discard state end))
               (when-let (status (comm:async-io-state-read-status state))
                 ;; terminate on any error
                 (comm:async-io-state-finish state)
                 (log-error :SYSTEM-LOG "~A Incoming error state: ~A" title status)
                 (send reader 'actor-internal-message:rd-error)
                 (decr-io-count state)))
             
             (decr-io-count (io-state)
               (when (zerop (atomic-decf io-running)) ;; >0 is running
                 (comm:close-async-io-state io-state)
                 (shutdown intf))))
          
          (setf writer
                (make-instance 'message-writer
                               :io-state      io-state
                               :io-running    io-running
                               :decr-io-count #'decr-io-count))
          (comm:async-io-state-read-with-checking io-state #'rd-callback-fn
                                                  :element-type '(unsigned-byte 8))
          (resched kill-timer)
          )))))

;; ------------------------------------------------------------------------
#|
(defun tst ()
  (bfly:!? "eval@malachite.local" '(get-universal-time))
  (bfly:!? "eval@10.0.1.13"       '(get-universal-time))
  (bfly:!? "eval@dachshund.local" '(get-universal-time)))
(tst)

(time
 (bfly:!? "eval@rincon.local" '(list "**** RESPONSE ****" (machine-instance) (get-universal-time))))
(bfly:!? "eval@arroyo.local" '(list "**** RESPONSE ****" (machine-instance) (get-universal-time)))

(bfly:!  "eval@rincon.local" '(bfly:log-info :SYSTEM-LOG
                                             (list :machine (machine-instance)
                                                   :time    (get-universal-time))))

(defun tst ()
  (let (ans)
    (log-info :SYSTEM-LOG "TIMING: ~A :VALUE ~A"
              (with-output-to-string (*trace-output*)
                (time
                 (setf ans (bfly:!? "eval@rincon.local"
                                    `(list "**** RESPONSE ****" (machine-instance) (get-universal-time)))
                       )))
              ans)))
(tst)
(ac:spawn 'tst) ;; no go...
(ac:spawn-worker 'tst)
(mp:funcall-async 'tst)

(..rem:init-messenger-mapper)
(com.sd.butterfly.glbs:show-maps)

(defun tst ()
  (let (ans)
    (log-info :SYSTEM-LOG "TIMING: ~A VALUE: ~A" 
              (with-output-to-string (*trace-output*)
                (time
                 (setf ans (start-client-messenger (bfly:make-node "rincon.local")))))
              ans)))

(tst)
(ac:spawn 'tst)
(ac:spawn-worker 'tst)
(mp:funcall-async 'tst)


(ac:spawn
 (lambda ()
   (ac:=wait* () ()
       (lw:do-nothing)
     (ac:pr :got-it!))))


|#
#||# ;; -------------------------------

(defun open-connection (ip-addr &optional ip-port)
  (=wait (io-state) ()
      (comm:create-async-io-state-and-connected-tcp-socket
         *ws-collection*
         ip-addr
         (or ip-port *default-port*)
         (lambda (state args)
           (when args
             (apply 'log-error :SYSTEM-LOG args))
           (=values (if args nil state)))
         #||#
         :ssl-ctx :tls-v1
         :ctx-configure-callback (lambda (ctx)
                                   (comm:set-ssl-ctx-cert-cb ctx 'my-find-certificate))
         #||#
         :handshake-timeout 5
         :ipv6    nil)
    (if io-state
          (let* ((crypto  (make-instance 'client-crypto))
                 (intf    (make-instance 'socket-interface
                                         :title    "Client"
                                         :io-state io-state
                                         :crypto   crypto)))
            (handler-bind ((error (lambda (c)
                                    (declare (ignore c))
                                    (shutdown intf))
                                  ))
              (progn
                (client-negotiate-security crypto intf)
                (socket-send intf 'actor-internal-message:client-info (machine-instance))
                (=wait (ans) (:timeout 5 :errorp t)
                    (expect intf
                      (actor-internal-message:server-info (server-node)
                          (bridge-register server-node intf)
                          (bridge-register ip-addr intf)
                          (log-info :SYSTEM-LOG "Socket client starting up: ~A" intf)
                          (=values intf)))
                  ans))))
      ;; else
      (error "Can't connect to: ~A" ip-addr))))

;; -------------------------------------------------------------

(defun start-server-messenger (accepting-handle io-state)
  "Internal routine to start a server messenger tree. A messenger tree
consists of two threads.  One thread is a dedicated socket reader, and
the other thread is a dispatcher between incoming and outgoing
messages. This much is just like a client messenger tree. The only
distinction is found in the details of the initial handshake dance.

See the discussion under START-CLIENT-MESSENGER for details."

  ;; this is a callback function from the socket event loop manager
  ;; so we can't dilly dally...
  (declare (ignore accepting-handle))
  (let* ((crypto  (make-instance 'server-crypto))
         (intf    (make-instance 'socket-interface
                                 :title    "Server"
                                 :io-state io-state
                                 :crypto   crypto)))

    (expect intf
      (actor-internal-message:client-info (client-node)
          (log-info :SYSTEM-LOG "Socket server starting up: ~A" intf)
          (socket-send intf 'actor-internal-message:server-info (machine-instance))
          (bridge-register client-node intf))
      )))

;; --------------------------------------------------------------
;;; The certificate and private key files in this directory were generated
;;; by running the following:
#|
   openssl req -new -text -subj "/C=US/ST=Arizona/L=Tucson/O=Refined Audiometrics Laboratory, LLC/CN=chicken" -passout pass:{bbe37564-f7b1-11ea-82f8-787b8acbe32e} -out newreq.pem -keyout newreq.pem
   openssl x509 -req -in newreq.pem -signkey newreq.pem -text -passin pass:{bbe37564-f7b1-11ea-82f8-787b8acbe32e} -out newcert.pem
   cat newreq.pem newcert.pem > cert-and-key.pem
   openssl dhparam -text 1024 -out dh_param_1024.pem
|#

(defvar *ssl-context*      nil)
(defvar *actors-version*   "{bbe37564-f7b1-11ea-82f8-787b8acbe32e}")

(defun filename-in-ssl-server-directory (name)
  (namestring (merge-pathnames name
                               (merge-pathnames "Butterfly/"
                                                (sys:get-folder-path :appdata))
                               )))
              
(defun verify-client-certificate (ok-p xsc)
  (format (or mp:*background-standard-output* t)
          "Current certificate issuer : ~a [~a]~%"
          (comm:x509-name-field-string 
           (comm:x509-get-issuer-name
            (comm:x509-store-ctx-get-current-cert xsc))
           "organizationName")
          ok-p)
  t)

(defun my-configure-ssl-ctx (ssl-ctx ask-for-certificate)
  (comm:set-ssl-ctx-password-callback ssl-ctx :password *actors-version*)

  (comm:ssl-ctx-use-certificate-chain-file
   ssl-ctx
   (filename-in-ssl-server-directory "newcert.pem" ))
  (comm:ssl-ctx-use-rsaprivatekey-file
   ssl-ctx
   (filename-in-ssl-server-directory "newreq.pem")
   comm:ssl_filetype_pem)
  (comm:set-ssl-ctx-dh
   ssl-ctx :filename (filename-in-ssl-server-directory "dh_param_1024.pem"))

  (when ask-for-certificate
    (comm:set-verification-mode ssl-ctx :server :always
                                'verify-client-certificate)
    (comm:set-verification-depth ssl-ctx 1)))

(defun initialize-the-ctx (symbol ask-for-certificate)
  (when-let (old (symbol-value symbol))
    (comm:destroy-ssl-ctx old)
    (set symbol nil))
  (let ((new (comm:make-ssl-ctx)))
    (set symbol new)
    (my-configure-ssl-ctx new ask-for-certificate)))

(defvar *cert-key-pairs* nil)

(defun my-find-certificate (ssl-pointer)
  (declare (ignorable ssl-pointer))
  (let ((pair (or *cert-key-pairs* 
                  (setq *cert-key-pairs* 
                        (comm:read-certificate-key-pairs
                         (filename-in-ssl-server-directory "cert-and-key.pem")
                        :pass-phrase *actors-version*)))))
    (values (caar pair) (second (car pair)))))

;; --------------------------------------------------------------

(=defun %terminate-server ()
  (if *aio-accepting-handle*
      (comm:close-accepting-handle *aio-accepting-handle*
                                   (lambda (coll)
                                     ;; we are operating in the collection process
                                     (comm:close-wait-state-collection coll)
                                     (setf *aio-accepting-handle* nil
                                           *ws-collection*        nil)
                                     (unwind-protect
                                         (mp:process-terminate (mp:get-current-process))
                                       (=values))))
    ;; else
    (=values)))

(defun terminate-server ()
  (=wait () ()
      (%terminate-server)))

(defun start-tcp-server (&optional (tcp-port-number *default-port*))
  "An internal routine to start up a server listener socket on the
indicated port number."

  (terminate-server)
  (initialize-the-ctx '*ssl-context* t)
  (setq *ws-collection*
        (comm:create-and-run-wait-state-collection "Actors Server"))
  (setq *aio-accepting-handle* 
        (comm:accept-tcp-connections-creating-async-io-states
         *ws-collection*
         tcp-port-number
         'start-server-messenger
         :ssl-ctx *ssl-context*
         :ipv6    nil
         ))
  (log-info :SYSTEM-LOG "Actors service started on port ~A" tcp-port-number))

;; --------------------------------------------------
;;

(defun lw-start-tcp-server (&rest ignored)
  ;; called by Action list with junk args
  (declare (ignore ignored))
  ;; We need to delay the construction of the system logger till this
  ;; time so that we get a proper background-error-stream.  Cannot be
  ;; performed on initial load of the LFM.
  (ensure-system-logger)
  (start-tcp-server))

(defun lw-reset-actor-system (&rest ignored)
  (declare (ignore ignored))
  (terminate-server)
  (bridge-reset))

(let ((lw:*handle-existing-action-in-action-list* '(:silent :skip)))
  
  (lw:define-action "Initialize LispWorks Tools"
                    "Start up Actor Server"
                    'lw-start-tcp-server
                    :after "Run the environment start up functions"
                    :once)

  #+(OR :LISPWORKS6 :LISPWORKS7)
  (lw:define-action "Save Session Before"
                    "Reset Actors"
                    'lw-reset-actor-system)

  #+(OR :LISPWORKS6 :LISPWORKS7)
  (lw:define-action "Save Session After"
                    "Restart Actor System"
                    'lw-start-tcp-server))
