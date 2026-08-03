(in-package #:http-backend-winhttp)

;;; Transfer-Encoding: chunked framing for streamed uploads (mirrors async http1).

(defun make-chunk-frame (octets &key (start 0) (end (length octets)))
  "Chunked frame for OCTETS[START:END] (size CRLF data CRLF)."
  (let* ((n (- end start))
         (size-line (babel:string-to-octets
                     (format nil "~X~C~C" n #\Return #\Newline)
                     :encoding :utf-8))
         (crlf (babel:string-to-octets (format nil "~C~C" #\Return #\Newline)
                                       :encoding :utf-8))
         (out (make-array (+ (length size-line) n (length crlf))
                          :element-type '(unsigned-byte 8))))
    (replace out size-line)
    (replace out octets :start1 (length size-line) :start2 start :end2 end)
    (replace out crlf :start1 (+ (length size-line) n))
    out))

(defparameter +chunked-terminator+
  (babel:string-to-octets (format nil "0~C~C~C~C" #\Return #\Newline
                                  #\Return #\Newline)
                          :encoding :utf-8)
  "Final chunk (0 CRLF CRLF).")
