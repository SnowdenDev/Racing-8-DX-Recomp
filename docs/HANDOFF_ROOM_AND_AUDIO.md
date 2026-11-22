# Handoff: Wireless Play over a room + audio-device bugs (Racing-8-DX-Recomp, Windows, beta 2 engine)

Written 2026-11-22 for another engineer / AI that will take over. Read this first, then `docs/ROOM_PACKETS_FIX.md`
(details of the room fix and the first profile-name fix).

Fork: https://github.com/SnowdenDev/Racing-8-DX-Recomp, branch `fix-room-guest-beta2` (based on upstream commit `d0922ea`,
the beta 2 engine; ENGINE_VERSION `53264625f4-abi6`). The branch `fix-room-guest` (based on main / beta 4) is obsolete.

## 0. Goal and constraints (from the owner)

- Goal: two-player Mario Kart 8 Deluxe "Wireless Play" through a suyu/yuzu room server (ENet, UDP 24872), to be integrated
  later in GameVerse (host and guest on the same virtual LAN; profile name comes from the launcher).
- Build ONLY the Windows engine, locally on the owner's PC. Do NOT use GitHub Actions (the owner objected). Linux and the
  rest do not matter.
- The owner dislikes iteration: read code and logs, reason, fix. Do NOT launch the games "just to see". Ask the owner to
  run a test when a diagnostic needs one (they run the `.bat` files below).
- Windows uses the EMULATED kernel and services (`bsd:u`, `ldn:u`, `acc`). The "native" services and `native_*.cpp` do not
  run on Windows: do not put code there.

## 1. State of the problems

| # | Problem | State |
|---|---------|-------|
| 1 | Guest dropped ~6 s after joining (room packets never reached game sockets) | FIXED, verified (patch 0004, `EnsureProxyBinding`) |
| 2 | Every lobby entry said "suyu" (`KARTRECOMP_PROFILE_NAME` ignored) | FIXED, verified (patch 0004, rename in `suyu_cmd/suyu.cpp`) |
| 3 | Random "communication error" mid-session | Probably the audio device being lost (see 3). Cubeb "keeper" written, built, NOT tested mid-race |
| 4 | With NO audio device present at start, the game stays on the title screen forever | OPEN, root cause identified (see 4), fix not written |

## 2. Fixes already done (all inside `patches/suyu/0004-trace-emulated-sockets-ldn.patch`)

1. `core/hle/service/sockets/bsd_sockets.{h,cpp}`: `BsdSockets::EnsureProxyBinding()` binds the room's proxy packets to
   the socket table on the first `socket()` call. Before: the table is built during `system.Load()`, the room client is
   created later by `Network::Init()` (`suyu_cmd/suyu.cpp` ~line 2440), the constructor saw no room client
   (`BsdSockets: Network isn't initialized`) and never bound. See `ROOM_PACKETS_FIX.md`.
2. `suyu_cmd/suyu.cpp`: after `system.Load`, rename the playing user's profile to `KARTRECOMP_PROFILE_NAME`
   (`ProfileManager::SetProfileBase`, 10 chars max).
3. Diagnostics kept in the patch: `bsd:` socket call traces (first 400000 calls, first 12 bytes of each datagram in hex),
   LDN `GetNetworkInfo`/`GetIpv4Address` traces, and ENet stats in the `room traffic (2 s)` log lines
   (`room_member.cpp`, `LogProxyTraffic(ENetPeer*)`: rtt, loss, queues).
4. `audio_core/sink/cubeb_sink.cpp`: "keeper" thread (details in section 3).

## 3. Audio device lost mid-session (suspected cause of random disconnects)

Owner's observation: muting or disabling the speakers/headphones (or turning headphones off so the PC has no adapter)
freezes the game; one real drop in a race coincided with turning the headphones off. Frame rate was ruled out
("no son los fps"; the earlier fps theory in `ROOM_PACKETS_FIX.md` is partly wrong, see its corrected section).

Why it matters: the game's audio thread waits for the sink to consume buffers. If the host audio device disappears,
cubeb stops calling the data callback. The audio-out buffers are never released, the game stalls, stops answering the
LDN/room traffic, and the peer sees a disconnect.

Facts from the code (`src/audio_core`):

- `DeviceSession::IsBufferConsumed`: `played_sample_count >= buffer.end_timestamp` (`device/device_session.cpp:120`).
- `DeviceSession::ThreadFunc` (`:133`): `played_sample_count = stream->GetExpectedPlayedSampleCount()`, then signals the
  audio manager event that releases buffers.
- `SinkStream::GetExpectedPlayedSampleCount()` (`sink/sink_stream.cpp:224`):
  `min(min_played + rate * (now - last_update), max_played) + TargetSampleCount * 5`.
  `min_played`/`max_played`/`last_update` are advanced ONLY inside `ProcessAudioOutAndRender` (and the in variant),
  which is called from the sink's device callback.
- So when the callback stops, `max_played` stops advancing, the expected count saturates, the buffers behind it are never
  "consumed" and never released.
- Cubeb's `StateCallback` was ignored (no handling of `CUBEB_STATE_ERROR`).

Keeper (in `cubeb_sink.cpp`, built into `D:\k\engine\mk8d-engine.exe`, NOT tested in a race):

- a thread wakes every 4 ms; stalled = no stream || `failed` flag (set from `StateCallback` on error) || no data callback
  for 300 ms;
- while stalled it drains `ProcessAudioOutAndRender(scratch, TargetSampleCount)` at real-time pace (up to 40 chunks per
  wake) so the played counts advance and the game keeps running silently;
- every 2 s it tries to reopen the stream; logs `audio output stream {} is not asking for samples: consuming silently`,
  `is back`, `re-opened`;
- Finalize joins the thread and nulls the stream; Start/Stop are guarded by a mutex and null-stream checks.

To test (owner runs it): start both games, enter a race, disable the playback device in Windows (or unplug headphones),
wait 10 s, re-enable. Expected: the game keeps running, the log shows the "consuming silently" lines, no disconnect.
Remember logs are block-buffered (section 6).

## 4. OPEN BUG: no audio device at startup -> stuck on the title screen

Reproduction: disable ALL playback devices in Windows (the owner has only virtual ones left, e.g. Steam Streaming Speakers,
Virtual Desktop Audio, NVIDIA Virtual Audio), start host and guest with `kr_two.bat`. Both processes stay alive
(~330 % CPU, Responding), the log shows the render loop running at 60 fps with ~35 draws/frame,
`ServiceQuitRequests: kart-recomp: title screen passed` appears (guest at 30.3 s), but the screen still shows the
"MARIO KART 8 DELUXE" title after pressing buttons on both games. (Owner screenshot: title screen, "Press any button".)

Log lines at startup in this situation:

```
GetCubebLatency: cubeb_init failed
Auto-selecting the sdl3 backend            (sink_details.cpp: cubeb_init failure falls back to sdl3)
SDLSinkStream: SDL audio device unavailable (No default audio device available); using silent output
```

Root cause (code read, NOT yet proven by a run): in `sink/sdl3_sink.cpp` (`SDLSinkStream::AppendBuffer`, ~line 112):

```cpp
void AppendBuffer(SinkBuffer& buffer, std::span<s16> samples) override {
    // If SDL could not open a device, no callback will drain the queue.
    // Discard audio as the null sink does so the ADSP cannot block forever.
    if (stream == nullptr) {
        return;
    }
    SinkStream::AppendBuffer(buffer, samples);
}
```

and `Start()`/`Stop()` return immediately when `stream == nullptr`. With the buffer dropped before `SinkStream::AppendBuffer`
and no one ever calling `ProcessAudioOutAndRender`, `max_played_sample_count` never moves. Then
`GetExpectedPlayedSampleCount()` stays at `5 * TargetSampleCount`, so every audio-out buffer whose `end_timestamp` is above
that is never consumed (`IsBufferConsumed`), `ReleaseBuffers` never returns it, and whatever waits on audio (title/menu
logic) never advances. The comment in the code assumes a null sink does not block; for audio-out buffers that assumption
looks wrong because of the played-count accounting above.

Suggested fix (same idea as the cubeb keeper): when the SDL stream is null, do NOT drop buffers. Call
`SinkStream::AppendBuffer` normally and run a real-time-paced drain thread that calls
`ProcessAudioOutAndRender(scratch, TargetSampleCount)` (same loop as `CubebSinkStream::Keeper`). Best done by moving the
keeper into a shared helper used by both sinks, and by making the same drain also run when the sink is the explicit null sink.
Also check `NullSink` (`sink/null_sink.h`): its `AppendBuffer` is a no-op; if the game works with it, find out why
(maybe the audio renderer path, not audio-out, is what the game uses) before assuming the theory is complete.

How to prove/disprove before patching: add a log in `DeviceSession::ThreadFunc` printing `played_sample_count` and the
oldest queued `end_timestamp` once per second; with no device, the first should stay constant and below the second.
Alternative check: run with devices enabled and `--audio_sink null` (or the equivalent config) and see if it also sticks.

## 5. How to build and test (Windows, local)

Source tree used for builds: `D:\k\fork` (suyu at sha `5949cab3ba93233ddd1c319bfc6f010f6cfa910a` + `patches/suyu/*.patch`).
Env: Visual Studio 18 Community, MSVC toolset 14.40 (`-vcvars_ver=14.40`), VS's CMake and Ninja, glslang 16.6.0 in
`D:\k\glslang\x\bin` (copy `glslang.exe` to `glslangValidator.exe`). Keep the work dir short: `D:\k`.

Full build (~25 min first time, minutes incremental):

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\build-engine-local.ps1 -Work D:\k -Glslang D:\k\glslang\x\bin
```

Output `D:\k\engine\mk8d-engine.exe`; copy it over `<game folder>\engine\mk8d-engine.exe` (no game rebuild needed).
Patches are CRLF; the tree is cloned with `core.autocrlf=true`. cmake configure sometimes fails on a cut download: rerun.
Build from `d0922ea` or a descendant with the same module ABI; building `main` (beta 4) with the beta 2 stamp gives a
white window.

Editing workflow for the patch: edit files in `D:\k\fork`, rebuild incrementally, test, then regenerate patch 0004 with the
script `make_patch4.py` kept by the previous session (revert old 0004 with `git apply -R`, run
`python -I make_patch4.py <patch path>`, `git apply --check`, apply, rebuild). If you do not have that script, regenerate
the patch with `git diff` against the pinned suyu sha for the files listed in section 2, keeping CRLF.

Two-game test on one PC (the owner runs these `.bat` files; they live in the previous session's scratchpad
`C:\Users\SnowdenDev\AppData\Local\Temp\claude\e610502bc52148c0\ed9922e8-652f-41cf-a2f8-f9704375e328\scratchpad\`):

- `kr_two.bat [HOST_FAST] [GUEST_FAST]`: host from `D:\Nueva carpeta (3)\kartrecomp-0.2.5-beta2-download\KartRecomp-windows-x64\KartRecomp`,
  guest = full copy in `D:\Nueva carpeta (3)\kartrecomp-guest\KartRecomp` (own firmware and profile). Sets
  `KARTRECOMP_PROFILE_NAME` GVHost/GVGuest, room GVTest on UDP 24872, guest joins `GVGuest1@127.0.0.1:24872`.
  `KARTRECOMP_ROOM_FAST` should stay empty (default 0); it was used in early tests and is not needed.
- `kr_host.bat`: host only with default settings (for a real second machine).
- Env summary: `KARTRECOMP_ROOM_HOST=port[:pass]` (+ `_ROOM_NICK`, `_ROOM_NAME`, `_ROOM_MAX`), `KARTRECOMP_ROOM=nick[:pass]@host:port`,
  `KARTRECOMP_PROFILE_NAME`, `KARTRECOMP_APP_NAME=kartrecomp`, `XDG_DATA_HOME/CACHE_HOME/CONFIG_HOME` = `<game>\userdata\{data,cache,config}`,
  engine args `--module-dir --content-base --content-update --content-dlc`.
- Logs: `<game>\userdata\data\kartrecomp\log\suyu_log.txt`, console in `host-console.log` / `guest-console.log`.
- The data folders are owned by Administrators; the games need an elevated launcher (`Permission denied` on romfs otherwise).
- Zips for the owner's laptop (Intel iGPU), in `D:\Nueva carpeta (3)\kartrecomp-0.2.5-beta2-download\`:
  `laptop-engine-update.zip` (new engine + clean launch.env), `laptop-low-quality.zip`, `laptop-firmware-fix.zip`.

## 6. Log-reading gotchas

- Engine logs are written in blocks and flushed on exit: a running game shows only its first lines. Silence in the log is
  not proof of a freeze. Close the game (or wait) before reading.
- `room traffic (2 s)` lines show ENet rtt/loss/queues. In every sample the link was healthy (rtt 1 ms, loss 0). The room
  server is not the problem.
- Each disconnect seen so far was the GUEST game calling `Disconnect` (socket closed first); the host then logs
  `Disconnect packet received!`.
- During races both games send for ~3 s (340-byte packets, ~12/s) then are silent ~2 s, repeating every 5 s. Cause not
  found; no error logged. It may be game behavior. Not confirmed either way.

## 7. Ruled out / retracted

- Same-PC artifact: no (also happened with a real second PC, though that run had a slow GPU).
- Profile UUID clash: fixed by giving the copy its own profile, did not stop random drops.
- `KARTRECOMP_ROOM_FAST`: not the cause; keep default.
- Frame rate as the only cause: 720p/no upscaler (steady 60 fps) held long sessions, but the owner later got drops with
  good fps and tied them to audio device loss. Treat low fps as a possible aggravating factor, not the root cause.
- Native `bsd`/`ldn` instrumentation: never runs on Windows.

## 8. Still untested

- Keeper behavior when the device is lost mid-race (section 3).
- Fix for problem 4 (not written).
- Two real machines with the new engine (laptop has Intel graphics; earlier laptop runs used the old engine builds).
- More than two players; a full race on default settings with both players on separate PCs.
- GameVerse integration: host/guest over the virtual network IP, UDP 24872, profile name from GV. Not started.
- Upstream PR to https://github.com/galarianpikachu2021-hue/Racing-8-DX-Recomp: not sent (needs the owner's decision).
- License: GPL-3.0; GameVerse must not host the game, the user builds it from their own dump.
