# For Parallel 42 and Wine: fixing this upstream

Each item is a change inside someone else's product that would remove the need for
prefix surgery by Proton users. Everything cited was observed in a Proton prefix and
checked against the sources named inline; see `internals.md` for the evidence.

## Parallel 42 (ChasePlane bridge)

1. **Do not use `HttpListener` for the panel WebSocket.** The 8652 server inherits the
   http.sys and WSPC dependency of .NET's windows `HttpListener` build, which is the
   single reason ChasePlane cannot work under Wine. Fix: serve 8652 with a `TcpListener`
   plus a small RFC 6455 handshake, or reuse the existing 8651 raw TCP transport for the
   panel protocol. The bridge already ships a raw TCP fallback for 8651, so the pattern
   and the framing code are already in the codebase; only the WebSocket side lacks one.
2. **Do not emit IPv6 literal prefixes.** The bridge adds `http://[::1]:8651/` always,
   and `http://[::1]:8652/` when LAN bindings are off. Those two prefixes are what break
   under any non-Windows `HttpListener` (its port parser cannot handle a bracketed
   address), and a wildcard `+` needs urlacl grants on Windows anyway. Fix: bind
   `http://127.0.0.1:<port>/` plus explicit LAN addresses, and skip the `[::1]` literal.
3. **Report the WebSocket failure as a state.** Today the failure surfaces as a
   `TypeInitializationException` inside a generic "Error handling request" log line, and
   the visible symptom is a panel that cannot connect with no hint that the camera engine
   is missing. Fix: detect `WebSocketProtocolComponent.IsSupported` (it is public
   behaviour of the type, and `HttpListener.GetContext` already fails on it) and log an
   explicit "WebSocket transport unavailable, camera engine not started" state, plus a
   documented fallback path. That turns a class of unreportable bug into a one-line bug
   report.

## Wine

4. **Implement `websocket.dll`.** `dlls/websocket/websocket.spec` marks 10 of 13 exports
   `@ stub`, and the three declared ones are `FIXME` stubs in `dlls/websocket/websocket.c`,
   `WebSocketCreateClientHandle` returning `E_NOTIMPL`. That is the exact call .NET uses to
   probe WebSocket support, so it breaks every .NET `HttpListener` WebSocket server under
   Wine, not just ChasePlane. Fix: implement `WebSocketCreateClientHandle`,
   `WebSocketCreateServerHandle`, `WebSocketBeginServerHandshake`,
   `WebSocketEndServerHandshake`, `WebSocketGetAction`, `WebSocketCompleteAction`,
   `WebSocketSend`, `WebSocketReceive`, `WebSocketAbortHandle`, `WebSocketDeleteHandle`.
   Wine already has a working WebSocket client inside `winhttp.dll` (real
   `.text$WinHttpWebSocket*` code, no stub thunks), so the framing logic exists in-tree to
   share.
5. **Implement `httpapi.dll!HttpCancelHttpRequest`.** It is in the export table but aborts
   as an unimplemented function, and .NET hits it on the request-abort path. Any Wine-side
   fix for .NET HTTP servers needs it alongside item 4.
