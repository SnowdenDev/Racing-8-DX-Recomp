# Wireless Play over a room: the guest dropped after a few seconds (fixed)

Status: **fixed and verified on Windows** (beta 2 engine, `d0922ea`). Patch: `patches/suyu/0004-trace-emulated-sockets-ldn.patch`.

## Symptom

Two games in one room (one hosts, one joins from the lobby list in Wireless Play):

- The guest sees the host's session, connects, and about 6 s later the game shows "A communication error has occurred"
  and goes back to the menu.
- Host log: `room traffic (2 s): N game packets sent, 0 received`, then `Disconnect packet received!`.
- Guest log: `0 game packets sent, 18 received`, then `Disconnect: called`.
- It did not depend on the machine (two games on one PC, or a second PC), on the profile, on the nickname, or on
  `KARTRECOMP_ROOM_FAST`.

## What the game did (from the traces in patch 0004)

After `Connect` the guest reached `StationConnected`, asked `GetIpv4Address` (192.168.1.2), created one UDP socket
(`socket(2, 2, 17)`), set `SO_BROADCAST`, bound it to port 12345 (`errno 0`), and the node list was right (2 nodes, both
connected). Then it **never read or wrote that socket again**: no `poll`, no `recvfrom` result, no `sendto`. It only polled
`GetState` / `GetNetworkInfo` / `GetIpv4Address` / `GetDisconnectReason` about ten times a second until it gave up.

The host, meanwhile, sent a 196-byte broadcast every ~115 ms to 192.168.1.255:12345 and those packets did reach the guest's
room client (`18 received` per 2 s), but not the guest's socket.

## Root cause

`BsdSockets::Shared()` (the process-wide socket table, `core/hle/service/sockets/bsd_sockets.cpp`) is built while the game
is being loaded. Its constructor binds the room's proxy packets to the table **only if the room client already exists**:

```cpp
BsdSockets::BsdSockets() {
    if (auto room_member = Network::GetRoomMember().lock()) {
        proxy_packet_received = room_member->BindOnProxyPacketReceived(...);
    } else {
        LOG_ERROR(Service, "Network isn't initialized");
    }
}
```

But in `suyu_cmd/suyu.cpp` the room client is created by `Network::Init()` **after** `system.Load()` (about line 2440).
So the constructor found no room client, logged `BsdSockets: Network isn't initialized` (this line is in every log, a
second or so before `Join: multiplayer: ...`), and never bound anything. The table is a function-local static, so it never
tried again. Packets from the room were received by the room client and thrown away; the game's sockets received nothing.

Sending worked (that is why Create Room and the host's broadcast looked fine), which hid the problem.

LDN packets (scan, connect, sync) use a different binding made in `ldn:u` `Initialize`, which runs later, so discovery and
the LDN handshake worked and only the game's own UDP traffic was lost.

## Fix

`BsdSockets::EnsureProxyBinding()`: bind the room's packets to the table the first time a socket is created
(`SocketImpl`), when the room client exists. A compare-and-swap makes it run once.

Files: `bsd_sockets.h` (declaration, `std::atomic<bool> proxy_bound`), `bsd_sockets.cpp` (constructor sets the flag,
`EnsureProxyBinding`, call at the top of `SocketImpl`).

Patch 0004 also keeps the diagnostic logging used to find this (it is cheap and stays useful):

- `bsd: socket / bind / connect / sendto / recvfrom / poll / setsockopt / fcntl` with arguments and results, for the first
  3000 calls (`recvfrom` only when it returned data or an error other than `EAGAIN`);
- `trace: GetNetworkInfo` (nodes, addresses, names) and `trace: GetIpv4Address`, logged when they change.

The same trace code was first put in `native_bsd.cpp` / `native_ldn.cpp`; it never ran, because **the Windows engine uses the
emulated kernel and the emulated `bsd:u` / `ldn:u` services** (the runtime kernel is off on Windows). Trace and fix live in the
shared socket library and in the emulated LDN service.

## How it was verified

Two engines on one PC (host with `KARTRECOMP_ROOM_HOST=24872`, guest with `KARTRECOMP_ROOM=nick@127.0.0.1:24872`), each with
its own full game folder, firmware and profile. With the fix:

- guest log: `bsd: room packets bound to the socket table`, then `socket`, `bind`, and 480 `recvfrom` + 480 `sendto` with
  data in about 80 s; host log the same;
- `room traffic (2 s)` about 27 sent / 27 received in both logs for the whole session (47 s to 133 s), no
  `Disconnect packet received!` until the players closed the games;
- the tester reported that the connection held instead of returning to the menu (the logs show the session up for about 85 s
  until the games were closed). A full race between the two games was not checked here.

Tested with `KARTRECOMP_ROOM_FAST=1` (host) and `15` (guest). Not tested with the default `0`, with a second PC, or with
more than two players.

## Second fix: `KARTRECOMP_PROFILE_NAME` was ignored on Windows (every lobby entry said "suyu")

Symptom: the launcher's "Profile name" (the `KARTRECOMP_PROFILE_NAME` variable) had no effect: Wireless Play's lobby
showed every player as `suyu`, the console profile's default name. The lobby shows the LDN node's user name, which the game
takes from its console profile.

Cause: the variable was applied only by the native services (`ApplyProfileName` in `native_services_list.cpp`, called when
the native `acc` service is built). The Windows engine runs the emulated kernel and services, so nothing ever read it.

Fix (also in patch 0004, `suyu_cmd/suyu.cpp`): right after `system.Load` returns and before the game runs, rename the
playing user's console profile (`ProfileManager::SetProfileBase`, saved in `profiles.dat`). It cuts to 10 characters, the
console's limit, without splitting a UTF-8 character. Log line: `kart-recomp: profile name 'suyu' -> 'GVHost'`.

Note: the rename is saved in `nand/system/save/8000000000000010/su/avators/profiles.dat`, so it persists after the variable is
removed. Two game folders that were copied from one another share the same profile id: give the copy its own profile by
deleting its `nand/system/save` folder (the firmware in `nand/system/Contents` stays).

## Random drops later in a session: tied to the frame rate (confirmed on one PC)

With the two fixes above a session holds through the lobby and several races (124 s, 190 s and 253 s in the last runs), but
it can still end with "A communication error has occurred", at random moments. What the traces show:

- The room link is healthy: `room traffic` lines now include ENet's round trip, loss and queues, and across 128 samples it was
  `rtt 1 ms, loss 0, lost 0, in flight 0 B, waiting to send 0, waiting for ack 0`. Nothing is delayed or lost by the room.
- Each drop is the **guest's game** calling `Disconnect` (its socket is closed first); the host then sees
  `Disconnect packet received!`. Both machines' traffic is normal right up to that moment.
- Both games stop sending for about 2 s every 5 s during a race (about 3 s of 340-byte packets at ~12 per second, then
  silence in both directions); no error is logged in those silences.
- Both games ran FSR 4 at a 3840x2160 internal size on one GPU (`upscale point: 3D 3840x2160 -> 3840x2160 with FSR 4`):
  frame pacing was 40 to 55 fps with hitches of 200 to 280 ms. The drops may come from two heavy games sharing one PC and not
  from the engine. **Not confirmed**: it needs a run with both games at low settings, or with the games on two machines.

Follow-up: the same two games, same engine, with both set to 720p and no upscaler (frame pacing 590+ of every 600 frames
under 17.5 ms, i.e. a steady 60 fps) held a session through two full races and more (the run was still going after 300 s,
no `Disconnect` on either side). The failing runs had FSR 4 at 3840x2160 internal size on one GPU, 40 to 55 fps, and the
laptop run (Intel graphics, 25 to 45 fps, half the packet rate of the host) dropped after 135 s. The only code change between
the failing and the working run was more logging, so the drops follow the machine's frame rate and not the room or the sockets.
Practical rule for Wireless Play over a room: each player needs a steady 60 fps (low resolution, no upscaler if needed).
Not tested: a slow player with the host at 60 fps for a long time, and a second PC with a capable GPU.

## Build (Windows only, local)

`packaging/windows/build-engine-local.ps1` builds only `mk8d-engine.exe` from the pinned suyu fork plus `patches/suyu`,
with Visual Studio's CMake and Ninja and the CI's MSVC toolset (14.40). Needs `glslangValidator.exe` (Vulkan SDK `Bin`
or a glslang release unpacked anywhere, `-Glslang <folder>`). Keep the work folder short (`D:\k`): the externals have very
long paths.

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\build-engine-local.ps1 -Work D:\k -Glslang D:\k\glslang\x\bin
```

The patches are CRLF (made on Windows), so the fork is checked out with `core.autocrlf=true`, as on the CI runner.
`packaging/windows/engine-version.pin` keeps the engine stamp of the beta 2 zip (`53264625f4-abi6`), so a game built with the
beta 2 engine is not rebuilt. **Build from `d0922ea` (beta 2) or a descendant that has the same module ABI.** Building from
`main` (beta 4) and pinning the beta 2 stamp gives an engine that does not match the game: a white window at start.

To use the engine: copy `mk8d-engine.exe` over `<game folder>\engine\mk8d-engine.exe`. No rebuild of the game is needed.

## Notes found on the way

- Deleting the `userdata\data\kartrecomp\nand` folder also deletes the firmware (`nand\system\Contents`); the game then runs
  with unmapped reads and `call to null`. The profile (name "suyu", user id) is in
  `nand\system\save\8000000000000010\su\avators\profiles.dat`.
- Logs are written in blocks: a running game shows only its first lines.
- Windows asks to allow `mk8d-engine.exe` on the private network the first time it hosts a room.
- Racing 8 DX beta 4 has the same `room_member.cpp` and `socket_proxy.cpp` as beta 2 (no change in the room code), so it
  has the same bug.
