# http-backend-winhttp

MIT. Windows [`http-protocol`](https://github.com/egao1980/http-protocol) backend over **WinHTTP**.

## Focus

| Feature | Implementation |
|---------|----------------|
| True async I/O | `WINHTTP_FLAG_ASYNC` + status callbacks |
| Event loop | Completions/`wake`+`defer` onto `event-protocol` (libuv) |
| `:want-stream` | Gray `winhttp-body-input-stream` fed from `READ_COMPLETE` |
| Cancel | `WinHttpCloseHandle` on the request → `http-canceled` |
| System proxy | `use-os-automatic-proxy-p` → `AUTOMATIC_PROXY` |
| Proxy auth | Basic + NTLM + Negotiate/SSO (dexador#202) |
| SOCKS | Unsupported → use `http-backend-async` |
| Pooling | WinHTTP session keep-alive (not Lisp LRU) |
| Retries | Protocol `http-retry` around `SEND` |

```lisp
#+windows
(progn
  (asdf:load-system "event-backend-libuv")
  (asdf:load-system "http-backend-winhttp")
  (setf http-backend-winhttp:*event-backend-maker*
        #'event-backend-libuv:make-libuv-backend)
  (let ((*http-backend* (http-backend-winhttp:make-winhttp-backend)))
    (http:get "https://intranet.example/")))
```

Non-Windows: library loads; `make-winhttp-backend` signals `unsupported-operation`.
