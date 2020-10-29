#|
The MIT License

Copyright (c) 2017-2018 Refined Audiometrics Laboratory, LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
|#

(in-package :um)

(defun do-with-timeout (timeout cleanup fn)
  (let* ((mbox   (mp:make-mailbox))
         (thread (mpcompat:process-run-function "Wait Function" '()
                                          (lambda ()
                                            (mp:mailbox-send mbox (um:capture-ans-or-exn fn)))
                                          )))
    (multiple-value-bind (ans okay)
        (mp:mailbox-read mbox :timeout timeout)
      (if okay
          (values
           (recover-ans-or-exn ans)
           t)
        ;; else
        (progn
          (mp:process-terminate thread)
          (when cleanup
            (funcall cleanup))
          nil))
      )))

(defmacro with-timeout ((timeout &key cleanup) &body body)
  `(do-with-timeout ,timeout ,cleanup
                    (lambda ()
                      ,@body)))

#+:LISPWORKS
(editor:setup-indent "WITH-TIMEOUT" 1)