(defpackage #:http-backend-winhttp/tests
  (:use #:cl #:rove #:http-protocol #:http-backend-winhttp)
  (:import-from #:ws-protocol
                #:ws-backend
                #:make-ws-client
                #:backend-ws-transports
                #:backend-supports-ws-transport-p
                #:ws-transport-not-available
                #:connect))
