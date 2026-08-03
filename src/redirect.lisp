(in-package #:http-backend-winhttp)

;;; HTTP redirect helpers (same shape as http-backend-async).

(defun redirect-status-p (status)
  (member status '(301 302 303 307 308) :test #'=))

(defun redirect-preserves-method-p (status)
  (member status '(307 308) :test #'=))

(defun resolve-redirect-uri (current-uri location)
  (let* ((loc (if (typep location 'quri:uri)
                  location
                  (quri:uri (string location))))
         (merged (quri:merge-uris loc current-uri)))
    (unless (member (or (quri:uri-scheme merged) "http")
                    '("http" "https") :test #'string-equal)
      (error 'http-redirect-error
             :message (format nil "disallowed redirect scheme ~A"
                              (quri:uri-scheme merged))))
    merged))

(defun %strip-body-headers (headers)
  (remove-if (lambda (pair)
               (member (car pair)
                       '("content-length" "content-type" "content-encoding"
                         "transfer-encoding")
                       :test #'string-equal))
             headers))

(defun prepare-redirect-hop (status uri method body-octets headers cookie-jar
                             accept-encoding-header)
  "Return (values method uri headers body)."
  (let* ((new-method (if (redirect-preserves-method-p status) method :get))
         (new-body (if (redirect-preserves-method-p status)
                       body-octets
                       (make-array 0 :element-type '(unsigned-byte 8))))
         (headers (copy-list headers)))
    (setf headers (remove "host" headers :key #'car :test #'string-equal)
          headers (remove "cookie" headers :key #'car :test #'string-equal))
    (unless (redirect-preserves-method-p status)
      (setf headers (%strip-body-headers headers)))
    (when (and accept-encoding-header
               (not (assoc "accept-encoding" headers :test #'string-equal)))
      (setf headers (acons "accept-encoding" accept-encoding-header headers)))
    (setf headers (inject-cookie-header headers cookie-jar
                                        (quri:render-uri uri)))
    (values new-method uri headers new-body)))
