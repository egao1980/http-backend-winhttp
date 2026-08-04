# http-backend-winhttp

MIT. Windows [`http-protocol`](https://github.com/egao1980/http-protocol) backend over **WinHTTP**.

## Focus

| Feature | Implementation |
|---------|----------------|
| True async I/O | `WINHTTP_FLAG_ASYNC` + status callbacks |
| Event loop | Completions/`wake`+`defer` onto `event-protocol` (libuv) |
| Download stream | `:want-stream` → Gray `winhttp-body-input-stream` + backpressure (`READ_COMPLETE`) |
| Upload stream | `streamp` body → `SendRequest` (headers) + `WinHttpWriteData` (`WRITE_COMPLETE`) |
| Chunked upload | unknown length → `Transfer-Encoding: chunked` + `WINHTTP_IGNORE_REQUEST_TOTAL_LENGTH` |
| Bodies | `http-protocol` ≥ **0.2.0** `:form-data` / typed `:data` / `:content` via `prepare-request-body` |
| Cancel | `WinHttpCloseHandle` on the request → `http-canceled` |
| System proxy | `use-os-automatic-proxy-p` → `AUTOMATIC_PROXY` |
| Proxy auth | Basic + NTLM + Negotiate/SSO (dexador#202) |
| SOCKS | Unsupported → use `http-backend-async` |
| Pooling | WinHTTP session keep-alive (not Lisp LRU) |
| Retries | Protocol `http-retry` around `SEND` |
| WebSocket | `ws-backend` — RFC 6455 Upgrade via `WinHttpWebSocket*` (`:http/1.1`; not RFC 8441) |

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

## CI / deps

No sibling checkouts. Workflow checkouts **only this repo**; bootstraps `cl-repository-client` from OCI (`ghcr.io/egao1980/cl-repository/cl-repository-client:0.10.0`); project deps via `ghcr.io/egao1980/cl-systems` (`scripts/ci-install.lisp` / `ci-test.lisp`). Matrix: `windows-latest` (primary) + `ubuntu-latest` (stubs).

## Publish

Source-only OCI publish is centralized in [`cl-stack-systems`](https://github.com/egao1980/cl-stack-systems)
(`imports/http-backend-winhttp/qlfile` pin + shared `publish.yml`). Packaging metadata lives in the `.asd`
(`auto-package-spec`):

```bash
gh workflow run publish.yml -R egao1980/cl-stack-systems -f import=http-backend-winhttp
```

