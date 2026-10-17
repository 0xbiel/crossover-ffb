# Shared memory v2

File `/tmp/crossover-ffb-<uid>/ffb-v2.bin` (8192 bytes, 0600, never truncated or replaced),
created by the app and opened by the DLL as `Z:\tmp\crossover-ffb-<uid>\ffb-v2.bin` with
`CreateFileMapping`/`MapViewOfFile`; Wine maps it `MAP_SHARED`. Little-endian. Each block starts
with a seqlock counter: odd while the writer is updating, readers retry until it is even and
unchanged. Source of truth: `bridge/shm.h` and `Sources/WheelCore/SharedBridge.swift`.

| Offset | Writer | Field |
|---|---|---|
| 0 | app | magic `CFB2`, u32 version 2, u32 size 8192 (an old 4096-byte file is grown, the DLL then skips telemetry) |
| 64 | app | input seqlock |
| 68 / 72 | app | connected u32 / heartbeat Unix ms u64 (stale > 500 ms = input lost) |
| 80…92 | app | steering, accelerator, brake, clutch (u32 0…65535, pedals as reported by HID) |
| 96 / 100 | app | buttons 1…25 bitmask / hat 0…7 clockwise from north, 8 = centred |
| 256 | DLL | force seqlock |
| 260 / 264 | DLL | Windows PID / heartbeat Unix ms u64 (every Poll/GetDeviceState) |
| 272 / 276 / 280 | DLL | acquired / device gain 0…10000 / flags: 1 paused, 2 actuators off, 4 autocenter |
| 320 + 96·n | DLL | 32 effect records |
| 4096 | DLL | telemetry seqlock |
| 4100 / 4104 / 4112 | DLL | source (1 = AC/ACC `Local\acpmf_physics`, 2 = AC EVO `Local\acevo_pmf_physics`) / length (800) / copied at Unix ms u64 |
| 4120 | DLL | car max rpm u32 from the static page (`Local\acpmf_static` / `Local\acevo_pmf_static`, offset 412), 0 if unknown; drives the rev lights |
| 4128… | DLL | raw page, copied on every Poll/GetDeviceState whose page packetId changed |

Effect record (u32/i32 words): 0 kind (1 constant, 2 ramp, 3 square, 4 sine, 5 triangle,
6 saw up, 7 saw down, 8 spring, 9 damper, 10 inertia, 11 friction; 0 empty), 1 playing,
2 start counter (changes on every Start), 3 duration µs (0xffffffff infinite), 4 start delay µs,
5 gain, 6 coordinate flags (0x10 cartesian, 0x20 polar, 0x40 spherical), 7 axis count,
8 index of the steering axis, 9–10 direction, 11 has envelope, 12–15 attack level/time,
fade level/time, 16–21 type-specific parameters (constant: magnitude; ramp: start, end;
periodic: magnitude, offset, phase, period; condition for the steering axis: offset,
+coefficient, −coefficient, +saturation, −saturation, dead band), 22 iterations.

Telemetry is read by `GameTelemetry.acPhysics` (word indices of `SPageFilePhysics`: 0 packetId,
1 gas, 5 rpm (int), 7 speed km/h, 46–49 suspension travel, 195 engine running, 196–199 kerb,
slip, g (AC EVO: road) and ABS vibration levels) and drives the simulated TrueForce synthesizer.

The DLL builds the Wine path from the digits after `CFBUID=` in its data section. The app's
installer (`BridgeInstaller`) writes the Mac user's uid there when it copies the DLL into a game,
so one build serves every user.
