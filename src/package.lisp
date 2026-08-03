(defpackage #:http-backend-winhttp
  (:use #:cl #:http-protocol)
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
           #:apply-stream-upload-headers))
