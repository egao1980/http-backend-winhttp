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
