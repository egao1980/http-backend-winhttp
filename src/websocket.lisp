(in-package #:http-backend-winhttp)

;;; WinHTTP WebSocket client (RFC 6455 HTTP/1.1 Upgrade).
;;;
;;; Uses WinHttpSetOption(UPGRADE_TO_WEB_SOCKET) + WinHttpWebSocket* APIs
;;; (QL winhttp bindings). Not RFC 8441 Extended CONNECT — that is :http/2
;;; and not exposed by WinHTTP's WebSocket upgrade path.

(defmethod backend-ws-transports ((backend winhttp-backend))
  (declare (ignore backend))
  #+(or win32 windows mswindows) '(:http/1.1)
  #-(or win32 windows mswindows) '())

(defclass winhttp-ws-connection (ws-connection)
  ((handle :initarg :handle :accessor winhttp-ws-handle)
   (session :initarg :session :accessor winhttp-ws-session)
   (connection :initarg :connection :accessor winhttp-ws-connection-handle)
   (handlers :initform (make-hash-table :test #'eq)
             :accessor winhttp-ws-handlers)
   (reader :initform nil :accessor winhttp-ws-reader)
   (lock :initform (bt:make-lock "winhttp-ws") :reader winhttp-ws-lock)
   (closed-p :initform nil :accessor winhttp-ws-closed-p)))

(defun %ws-url-parts (url)
  "Return (values host port path https-p) for a ws/wss/http(s) URL."
  (let* ((uri (quri:uri url))
         (scheme (string-downcase (or (quri:uri-scheme uri) "ws")))
         (https-p (member scheme '("wss" "https") :test #'string=))
         (host (or (quri:uri-host uri)
                   (error 'ws-handshake-error
                          :message "WebSocket URL missing host")))
         (port (or (quri:uri-port uri) (if https-p 443 80)))
         (path (let ((p (or (quri:uri-path uri) "/"))
                     (q (quri:uri-query uri)))
                 (if q (format nil "~A?~A" p q) p))))
    (values host port path https-p)))

(defun %ws-header-block (headers protocols)
  "CRLF header block for WinHttpAddRequestHeaders."
  (with-output-to-string (out)
    (dolist (pair headers)
      (format out "~A: ~A~%" (car pair) (cdr pair)))
    (when protocols
      (format out "Sec-WebSocket-Protocol: ~{~A~^, ~}~%"
              (if (listp protocols) protocols (list protocols))))))

#+ (or win32 windows mswindows)
(defun %winhttp-ws-send-octets (hws octets buffer-type)
  "WinHttpWebSocketSend with a correct foreign copy (QL helper omits memcpy)."
  (let* ((vec (coerce octets '(vector (unsigned-byte 8))))
         (n (length vec))
         (btype (winhttp::get-buffer-type buffer-type)))
    (cffi:with-foreign-object (buf :uint8 n)
      (dotimes (i n)
        (setf (cffi:mem-aref buf :uint8 i) (aref vec i)))
      (let ((sts (winhttp::%websocket-send hws btype buf n)))
        (unless (zerop sts)
          (error 'ws-protocol-error
                 :message (format nil "WinHttpWebSocketSend failed status=~A" sts)))))))

#+ (or win32 windows mswindows)
(defun %winhttp-ws-fire (conn event &rest args)
  (let ((fn (gethash event (winhttp-ws-handlers conn))))
    (when fn (ignore-errors (apply fn args)))))

#+ (or win32 windows mswindows)
(defun %winhttp-ws-start-reader (conn)
  (setf (winhttp-ws-reader conn)
        (bt:make-thread
         (lambda ()
           (let ((buf (make-array 65536 :element-type '(unsigned-byte 8))))
             (loop
               (when (winhttp-ws-closed-p conn) (return))
               (handler-case
                   (multiple-value-bind (n type)
                       (winhttp:websocket-receive (winhttp-ws-handle conn) buf)
                     (case type
                       ((:utf8 :utf8-fragment)
                        (%winhttp-ws-fire
                         conn :message
                         (babel:octets-to-string buf :end n :encoding :utf-8)))
                       ((:binary :binary-fragment)
                        (%winhttp-ws-fire conn :message (subseq buf 0 n)))
                       (:close
                        (bt:with-lock-held ((winhttp-ws-lock conn))
                          (setf (winhttp-ws-closed-p conn) t
                                (ws-protocol:%connection-ready-state conn) :closed))
                        (%winhttp-ws-fire conn :close :code nil :reason nil)
                        (return))
                       (t nil)))
                 (error (e)
                   (bt:with-lock-held ((winhttp-ws-lock conn))
                     (setf (winhttp-ws-closed-p conn) t
                           (ws-protocol:%connection-ready-state conn) :closed))
                   (%winhttp-ws-fire conn :error e)
                   (return))))))
         :name "winhttp-ws-reader")))

#+ (or win32 windows mswindows)
(defmethod connect ((backend winhttp-backend) client url &key transport)
  (let ((resolved (resolve-ws-transport backend client :transport transport)))
    (unless (eq resolved :http/1.1)
      (error 'ws-transport-not-available
             :requested (or transport (ws-client-transport client))
             :negotiated resolved
             :message "WinHTTP WebSocket API is HTTP/1.1 Upgrade only"))
    (when (ws-client-proxy client)
      (error 'unsupported-operation :operation :proxy
             :message "WinHTTP WS proxy support is P2"))
    (multiple-value-bind (host port path https-p) (%ws-url-parts url)
      (let* ((headers (inject-auth-headers
                       (loop for pair in (ws-client-headers client)
                             for name = (string-downcase
                                         (string (if (consp pair) (car pair) pair)))
                             for value = (if (consp pair) (cdr pair) nil)
                             when value
                               collect (cons name (if (stringp value)
                                                      value
                                                      (princ-to-string value))))
                       :auth (ws-client-auth client)))
             (hdr-block (%ws-header-block headers (ws-client-protocols client)))
             (hsession nil)
             (hconnect nil)
             (hreq nil)
             (hws nil))
        (handler-case
            (progn
              (setf hsession (winhttp:http-open "http-backend-winhttp/ws" nil)
                    hconnect (winhttp:http-connect hsession host port)
                    hreq (winhttp:http-open-request hconnect
                                                    :verb "GET"
                                                    :url path
                                                    :https-p https-p))
              (winhttp:upgrade-to-websocket hreq)
              (unless (zerop (length hdr-block))
                (winhttp:add-request-headers hreq hdr-block))
              (winhttp:send-request hreq nil :end 0)
              (winhttp:receive-response hreq)
              (let ((status (winhttp:query-status-code hreq)))
                (unless (= status 101)
                  (error 'ws-handshake-error
                         :message (format nil "WinHTTP WS upgrade status ~A (want 101)"
                                          status))))
              (setf hws (winhttp:websocket-complete-upgrade hreq))
              ;; Request handle is done; keep session+connect for the WS handle lifetime.
              (winhttp:close-handle hreq)
              (setf hreq nil)
              (let ((conn (make-instance 'winhttp-ws-connection
                                         :url url
                                         :ready-state :open
                                         :handle hws
                                         :session hsession
                                         :connection hconnect)))
                (%winhttp-ws-start-reader conn)
                (%winhttp-ws-fire conn :open)
                conn))
          (error (e)
            (ignore-errors (when hws (winhttp:websocket-close hws)))
            (ignore-errors (when hreq (winhttp:close-handle hreq)))
            (ignore-errors (when hconnect (winhttp:close-handle hconnect)))
            (ignore-errors (when hsession (winhttp:close-handle hsession)))
            (if (typep e 'ws-error)
                (error e)
                (error 'ws-connection-error
                       :message (format nil "WinHTTP WS connect failed: ~A" e)))))))))

#-(or win32 windows mswindows)
(defmethod connect ((backend winhttp-backend) client url &key transport)
  (declare (ignore client url transport))
  (error 'unsupported-operation :operation 'connect
         :message "http-backend-winhttp WebSocket requires Windows + WinHTTP"))

#+ (or win32 windows mswindows)
(defmethod send-text ((connection winhttp-ws-connection) text &key)
  (%winhttp-ws-send-octets (winhttp-ws-handle connection)
                           (babel:string-to-octets text :encoding :utf-8)
                           :utf8))

#+ (or win32 windows mswindows)
(defmethod send-binary ((connection winhttp-ws-connection) octets &key)
  (%winhttp-ws-send-octets (winhttp-ws-handle connection) octets :binary))

#+ (or win32 windows mswindows)
(defmethod ping ((connection winhttp-ws-connection) &optional payload &key)
  (declare (ignore connection payload))
  (error 'unsupported-operation :operation 'ping
         :message "WinHTTP WebSocket API does not expose ping frames"))

#+ (or win32 windows mswindows)
(defmethod close-connection ((connection winhttp-ws-connection) &key code reason)
  (declare (ignore reason))
  (bt:with-lock-held ((winhttp-ws-lock connection))
    (unless (winhttp-ws-closed-p connection)
      (setf (winhttp-ws-closed-p connection) t
            (ws-protocol:%connection-ready-state connection) :closing)
      (ignore-errors
        (winhttp:websocket-close (winhttp-ws-handle connection) (or code 1000)))
      (ignore-errors (winhttp:close-handle (winhttp-ws-connection-handle connection)))
      (ignore-errors (winhttp:close-handle (winhttp-ws-session connection)))
      (setf (ws-protocol:%connection-ready-state connection) :closed)))
  t)

#+ (or win32 windows mswindows)
(defmethod on-event ((connection winhttp-ws-connection) event handler)
  (setf (gethash event (winhttp-ws-handlers connection)) handler))
