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
| 68 / 72 | app | connected flags u32 (0 disconnected, 1 legacy connected, 3 connected with identity) / heartbeat Unix ms u64 (stale > 500 ms = input lost) |
| 80…92 | app | steering, accelerator, brake, clutch (u32 0…65535, pedals as reported by HID) |
| 96 / 100 | app | buttons 1…25 bitmask / hat 0…7 clockwise from north, 8 = centred |
| 104 | app | optional packed VID/PID u32 (`0xc24f046d` G29, `0xc266046d` G923 PlayStation/PC), valid only when connected flags bit 1 is set |
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

## Wheel identity (compatible v2 extension)

The native scanner still accepts only USB `046d:c24f` and `046d:c266`. It publishes the
selected device's model with the input, under the same seqlock. Offset 104 was unused;
no existing offsets, file size, magic or protocol version change. Older DLLs treat any
nonzero connected word as connected and ignore this field. Older apps write 0/1, so a
new DLL ignores leftover identity bytes even after a downgrade using the same file.
An old DLL still advertises G923; both app and DLL must be updated for G29 identity.

The DLL uses one model selection for enumeration, GetDeviceInfo, instance/product name
properties and DIPROP_VIDPID. G29 is named `G29 Driving Force Racing Wheel`, with product
GUID `{c24f046d-0000-0000-0000-504944564944}`. G923 retains its existing name and product
GUID `{c266046d-0000-0000-0000-504944564944}`. No additional wheel variants are enabled.
Unknown/absent identity in otherwise valid connected input uses the historical G923
fallback; this is compatibility behavior, not detection of another supported wheel.

Before the first valid input, identity defaults to G923. Disconnected, stale, torn,
invalid or incompatible input retains the last observed valid identity. A fresh valid
snapshot updates metadata even on an existing device object, including after changing
wheels. Attached-only enumeration and input availability continue to use the existing
heartbeat checks. Connect/start the app before launching the game; games that cache
metadata may need restarting after swapping models or starting the app late.

The virtual instance and FF driver GUID remain
`{43464231-0923-4001-8001-434642000001}` for both wheels: they identify the existing single
virtual wheel slot, not a hardware serial number. This preserves instance-keyed bindings
and leaves G923 identity unchanged. G29 product-keyed profiles may need selecting or
calibrating again because correcting the previously advertised G923 product is intentional.
Native wheel/force settings and all force behavior are unchanged.
