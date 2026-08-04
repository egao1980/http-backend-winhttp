(defpackage #:http-backend-winhttp
  (:use #:cl #:http-protocol)
  (:import-from #:ws-protocol
                #:ws-backend
                #:ws-backend-p
                #:ws-client
                #:make-ws-client
                #:ws-client-headers
                #:ws-client-protocols
                #:ws-client-transport
                #:ws-client-auth
                #:ws-client-proxy
                #:ws-client-verify
                #:ws-connection
                #:ws-error
                #:ws-handshake-error
                #:ws-connection-error
                #:ws-protocol-error
                #:ws-transport-not-available
                #:backend-ws-transports
                #:backend-supports-ws-transport-p
                #:resolve-ws-transport
                #:inject-auth-headers
                #:connect
                #:send-text
                #:send-binary
                #:ping
                #:close-connection
                #:on-event
                #:%connection-ready-state)
  (:shadowing-import-from #:http-protocol
                          #:unsupported-operation)
  (:import-from #:event-protocol
                #:*event-backend*
                #:*event-loop*
                #:with-event-backend
                #:with-event-loop-var
                #:make-event-loop
                #:run
                #:stop
                #:defer
                #:sleep*
                #:wake)
  (:import-from #:alexandria #:when-let #:ensure-list)
  (:import-from #:split-sequence #:split-sequence)
  (:export #:winhttp-backend
           #:make-winhttp-backend
           #:winhttp-available-p
           #:*use-default-credentials*
           #:*winhttp-autologon-policy*
           #:*event-backend-maker*
           #:winhttp-request-handle
           #:winhttp-request-canceled-p
           #:winhttp-body-input-stream
           #:make-winhttp-body-input-stream
           #:body-feed
           #:body-eof
           #:body-full-p
           #:make-chunk-frame
           #:+chunked-terminator+
           #:apply-stream-upload-headers
           #:winhttp-ws-connection))
