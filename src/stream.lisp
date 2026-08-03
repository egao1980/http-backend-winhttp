(in-package #:http-backend-winhttp)

;;; Gray binary input stream fed by WinHTTP READ_COMPLETE callbacks.
;;; Same shape as http-backend-async's async-body stream (producer/consumer + CV).

(defvar *winhttp-body-queue-limit* nil
  "Max buffered octets for :want-stream downloads (NIL → 4 × *HTTP-STREAM-BUFFER-SIZE*).
   Producer (WinHttpReadData) pauses when full; consumer drain resumes via on-space.")

(defun %body-limit ()
  (or *winhttp-body-queue-limit*
      (* 4 (or (ignore-errors *http-stream-buffer-size*) 65536))))

(defclass winhttp-body-input-stream
    (trivial-gray-streams:fundamental-binary-input-stream)
  ((lock :initform (bt:make-lock "winhttp-body") :reader body-lock)
   (cv :initform (bt:make-condition-variable :name "winhttp-body")
       :reader body-cv)
   (chunks :initform nil :accessor body-chunks)
   (chunk-pos :initform 0 :accessor body-chunk-pos)
   (buffered :initform 0 :accessor body-buffered)
   (limit :initarg :limit :reader body-limit)
   (eof :initform nil :accessor body-eof-p)
   (error :initform nil :accessor body-error)
   (open :initform t :accessor body-open-p)
   (on-space :initform nil :initarg :on-space :accessor body-on-space
             :documentation "Thunk when buffer drains (resume WinHTTP reads).")))

(defun make-winhttp-body-input-stream (&key (limit (%body-limit)) on-space)
  (make-instance 'winhttp-body-input-stream :limit limit :on-space on-space))

(defun body-full-p (s)
  (>= (body-buffered s) (body-limit s)))

(defun body-feed (s octets &key (start 0) (end (length octets)))
  (when (>= start end) (return-from body-feed t))
  (let ((piece (subseq octets start end)))
    (bt:with-lock-held ((body-lock s))
      (unless (body-open-p s) (return-from body-feed nil))
      (when (body-error s) (return-from body-feed nil))
      (setf (body-chunks s) (nconc (body-chunks s) (list piece)))
      (incf (body-buffered s) (length piece))
      (bt:condition-notify (body-cv s)))
    t))

(defun body-eof (s)
  (bt:with-lock-held ((body-lock s))
    (setf (body-eof-p s) t)
    (bt:condition-notify (body-cv s))))

(defun body-fail (s condition)
  (bt:with-lock-held ((body-lock s))
    (setf (body-error s) condition
          (body-eof-p s) t)
    (bt:condition-notify (body-cv s))))

(defun body-close (s)
  (bt:with-lock-held ((body-lock s))
    (setf (body-open-p s) nil
          (body-eof-p s) t)
    (bt:condition-notify (body-cv s))))

(defun %body-wait (s)
  (loop until (or (body-chunks s) (body-eof-p s) (body-error s)
                  (not (body-open-p s)))
        do (bt:condition-wait (body-cv s) (body-lock s))))

(defun %body-signal-space (s)
  (when-let (fn (body-on-space s))
    (ignore-errors (funcall fn))))

(defmethod trivial-gray-streams:stream-read-byte ((s winhttp-body-input-stream))
  (bt:with-lock-held ((body-lock s))
    (%body-wait s)
    (when (body-error s) (error (body-error s)))
    (unless (body-open-p s)
      (return-from trivial-gray-streams:stream-read-byte :eof))
    (let ((chunks (body-chunks s)))
      (unless chunks
        (return-from trivial-gray-streams:stream-read-byte :eof))
      (let* ((chunk (car chunks))
             (pos (body-chunk-pos s))
             (b (aref chunk pos)))
        (incf pos)
        (decf (body-buffered s))
        (if (>= pos (length chunk))
            (setf (body-chunks s) (cdr chunks)
                  (body-chunk-pos s) 0)
            (setf (body-chunk-pos s) pos))
        (%body-signal-space s)
        b))))

(defmethod trivial-gray-streams:stream-read-sequence
    ((s winhttp-body-input-stream) seq start end &key)
  (let ((pos start))
    (loop while (< pos end)
          for b = (trivial-gray-streams:stream-read-byte s)
          until (eq b :eof)
          do (setf (aref seq pos) b)
             (incf pos))
    pos))

(defmethod close ((s winhttp-body-input-stream) &key abort)
  (declare (ignore abort))
  (body-close s)
  t)
