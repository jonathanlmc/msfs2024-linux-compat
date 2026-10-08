# BeyondATC on Proton - findings & fix

## What this is

BeyondATC installs fine under Proton. Then it refuses to work: at login it says
"simulator is not running" while MSFS 2024 is open and flying right next to it.

BeyondATC talks to the sim over SimConnect, the data channel addons use. It
tries a Windows named pipe first, which is how SimConnect works on a real
Windows box. Under Wine that pipe does not exist outside the sim's own prefix,
so the connection never lands. No setting inside BeyondATC changes this. There
is nothing to calibrate, no firewall to open, no "run as admin".

`apply.sh` moves both sides to TCP. The sim gets a fixed local port, BeyondATC
gets a small file telling it to use that port, and the sim's original config is
kept as a backup. BeyondATC's own files are never touched, so BATC and sim
updates leave the fix alone.

_Note:_ you still need a real BeyondATC license. Login, purchase and update
flows run untouched; this is a transport fix, not a crack.
## What you need

- Steam (Flatpak or regular) with MSFS 2024 installed and launched at least
  once. The app id is **2537590**; `protontricks` lists it if you don't know.
- **BeyondATC installed into the MSFS 2024 prefix.** Run the Windows installer
  through `protontricks 2537590`, it works under Proton. The script looks for
  `BeyondATC.exe` in that prefix and stops if it is not there. It will not
  fetch BATC for you: beyondatc.net only links versioned zips, there is no
  stable URL to script against.
- bash, find, grep, python3. Standard on any desktop Linux.

## Simple instructions

Close the sim. In this folder:

```bash
# 1. Apply. Points the sim at a fixed local port, tells BeyondATC to use it,
#    keeps the sim's original file as SimConnect.xml.bak.
./apply.sh 2537590

# 2. Start MSFS 2024 from Steam, then start BeyondATC (exe.xml autolaunch works
#    too if you have it set up). They meet on 127.0.0.1:5111.
```

The sim only reads its SimConnect config at startup. Apply while the sim is
closed, then start it. Skipping the restart is the most common way this
"fails".

## Did it work?

BeyondATC gets past "simulator is not running" and starts talking to ATC.

For proof from the sim's side: put a `SimConnect.ini` next to `SimConnect.xml`
with `level=Verbose` and a `file=` path, relaunch, and the `simconnect*.log`
it writes shows the BATC client arriving on port 5111.

## If it does not work

- **Run `./apply.sh 2537590 --check` before guessing.** It prints what the
  prefix actually contains and changes nothing.
- **`BeyondATC.exe not found`.** BATC is not in this prefix. Install it with
  `protontricks 2537590`. BATC in its own prefix can still reach the sim over
  TCP, but the script only searches the prefix you give it, so copy the cfg
  there yourself.
- **Port 5111 taken.** Edit `PORT` at the top of `apply.sh`. Everything else
  follows from that constant.
- **Still "simulator is not running".** The sim was open when you applied, or
  BATC started before the sim reached the main menu. Kill leftover
  `BeyondATC.exe` processes, restart the sim, wait for the menu, then start
  BATC.
- **Undo.** `./apply.sh 2537590 --restore`. Original xml back, client file
  gone.

## When you need to run it again

The fix lives in the game's prefix. BATC updates and sim updates leave it
alone. Re-run when:

- the prefix is wiped or MSFS 2024 is reinstalled;
- a sim update rewrites `SimConnect.xml`;
- BATC is reinstalled into a different folder.

Re-running is safe. Already-fixed files are detected and skipped, and the
backup is never overwritten, so `--restore` always gets you back to the true
original.

## Gotchas

- **The sim-side change affects every addon, and that is fine.** It adds a TCP
  endpoint; the sim's default local servers still start, so pipe users like GSX
  carry on untouched.
- **Client count stays at the stock 64.** Raise it only if you hit the
  connection-starvation bug in `gsx/docs/internals.md`. BATC alone never needs
  it.
- **One client file, beside the exe.** A cfg beside a different addon's exe
  applies to that addon, if it reads cfgs at all. GSX's engine does not; see
  `gsx/docs/internals.md`.

## Deep dives

- **Why the pipe fails.** SimConnect clients default to
  `\\.\pipe\Microsoft Flight Simulator\SimConnect`. Wine implements named pipes
  per wineserver, i.e. per prefix, and a process in another prefix cannot open
  the sim's pipe. Measured on this machine: the pipe open returns err=2, TCP on
  5111 connects.
- **What `apply.sh` writes.** Server side: in the sim's `SimConnect.xml` it
  rewrites only the first IPv4 comm's `<Port>` to 5111; an IPv4 comm is appended
  only when the file has none, in the same shape the sim generates itself, and
  everything else in the file is left as it was. Client side: `SimConnect.cfg`
  beside `BeyondATC.exe`, the per-client transport override the MSFS 2024 docs
  define as living in the client application's folder. cfgs in `Documents` or
  `AppData` belong to MSFS 2020's old search order; 2024 does not consult them.
- `gsx/docs/internals.md`, "SimConnect transport (MSFS 2024)" - the measured
  pipe failure, the TCP setup, and the MaxClients pool bug.
- MSFS 2024 SDK docs: [SimConnect CFG
  Definition](https://docs.flightsimulator.com/msfs2024/html/6_Programming_APIs/SimConnect/SimConnect_CFG_Definition.htm)
  and [SimConnect XML
  Definition](https://docs.flightsimulator.com/msfs2024/html/6_Programming_APIs/SimConnect/SimConnect_XML_Definition.htm).
