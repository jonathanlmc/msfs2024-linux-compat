# Internals: what breaks, why, and how the fix works

Technical companion to `../README.md`. Everything here was observed in a Proton
prefix and checked against the published sources named inline.

## Symptom chain

1. The in-sim panel reports "can't connect to bridge module".
2. The bridge log shows, for every upgrade attempt on 8652:

   ```
   WS: Initializing server with prefix http://+:8652/
   WS: HttpListener server started.
   WS: Error handling request: The type initializer for
       'System.Net.WebSockets.WebSocketProtocolComponent' threw an exception.
   ```

3. No WebSocket client ever gets validated, so the bridge never reaches its Helper
   path and never injects `CP.dll`. The sim's `loaddll` records contain
   `CP MSFS Bridge.exe`, `SimConnect.dll` and
   `Microsoft.FlightSimulator.SimConnect.dll`, and nothing for
   `Modules\ChasePlane\CP.dll` or `Helper.dll`. ChasePlane is a WASM shell with no
   camera engine.
4. Panel auth is downstream, not a second gate: `Auth: UINFO received from toolbar:
   <user>` arrives over the `Toolbar` WebSocket client, so the "reauth required"
   state resolves once 8652 works.

## Root cause: Wine's `websocket.dll` is a stub

.NET's windows `HttpListener` build does not implement WebSocket framing itself. It
loads the Windows WebSocket Protocol Component (WSPC), which is `websocket.dll`. The
DLL name strings in the shipped assembly are `httpapi.dll`, `kernel32.dll` and
`websocket.dll`.

`WebSocketProtocolComponent`'s static constructor (dotnet/runtime
`src/libraries/System.Net.HttpListener/src/System/Net/Windows/WebSockets/WebSocketProtocolComponent.cs`,
v8.0.31) does this:

1. `LoadLibraryEx("websocket.dll")`. If it fails, the type is simply unsupported and
   later calls throw `PlatformNotSupportedException`.
2. If it loads, probe it: `WebSocketCreateClientHandle(null, 0, out handle)` then
   `WebSocketBeginClientHandshake(...)` with a canned client request, to read the
   supported `Sec-WebSocket-Version`.
3. `ThrowOnError` turns any non-zero error code into an exception. It runs inside the
   static constructor, so a failure there surfaces as `TypeInitializationException`
   for every later use of the type.

Wine ships `websocket.dll`, but it has no implementation. `dlls/websocket/websocket.spec`
marks 10 of its 13 exports `@ stub` (`WebSocketBeginClientHandshake`,
`WebSocketBeginServerHandshake`, `WebSocketCompleteAction`, `WebSocketCreateServerHandle`,
`WebSocketEndClientHandshake`, `WebSocketEndServerHandshake`, `WebSocketGetAction`,
`WebSocketGetGlobalProperty`, `WebSocketReceive`, `WebSocketSend`). The three that are
declared are `FIXME` stubs in `dlls/websocket/websocket.c`, and `WebSocketCreateClientHandle`
returns `E_NOTIMPL`. The shipped binary confirms it: the export thunks are named
`__wine_stub_WebSocketBeginClientHandshake` and so on.

So step 2 throws, the type initializer fails, and 8652 never completes a handshake.
That single failure is the whole ChasePlane failure.

`httpapi.dll` is a separate gap, not this one. Wine implements the HTTP core (75
`Http*` exports, none of them WebSocket, which .NET does not need for framing), and
`HttpCancelHttpRequest` aborts as an unimplemented function. It is hit on the
request-abort path (it recurs repeatedly in a session's console log) and .NET's SEH
dispatch absorbs it.

Not the problem: Wine's WinHTTP WebSocket **client** is real. `winhttp.dll` contains
`.text$WinHttpWebSocketClose/CompleteUpgrade/QueryCloseStatus/Receive/Send/Shutdown`
and no stub thunks, which is why `CP.dll`'s `WinHttpWebSocket*` imports resolve fine
once the module is loaded.

## Why the naive file swap does not load

The `net8.0-unix` build of the same assembly is a pure-socket `HttpListener` whose
`AcceptWebSocketAsyncCore` completes the handshake with
`WebSocket.CreateFromStream(..., isServer: true, ...)` and never loads
`websocket.dll` or touches `httpapi.dll`. Copying it over the windows build is not
enough, because of PE layout rather than .NET:

| layout | result |
|---|---|
| VA != raw, SectAlign `0x200` | `BadImageFormatException` naming the file |
| VA != raw, SectAlign `0x1000` | `FileNotFoundException` naming the assembly identity |
| VA == raw, SectAlign `0x200` | loads and runs |

The unix build is emitted with `SectionAlignment = FileAlignment = 0x200` and
`VirtualAddress != PointerToRawData` for every section (.text VA `0x10200` / raw
`0x200`, .data `0x66c00` / `0x36c00`, .reloc `0x95600` / `0x45600`). The windows build
has `0x1000/0x1000` with VA equal to raw. CoreCLR under Wine accepts only the second
shape.

`patch_httplistener.py` sets the machine from `0xfd1d`, which is what the linux-x64
package ships and is not x86-64, to `0x8664`, and moves each section's bytes to the address
it already occupies in memory, repointing `PointerToRawData` and the Authenticode
overlay. No RVA moves, so the COR20 header, metadata, base relocations, exception
directory and resources stay valid. It then resolves the COR20 header and the `BSJB`
metadata root through the new section map as a self-check.

Neither build is ReadyToRun (`COR20 cb=72`, `ManagedNativeHeader` and
`ILToNativeMapTable` zero, no `R2R!` signature), and strong names are irrelevant:
both carry a zeroed 128-byte signature and CoreCLR verifies nothing.

## Why ReadyToRun has to be off

With the re-laid-out assembly installed and nothing else changed, the bridge aborts
with `AccessViolationException` on a fault inside a native module in the `clrjit` range.
With `DOTNET_ReadyToRun=0` the same file runs cleanly through HTTP startup. Since neither
HttpListener build is R2R, the flag is suppressing precompiled
code in the *other* framework assemblies; which one has not been identified. The
launch option is the cheap, reversible control.

## The managed listener's IPv6 prefix bug

`HttpEndPointManager.AddPrefixInternal` (dotnet/runtime v8.0.31,
`src/libraries/System.Net.HttpListener/src/System/Net/Managed/HttpEndPointManager.cs`)
locates the port with `p.IndexOf(':', p.IndexOf(':') + 3)`. For `http://[::1]:8651/`
that lands on the colon *inside* `[::1]`, so the port string is `":1]:865"`, parsing
fails, and `Start()` throws `HttpListenerException(400, "Invalid port in prefix")`.
Observed as:

```
HTTP: Added prefix: http://localhost:8651/
HTTP: Added prefix: http://127.0.0.1:8651/
HTTP: Added prefix: http://[::1]:8651/
HTTP: Calling HttpListener.Start()...
HTTP: Error starting listener: One or more errors occurred. (Invalid port in prefix.)
HTTP: Raw TCP server listening on 0.0.0.0:8651
```

`+` and `*` map to `IPAddress.Any` and parse fine. Consequences: 8651 always falls
back to the bridge's raw TCP server (the panel tolerates it), and 8652 needs ChasePlane's
LAN bindings on so it binds `http://+:8652/`. With LAN bindings off the bridge adds
`http://[::1]:8652/` and the WebSocket listener fails exactly as it did before the swap.

## What the swap does not touch

No ChasePlane file, no registry key, no Wine or Proton file, no sim setting. The only
outside change is the `DOTNET_ReadyToRun=0` environment variable, set as a Steam launch
option and inherited by the bridge the sim spawns.

## Confirming it worked, at log level

```
WS: Initializing server with prefix http://+:8652/
SimConnect: Connected to Flight Simulator!
WS: Client (n) categorized as Private with name 'Toolbar'.
Auth: UINFO received from toolbar: <user>
Helper: Cameras connected for generation 1: <n>
WS: Client (n) categorized as Private with name 'CP_DLL'.
```

`CP_DLL` is the decisive line: that client only exists once the injected `CP.dll` is
running inside the sim. In `msfs_console.log` (needs `WINEDEBUG=+loaddll`) the matching
records are `Modules\ChasePlane\CP.dll`, `Helper.dll`, `CPLifetimeHost.dll` and
`SDL3.dll`, with no `WebSocketProtocolComponent`, `HttpCancelHttpRequest`,
`BadImageFormatException` or `AccessViolationException` lines. Whole-file greps keep
reporting the pre-fix failures from earlier sessions, so only the region a session
appended is meaningful.
