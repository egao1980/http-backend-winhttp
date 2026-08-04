(defsystem "http-backend-winhttp"
  :version "0.1.3"
  :description "WinHTTP http-protocol backend — async I/O, streams, Windows proxy auth, WebSocket"
  :author "egao1980"
  :license "MIT"
  :depends-on ("http-protocol"
               "event-protocol"
               "ws-protocol"
               "quri"
               "cffi"
               "cl-base64"
               "babel"
               "alexandria"
               "bordeaux-threads"
               "split-sequence"
               "trivial-gray-streams"
               (:feature (:or :win32 :windows :mswindows) "winhttp"))
  :serial t
  :pathname "src"
  :components ((:file "package")
               (:file "ffi")
               (:file "auth")
               (:file "chunk")
               (:file "stream")
               (:file "redirect")
               (:file "async")
               (:file "backend")
               (:file "websocket"))
  :in-order-to ((test-op (test-op "http-backend-winhttp/tests"))))

(defsystem "http-backend-winhttp/tests"
  :depends-on ("http-backend-winhttp" "rove" "ws-protocol")
  :pathname "tests"
  :serial t
  :components ((:file "package")
               (:file "backend-test")
               (:file "http2-test")
               (:file "websocket-test"))
  :perform (test-op (o c)
             (unless (symbol-call :rove :run c)
               (error "tests failed for ~A" (component-name c)))))
