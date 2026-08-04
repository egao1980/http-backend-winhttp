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

(defun %winhttp-ws-live-p ()
  (let ((fn (find-symbol "FEATURE-OR-ENV-ENABLED-P" :ws-protocol)))
    (if (and fn (fboundp fn))
        (funcall fn :winhttp-ws-live "WINHTTP_WS_LIVE")
        (let ((v (uiop:getenv "WINHTTP_WS_LIVE")))
          (and v (not (member (string-downcase v)
                              '("" "0" "false" "no" "off")
                              :test #'string=)))))))

(deftest winhttp-ws-echo-live-optional
  "Live H1 Upgrade echo — gate with WINHTTP_WS_LIVE=1 or :winhttp-ws-live."
  (cond
    ((not (%winhttp-ws-live-p))
     (skip "set WINHTTP_WS_LIVE=1 for WinHTTP WS echo smoke"))
    #-(or win32 windows mswindows)
    (t (skip "WinHTTP WS live requires Windows"))
    #+(or win32 windows mswindows)
    (t
     (let* ((b (make-winhttp-backend))
            (c (make-ws-client b :transport :http/1.1))
            (url (or (uiop:getenv "WINHTTP_WS_URL")
                     "wss://echo.websocket.events/"))
            (payload (format nil "winhttp-ws-~A" (get-universal-time)))
            (got nil)
            (err nil))
       (handler-case
           (let ((conn (connect b c url :transport :http/1.1)))
             (ok (eq :open (ws-protocol:ready-state conn)))
             (ws-protocol:on-event conn :message (lambda (msg) (setf got msg)))
             (ws-protocol:on-event conn :error (lambda (e) (setf err e)))
             (ws-protocol:send-text conn payload)
             (loop repeat 50
                   until (or got err)
                   do (sleep 0.2))
             (ignore-errors (ws-protocol:close-connection conn))
             (when err (fail (format nil "WS error: ~A" err)))
             (ok (equal payload got)))
         (error (e)
           (fail (format nil "unexpected: ~A" e))))))))
