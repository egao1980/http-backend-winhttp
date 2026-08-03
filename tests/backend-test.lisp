(in-package #:http-backend-winhttp/tests)

(deftest winhttp-available-matches-platform
  #+(or win32 windows mswindows)
  (ok (winhttp-available-p))
  #-(or win32 windows mswindows)
  (ok (not (winhttp-available-p))))

(deftest make-backend-requires-windows
  #+(or win32 windows mswindows)
  (ok (typep (make-winhttp-backend) 'winhttp-backend))
  #-(or win32 windows mswindows)
  (ok (signals (make-winhttp-backend) 'unsupported-operation)))

(deftest body-stream-feed-eof
  "Gray stream used for :want-stream (platform-independent)."
  (let ((s (make-winhttp-body-input-stream :limit 1024)))
    (ok (body-feed s #(1 2 3)))
    (body-eof s)
    (ok (= 1 (read-byte s)))
    (ok (= 2 (read-byte s)))
    (ok (= 3 (read-byte s)))
    (ok (eq :eof (read-byte s nil :eof)))))

(deftest redirect-helpers
  (ok (http-backend-winhttp::redirect-status-p 302))
  (ok (http-backend-winhttp::redirect-preserves-method-p 307))
  (ok (not (http-backend-winhttp::redirect-preserves-method-p 302)))
  (let* ((base (quri:uri "https://a.example/x"))
         (next (http-backend-winhttp::resolve-redirect-uri base "/y")))
    (ok (string-equal "https" (quri:uri-scheme next)))
    (ok (string= "/y" (quri:uri-path next)))))

(deftest inject-cookie-roundtrip
  (let* ((jar (cl-cookie:make-cookie-jar))
         (url "http://example.com/")
         (_ (cl-cookie:merge-cookies
             jar
             (list (cl-cookie:make-cookie :name "a" :value "1"
                                          :origin-host "example.com"
                                          :path "/" :sanity-check nil))))
         (headers (inject-cookie-header nil jar url)))
    (declare (ignore _))
    (ok (equal "a=1" (cdr (assoc "cookie" headers :test #'string-equal))))))

(deftest wrap-response-stream-identity
  "CE wrap on stream body (want-stream path) is a no-op without Content-Encoding."
  (let* ((src (make-winhttp-body-input-stream :limit 64))
         (ht (make-hash-table :test #'equal)))
    (body-feed src #(9 8 7))
    (body-eof src)
    (multiple-value-bind (out headers)
        (wrap-response-body-stream src ht :decompress t)
      (declare (ignore headers))
      (ok (= 9 (read-byte out)))
      (ok (= 8 (read-byte out)))
      (ok (= 7 (read-byte out))))))

(deftest chunk-frame-roundtrip
  (let* ((data #(1 2 3 4))
         (frame (make-chunk-frame data))
         ;; "4\r\n" + data + "\r\n"
         (prefix (babel:string-to-octets (format nil "4~C~C" #\Return #\Newline)
                                         :encoding :utf-8))
         (suffix (babel:string-to-octets (format nil "~C~C" #\Return #\Newline)
                                         :encoding :utf-8)))
    (ok (= (+ (length prefix) 4 (length suffix)) (length frame)))
    (ok (equalp prefix (subseq frame 0 (length prefix))))
    (ok (equalp data (subseq frame (length prefix) (+ (length prefix) 4))))
    (ok (equalp suffix (subseq frame (+ (length prefix) 4))))
    (ok (equalp #(#x30 #x0d #x0a #x0d #x0a) +chunked-terminator+))))

(deftest stream-upload-headers-content-length
  (multiple-value-bind (headers chunked-p)
      (apply-stream-upload-headers '(("accept" . "*/*")) 42)
    (ok (not chunked-p))
    (ok (equal "42" (cdr (assoc "content-length" headers :test #'string-equal))))
    (ok (null (assoc "transfer-encoding" headers :test #'string-equal)))))

(deftest stream-upload-headers-chunked
  (multiple-value-bind (headers chunked-p)
      (apply-stream-upload-headers '(("content-length" . "99")) nil)
    (ok chunked-p)
    (ok (null (assoc "content-length" headers :test #'string-equal)))
    (ok (equal "chunked"
               (cdr (assoc "transfer-encoding" headers :test #'string-equal))))))

(deftest normalize-wire-stream-vs-vector
  (let ((s (make-string-input-stream "hi")))
    (multiple-value-bind (wire headers stream-p chunked-p clen)
        (http-backend-winhttp::normalize-request-wire s nil nil)
      (declare (ignore headers))
      (ok (eq wire s))
      (ok stream-p)
      (ok chunked-p)
      (ok (null clen))))
  (let ((octets (make-array 3 :element-type '(unsigned-byte 8)
                              :initial-contents '(1 2 3))))
    (multiple-value-bind (wire headers stream-p chunked-p clen)
        (http-backend-winhttp::normalize-request-wire octets nil 3)
      (declare (ignore headers))
      (ok (equalp octets wire))
      (ok (not stream-p))
      (ok (not chunked-p))
      (ok (= 3 clen)))))

(deftest body-stream-backpressure-full-p
  (let* ((space 0)
         (s (make-winhttp-body-input-stream
             :limit 4
             :on-space (lambda () (incf space)))))
    (ok (body-feed s #(1 2 3 4)))
    (ok (body-full-p s))
    (ok (= 1 (read-byte s)))
    (ok (plusp space))
    (ok (not (body-full-p s)))))
