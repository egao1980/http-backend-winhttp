(in-package #:http-backend-winhttp/tests)

(deftest winhttp-backend-is-ws-backend
  (let ((b (make-instance 'winhttp-backend)))
    (ok (typep b 'ws-backend))
    #+(or win32 windows mswindows)
    (progn
      (ok (equal '(:http/1.1) (backend-ws-transports b)))
      (ok (backend-supports-ws-transport-p b :http/1.1))
      (ok (not (backend-supports-ws-transport-p b :http/2))))
    #-(or win32 windows mswindows)
    (progn
      (ok (null (backend-ws-transports b)))
      (ok (not (backend-supports-ws-transport-p b :auto))))))

(deftest winhttp-ws-rejects-http2-transport
  #+(or win32 windows mswindows)
  (let* ((b (make-winhttp-backend))
         (c (make-ws-client b :transport :http/2)))
    (ok (signals (connect b c "ws://127.0.0.1/echo" :transport :http/2)
                 'ws-transport-not-available)))
  #-(or win32 windows mswindows)
  (ok (signals (connect (make-instance 'winhttp-backend)
                        (make-ws-client (make-instance 'winhttp-backend))
                        "ws://127.0.0.1/echo")
               'ws-transport-not-available)))

(deftest winhttp-ws-url-parts
  (multiple-value-bind (host port path https-p)
      (http-backend-winhttp::%ws-url-parts "wss://example.com:8443/chat?q=1")
    (ok (string= "example.com" host))
    (ok (= 8443 port))
    (ok (string= "/chat?q=1" path))
    (ok https-p)))
