
(in-package :actors)

(um:eval-always
  (import '(
            cps:=bind-cont
            )))

(defclass reactor (actor)
  ((table  :reader reactor-table  :initform (make-hash-table))
   ))

(defvar *reactor* (make-instance 'reactor))

(defun subscribe (evt-kind subscriber cbfun)
  ;; a null callback function indicates an unsubscribe
  (with-slots (table) *reactor*
    (perform-in-actor *reactor*
      (let* ((subscribers (gethash evt-kind table))
             (entry       (assoc subscriber subscribers)))
        (if entry
            (if cbfun
                (setf (cdr entry) cbfun)
              (setf (gethash evt-kind table) (remove entry subscribers)))
          (when cbfun
            (setf (gethash evt-kind table) (acons subscriber cbfun subscribers)))
          )))
    ))

(defun unsubscribe (evt-kind subscriber)
  (subscribe evt-kind subscriber nil))

(defun notify (evt-kind &rest evt-data)
  (with-slots (table) *reactor*
    (perform-in-actor *reactor*
      (dolist (pair (gethash evt-kind table))
        (destructuring-bind (actor . cbfun) pair
          (apply cbfun actor evt-data)))
      )))

(defmacro =subscribe (evt-kind)
  ;; to be used in an =BIND context
  ;; NOTE: =BIND1 continuations are one-shot,
  ;; while =BIND continuations are persistent
  `(subscribe ,evt-kind (current-actor) =bind-cont))

(defun =unsubscribe (evt-kind)
  (unsubscribe evt-kind (current-actor)))

#|
(defvar *x* 0)
(defun incr-x ()
  (incf *x*)
  (notify '*x* *x*))
(defun decr-x ()
  (decf *x*)
  (notify '*x* *x*))
(cps:=bind (me ct)
    (=subscribe '*x*)
  (format t "~&*X* = ~A" ct))

(defun prt (me ct)
  (format t "~&*X* = ~A" ct))
(subscribe '*x* nil 'prt)
(incr-x)
(decr-x)
 |#