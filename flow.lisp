(in-package :cl-flow)


(defun nop (result error-p)
  (declare (ignore result error-p)))


(defun expand-body-function-def (name lambda-list body)
  (let* ((destructuring-ll (car lambda-list))
         (destructured-p (and destructuring-ll (listp destructuring-ll)))
         (arg (gensym)))
    (unless (or destructured-p (null (cdr lambda-list)))
      (error "Atomic block can accept single argument only, but got ~A" lambda-list))
    `(,name
      (,arg)
      (declare (ignorable ,arg))
      (restart-case
          ,(if destructured-p
               `(destructuring-bind ,destructuring-ll ,arg
                  ,@body)
               `(,@(if lambda-list
                       `(let ((,(car lambda-list) ,arg)))
                       `(progn))
                   ,@body))
        (continue ()
          :report "Skip flow block returning nil"
          nil)
        (use-value (value)
          :report "Skip flow block returning provided value"
          value)))))



(defmacro atomically (invariant-n-opts lambda-list &body body)
  "Encloses atomic flow block of code that could be dispatched concurrently"
  (destructuring-bind (&optional invariant &rest opts) (ensure-list invariant-n-opts)
    (with-gensyms (dispatcher arg result-callback return-error dispatched e body-fn)
      `(lambda (,dispatcher ,result-callback ,arg)
         (declare (ignorable ,arg))
         (labels (,(expand-body-function-def body-fn lambda-list body)
                  (,return-error (,e)
                    (funcall ,result-callback ,e t))
                  (,dispatched ()
                    (handler-bind ((simple-error #',return-error))
                      (funcall ,result-callback (funcall #',body-fn ,arg) nil))))
           (funcall ,dispatcher #',dispatched ,invariant ,@opts))))))


(defmacro -> (invariant-n-opts lambda-list &body body)
  "See flow:atomically"
  `(atomically ,invariant-n-opts ,lambda-list
     ,@body))


(defmacro dynamically (lambda-list &body body)
  "Generates new flow dynamically during parent flow execution. In other words, injects new
dynamically created flow into a current one."
  (with-gensyms (dispatcher body-fn arg result-callback return-error e)
    `(lambda (,dispatcher ,result-callback ,arg)
       (declare (ignorable ,arg))
       (flet (,(expand-body-function-def body-fn lambda-list body)
              (,return-error (,e)
                (funcall ,result-callback ,e t)))
         (handler-bind ((simple-error #',return-error))
           (funcall (funcall #',body-fn ,arg) ,dispatcher ,result-callback ,arg))))))


(defmacro ->> (lambda-list &body body)
  "See flow:dynamically"
  `(dynamically ,lambda-list
     ,@body))


(defun continue-flow (&optional value)
  "Invokes next flow block with provided value as an argument"
  (declare (ignore value))
  (error "function can be called inside asynchonous block only"))


(defun interrupt-flow (condition)
  "Interrupts flow with provided condition"
  (declare (ignore condition))
  (error "function can be called inside asynchonous block only"))


(defmacro asynchronously (lambda-list &body body)
  "Splits current flow allowing manually managing its execution via #'continue-flow and
#'interrupt-flow functions"
  (with-gensyms (dispatcher body-fn arg result-callback continue-arg condi)
    `(lambda (,dispatcher ,result-callback ,arg)
       (declare (ignorable ,arg)
                (ignore ,dispatcher))
       (labels ((continue-flow (&optional ,continue-arg)
                  (funcall ,result-callback ,continue-arg nil))
                (interrupt-flow (,condi)
                  (funcall ,result-callback ,condi t))
                ,(expand-body-function-def body-fn lambda-list body))
         (handler-bind ((simple-error #'interrupt-flow))
           (funcall #',body-fn ,arg))))))


(defmacro %> (lambda-list &body body)
  "See flow:asynchronously"
  `(asynchronously ,lambda-list
     ,@body))


(defun dispatch-serial-flow (list dispatcher result-callback arg)
  (labels ((dispatch-list (fn-list arg)
             (if (null fn-list)
                 (funcall result-callback arg nil)
                 (let ((flow-element (first fn-list)))
                   (flet ((dispatch-next (result error-p)
                            (if error-p
                                (error result)
                                (dispatch-list (rest fn-list) result))))
                     (if (listp flow-element)
                         (dispatch-serial-flow flow-element dispatcher #'dispatch-next arg)
                         (funcall flow-element dispatcher #'dispatch-next arg)))))))
    (dispatch-list list arg)))


(defun dispatch-parallel-flow (list dispatcher result-callback arg)
  (if (null list)
      (funcall result-callback nil nil)
      (let ((counter)
            (flow-result (copy-tree list)))
        (labels ((count-elements (root)
                   (if (and root (listp root))
                       (loop for node in root summing (count-elements node))
                      1))
                 (resolve (callback-list)
                   (flet ((%cons-result-callback (result error-p)
                            (when error-p
                              (error result))
                            (setf (car callback-list) result)
                            (when (= (decrement-counter counter) 0)
                              (funcall result-callback flow-result nil))))
                     (let ((element (car callback-list)))
                       (cond
                         ((null element) (%cons-result-callback nil nil))
                         ((listp element) (resolve element))
                         (t (funcall element dispatcher #'%cons-result-callback arg))))
                     (when-let ((rest-elements (cdr callback-list)))
                       (resolve rest-elements)))))
          (setf counter (make-atomic-counter (count-elements list)))
          (resolve flow-result)))))


(defmacro serially (&body flow)
  "Executes child elements serially (but possibly in different threads) returning a value of the
last atomic block or flow"
  (with-gensyms (dispatcher result-callback arg flow-tree)
    `(let ((,flow-tree (list ,@flow)))
       (lambda (,dispatcher ,result-callback ,arg)
         (declare (type (or null (function (list t) *)) ,result-callback))
         (dispatch-serial-flow ,flow-tree ,dispatcher (or ,result-callback #'nop) ,arg)))))


(defmacro >> (&body flow)
  "See flow:serially"
  `(serially ,@flow))


(defmacro concurrently (&body body)
  "Executes child elements in parallel, returning a list of results for child blocks or flows in
the same order they were specified"
  (with-gensyms (dispatcher arg result-callback flow)
    `(let ((,flow (list ,@body)))
       (lambda (,dispatcher ,result-callback ,arg)
         (declare (type (or (function (list t) *) null) ,result-callback))
         (dispatch-parallel-flow ,flow ,dispatcher (or ,result-callback #'nop) ,arg)))))


(defmacro ~> (&body body)
  "See flow:concurrently"
  `(concurrently ,@body))


(defun run (dispatcher flow)
  "Dispatcher must be a function with lambda-list congruent to (task invariant &key
&allow-other-keys)"
  (dispatch-serial-flow (ensure-list flow) dispatcher #'nop nil))
