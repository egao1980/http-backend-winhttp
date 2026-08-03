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
