;;;; HTTP/2 preference / negotiation unit tests (platform-safe).

(in-package #:http-backend-winhttp/tests)

(deftest http-protocol-flags-to-version-maps-bits
  "WINHTTP_PROTOCOL_FLAG_HTTP2 bit → :http/2; else :http/1.1."
  (ok (eq :http/1.1 (http-backend-winhttp::http-protocol-flags-to-version 0)))
  (ok (eq :http/1.1 (http-backend-winhttp::http-protocol-flags-to-version nil)))
  (ok (eq :http/2
          (http-backend-winhttp::http-protocol-flags-to-version
           http-backend-winhttp::+winhttp-protocol-flag-http2+)))
  (ok (eq :http/2
          (http-backend-winhttp::http-protocol-flags-to-version
           (logior http-backend-winhttp::+winhttp-protocol-flag-http2+ #x10))))
  (ok (eq :http/1.1 (http-backend-winhttp::http-protocol-flags-to-version #x10))))

(deftest backend-http-versions-clos
  "CLOS capability: Windows offers H2; other platforms HTTP/1.1 only."
  (let ((b (make-instance 'winhttp-backend)))
    #+(or win32 windows mswindows)
    (progn
      (ok (equal '(:http/1.1 :http/2) (backend-http-versions b)))
      (ok (backend-supports-http-version-p b :auto))
      (ok (backend-supports-http-version-p b :http/1.1))
      (ok (backend-supports-http-version-p b :http/2)))
    #-(or win32 windows mswindows)
    (progn
      (ok (equal '(:http/1.1) (backend-http-versions b)))
      (ok (backend-supports-http-version-p b :auto))
      (ok (backend-supports-http-version-p b :http/1.1))
      (ok (not (backend-supports-http-version-p b :http/2))))))

(deftest send-before-rejects-http2-off-windows
  "Protocol SEND :before rejects forced :http/2 when backend lacks it."
  #-(or win32 windows mswindows)
  (let* ((b (make-instance 'winhttp-backend))
         (c (make-http-client b :http-version :http/2))
         (r (make-http-request :url "https://example.test/"
                               :http-version :http/2)))
    (ok (signals (send b c r) 'http-version-not-available)))
  #+(or win32 windows mswindows)
  (ok (backend-supports-http-version-p (make-instance 'winhttp-backend) :http/2)))

(deftest maybe-enable-http2-auto-swallows-enable-failure
  "Preference :auto must not signal when enable-http2 fails (stub / old WinHTTP)."
  #-(or win32 windows mswindows)
  (ok (null (http-backend-winhttp::maybe-enable-http2 nil :auto)))
  #+(or win32 windows mswindows)
  (ok t))

(deftest negotiated-http-version-auto-accepts-http11
  "Stub http-protocol-used → :http/1.1 is fine for :auto."
  (ok (eq :http/1.1
          (http-backend-winhttp::negotiated-http-version nil :auto)))
  (ok (eq :http/1.1
          (http-backend-winhttp::negotiated-http-version nil :http/1.1))))

(deftest negotiated-http-version-forced-http2-requires-h2
  "Forced :http/2 with negotiated 1.1 → http-version-not-available."
  ;; Non-Windows stub always reports :http/1.1; on Windows NIL req falls back too.
  (ok (signals (http-backend-winhttp::negotiated-http-version nil :http/2)
               'http-version-not-available)))

#+ (or win32 windows mswindows)
(deftest maybe-enable-http2-calls-enable-on-windows
  "On Windows, :auto/:http/2 attempt enable (real handle required for success)."
  ;; Without a real HINTERNET, enable-http2 errors; :http/2 must surface
  ;; http-version-not-available, :auto must swallow.
  (ok (null (http-backend-winhttp::maybe-enable-http2
             (cffi:null-pointer) :auto)))
  (ok (signals (http-backend-winhttp::maybe-enable-http2
                (cffi:null-pointer) :http/2)
               'http-version-not-available)))
