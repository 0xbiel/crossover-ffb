# Native SDK and new-wheel foundation (experimental)

This branch is an offline-tested foundation, **not public hardware support**. It preserves the existing G29 / PS G923 app-managed output and does not add experimental products to its attach allowlist. No SDK, Wine patch, driver or game was installed or launched for this work.

## What is implemented

- `WheelInventory.snapshot()` enumerates Logitech metadata without opening HID devices or requesting/sending reports. Collections group by their IOUSBHostDevice ancestor. Missing ancestry stays ungrouped; identical PIDs at different USB parents never merge. No attach routine is called.
- `WheelProfile` separates identity, input collections, transport family and default output permission. `c26d` is Xbox console mode; `c26e` is Xbox PC HID. `c276` identifies RS50 native; `c268` identifies G PRO PS/PC. `c272` stays ambiguous between RS50 compatibility and G PRO Xbox/PC, regardless of marketing name. Standalone PC-only G PRO identity remains unknown. There is deliberately no API to turn a product-string guess into accepted identity.
- Xbox input has Y throttle, Z brake, Rz clutch. Existing PS mapping remains Y clutch, Z throttle, Rz brake. Neither map is applied to unknown/console models.
- The original C implementation forwards `DIPROP_GUIDANDPATH` to the real system DirectInput PS G923 device, returning its actual Unicode property. It enumerates attached matching joystick collections, requires exactly one, releases the physical COM device after querying and never acquires it. Missing, ambiguous, stale or malformed identity fails closed. No fabricated HID paths. G29 metadata and stable virtual GUIDs remain intact. Unsupported Logitech models are no longer hidden by the virtual bridge's enumeration filter.
- `FFBBridge(outputMode: .sdkInputOnly)` has an immutable input-only lifecycle. It only selects PS G923 input, rejects multiple candidates, publishes input, skips motor initialization and the entire effects/telemetry loop, and gates both low-level report writers. Close/disconnect writes are suppressed too. `--sdk-input-only` explicitly selects it; ordinary app startup keeps existing app-managed behavior. This option does **not** load the SDK or launch Wine.
- A cooperative OS `flock` lease excludes other instances of this app and the CLI TrueForce probe. The lock uses a per-user file with no symlink following, owner/type/link checks and close-on-exec. Do not delete the lock file to “unlock” it. It does not exclude old releases, external tools, GHUB or an unsupervised SDK process. Stop those separately.
- Native Swift setup-plan persistence is reversible and refuses overwrite. Preflight is a pure evidence checklist. The SDK supervision model tests arming, process start, heartbeat, disconnect, process exit and latched watchdog faults. There is no automatic fallback to app output. The completion audit adds adapter-driven, mock-tested stop/kill orchestration.
- Original offline HID++ framing, ROOT discovery for feature `0x8123`, reply/error correlation, bounded single-outstanding transactions and poisoned timeout/disconnect sessions. Feature indices are discovered, never assumed. The original abstract effect lifecycle remains available; the completion audit additionally implements offline effect serialization and a correlated wire session (see below). Neither has a hardware sender.
- Separate Xbox and direct-drive backend interfaces reject every force-report request. The direct-drive input parser handles the documented 30-byte payload after descriptor-based report-ID stripping; button/accessory binding remains unaccepted. RS50's 8 Nm and G PRO's 11 Nm ratings are descriptive, never G923 output conversion factors.

## Safe entry points

Build with `scripts/dev test` and `scripts/build-bridge`. Neither runs a hardware probe.

`crossover-ffb inventory` is metadata-only. It is available for a future explicitly authorized inventory run; it was not run during this task.

`crossover-ffb sdk-plan /new/local/plan.json /user/original-sdk.dll /separate/patched-wine` writes only that JSON plan. `NativeSDKSetupPlan.remove(from:)` verifies the plan matches before deleting it. This is not an installer. The CLI intentionally cannot mark preflight evidence accepted or launch a session.

The app's `--sdk-input-only` switch is useful for later input lifecycle acceptance. Do not confuse successful input with native SDK transport acceptance.

## Separate versioned Wine transport

Contract: `winebus-11.17-g923-v1`. The upstream author's reported combination is CrossOver Preview `27.0.0.41069`, Wine `11.17`, original signed Logitech SDK `1.3.12` x64, PS G923 and DiRT Rally 2.0. This report is not independent validation and does not establish stock CrossOver support.

The complete transport must include vendor collection admission, interface metadata and physical container grouping. Merely changing a USB allowlist, forwarding GUIDANDPATH, or creating a Python/Swift sample ring buffer does not implement SDK transport. Escape remains unsupported. No Wine patch is vendored or applied here.

Before any future activation, record immutable source commits, patch hash, build toolchain, binary hashes, complete corresponding Wine source, notices/licenses and a rollback manifest. Use a separate runtime/bottle and retain original files/hashes. A future installer must stage and verify before atomic replacement and restore only files it owns whose installed hash still matches. This branch provides no bottle/registry modification or patched-Wine activation code.

`SDKPreflight` fields are evidence inputs for the future supervisor, **not verification results**. In particular, code does not authenticate a proprietary Windows DLL signature, discover runtime provenance or attest physical output. All fields default to blocked. A UI must never present these as casual enable toggles.

## Remaining acceptance gates

1. **PS G923 SDK:** independently verify original SDK signature/version and redistribution restrictions; reproduce the complete pinned transport in an isolated runtime; correlate physical DirectInput path, USB container and vendor collection; capture actual SDK-owned reports and game result. Confirm input-only app emits no stop, autocenter, LEDs, range, calibration, classic or telemetry commands at attach, tick, disconnect and shutdown.
2. **Supervision:** implement the external process runner only after the transport is accepted. Hold a single supervisor lease for the entire SDK process lifetime, terminate and confirm exit before releasing it, and keep app output disabled after crash/disconnect/watchdog fault. The coordinator now requests termination and bounded kill escalation through an injected adapter, retaining the lease until confirmed exit. No concrete Wine/game process adapter is supplied, so this branch still cannot launch or stop an actual SDK process. Validate SDK/firmware stop behavior and physical watchdog independently; an app heartbeat cannot guarantee motor stop after its own crash. No launcher is enabled until that is resolved.
3. **Xbox G923:** collect descriptors and grouped collection identities in PC mode, confirm pedal ranges/polarity, discover `0x8123`, capture get-info and effect allocation/start/stop/delete/error replies, slot reservations and timing. Confirm correlation under unrelated input and late replies, disconnect and rapid reconnect. Do not send PS initialization or assume a fixed interface number. Owner observations put Xbox input/HID++ on interface 0 and TrueForce on 1; choose via descriptors/usage/physical parent. Xbox native-SDK CrossOver remains unverified.
4. **RS50/G PRO:** independently distinguish `c272` physical models using accepted descriptor/capture evidence; identify PC-only G PRO; accept subdevices, payload framing, ranges and buttons. Validate each model's protocol, calibration/strength units, saturation and stop behavior separately. No hard-coded fallback feature indices, initialization tables, torque packets or force scaling are enabled.
5. **Runtime/hardware safety:** demonstrate single writer across app/CLI/SDK, reconnect isolation, bounded queues/timeouts, process crash and disconnect behavior on each exact firmware/runtime/model. Only then connect the offline codecs to a separately reviewed physical output transport and explicit acceptance record. Passing mocks is not this gate.

## Provenance and licensing

All new implementation in this branch is original under the repository MIT license. Protocol facts and external behavior were reviewed; no GPL orchestration, Linux driver implementation, SDK binary, libtrueforce initialization table or Wine patch was copied into this repository.

Reviewed sources:

- [armax9 C bridge](https://github.com/armax9/g923-control-center/blob/9095b75b50f16fc11207761c6341ec9f7cbaa01b/g923-mac-bridge/vendor/crossover-ffb/bridge/virtual_core.h), [complete Wine patch](https://github.com/armax9/g923-control-center/blob/9095b75b50f16fc11207761c6341ec9f7cbaa01b/g923-mac-bridge/patches/winebus-11.17-g923-trueforce.patch), [support report](https://github.com/armax9/g923-control-center/blob/9095b75b50f16fc11207761c6341ec9f7cbaa01b/g923-mac-bridge/docs/publication/SUPPORT.md), [file-level notices](https://github.com/armax9/g923-control-center/blob/9095b75b50f16fc11207761c6341ec9f7cbaa01b/g923-mac-bridge/NOTICE.md). Root orchestration is GPL-3.0-only; vendored crossover bridge/sdk_trace MIT; Wine changes LGPL-2.1-or-later. Preserve these boundaries in future packaging.
- [Pinned protocol specification](https://github.com/mescon/logitech-trueforce-linux-driver/blob/972274bdce293419c058eb10b796feb232bfd9ef/docs/PROTOCOL_SPECIFICATION.md). Used for identity, 30-byte input layout and transport distinctions. Linux implementation is GPL; libtrueforce LGPL. No derived driver code is linked.
- [Xbox owner observations #27](https://github.com/mescon/logitech-trueforce-linux-driver/issues/27), [Xbox force-engine versus parked SDK investigation #87](https://github.com/mescon/logitech-trueforce-linux-driver/issues/87), [RS50 mode identity uncertainty #65](https://github.com/mescon/logitech-trueforce-linux-driver/issues/65). Issue threads are mutable observations, not acceptance fixtures.
- [Pinned Linux HID++ driver](https://github.com/torvalds/linux/blob/7be4bc52fd9e0e55dc9a2e0232b89427d2c4b614/drivers/hid/hid-logitech-hidpp.c), GPL-2.0-only. Consulted for public packet framing, feature ID and reply/error structure only. New Swift implementation is deliberately limited and original.

Offline test byte arrays are synthetic protocol fixtures, not real hardware captures. The Win64 DLL build uses the repository's existing build script (which uses Python for PE inspection); the new SDK plan/lifecycle path has no Python runtime dependency.

## Integration notes

Base: `6e5c775355dc59cde9896cc087076cbe15cbf2ec`. UI work is separate. `Sources/CrossoverFFBApp/FFBBridge.swift` overlaps that branch and needs a deliberate merge of immutable mode, lease, candidate-count and output gates. `SharedBridge.swift` and the shared-memory ABI are unchanged. UI can consume `WheelInventory`, `WheelProfile`, `SDKPreflight.blockers` and setup-plan types without enabling experimental output. Model artwork remains owned by the UI task.

## Offline validation on 2026-10-22

- `scripts/dev test`: **52 tests passed**, including profile grouping, Xbox/PS pedal separation, synthetic HID++ replies/errors/timeouts, actor-level shared request budget, effect lifecycle invalidation, direct-drive payload parsing, no-output backend defaults, preflight rejection, supervisor faults, process lease exclusion and reversible setup plans. Swift app and CLI targets compiled with existing tools.
- `scripts/build-bridge`: C AddressSanitizer/UndefinedBehaviorSanitizer tests passed; ANSI/Unicode physical-path tests cover ambiguity, disconnect, malformed properties/path and balanced release. Existing identity, input, effect and lifetime regression tests passed. Win64 DLL built and PE exports/KERNEL32-only imports verified.
- `git diff --check`: passed.
- No hardware inventory, motor command, force test, game launch, SDK loading, driver installation or bottle/registry change was performed. SwiftPM only warned that user-level cache/configuration directories were unavailable; local build caches worked. No dependency was installed.


## Focused completion audit

The earlier statement that Xbox effect *encoding* needed new captures was too broad. The pinned Linux `0x8123` source publishes enough wire facts for an original offline serializer. `HIDPPForceEffect` now serializes constant, ramp, five periodic waveforms and four condition types using explicitly raw protocol units. `HIDPPForceSession` discovers the feature, reads slot capacity, downloads/updates stopped effects, plays/stops/erases, correlates replies/errors and invalidates slots after faults. `XboxWireSession` serializes concurrent callers. Synthetic mock fixtures cover these paths, big-endian/signed fields, long versus very-long reports and unrelated replies. This is not a copy of Linux's conversion, queue or driver implementation. No physical transport can consume these bytes in this branch.

The capture harness deliberately uses each 4-bit software ID once (15 transactions per session) rather than wrapping and accepting potentially stale duplicate replies. Exceeding the budget fails closed. Continuous production operation requires an accepted stale-response/drain strategy; this offline capture engine is not a streaming game backend. No torque-unit conversion, DirectInput direction projection, global gain, reset/autocenter or PS initialization is inferred by the codec.

`SDKArtifactAudit` performs SHA-256 comparison against independently reviewed expected hashes and checks x64 PE DLL header fields without executing/loading a file. `SDKPreflight.applyArtifactAudit` cannot promote hashes to Authenticode trust. `SDKSessionCoordinator` runs against an injected process/lease adapter: it blocks rejected preflight, waits for explicit readiness, requests termination after watchdog/disconnect and requests kill once after 500 ms, retaining the lease until confirmed exit. Tests use only mocks. A concrete SDK host ABI is deliberately not invented: the known route uses the game's original SDK inside the separately patched Wine runtime.

New read-only commands (implemented but not run on hardware in this task):

- `crossover-ffb inventory-export /new/inventory.json`: exports collection metadata and cached HID report descriptors (base64), preserving missing ancestry/descriptors. No serial number is collected. The metadata capability has no open/get-report/set-report methods; the native adapter uses only manager enumeration, cached properties and registry ancestry. A spy test verifies export calls only metadata reads and local file output; the native path was also inspected for prohibited calls. It does not capture live input, request a report descriptor over USB, or imply firmware acceptance.
- `crossover-ffb sdk-audit /sdk.dll /wine-binary SDK_SHA256 WINE_SHA256`: reads and hashes files; checks PE header metadata; never executes either. Expected hashes must come from external reviewed provenance, not the files being checked. It cannot verify Authenticode trust, actual SDK version, complete Wine source/patch correspondence or gameplay.

### Exactly what remains, and why

| Area | Required evidence / remaining work | Why current sources do not finish it |
| --- | --- | --- |
| Xbox physical HID transport | `inventory-export` for `c26e`: all collections, cached descriptors, physical-parent grouping; confirm report IDs 0x10/0x11/0x12 and lengths on the chosen HID++ collection; firmware identity and feature discovery/get-info replies | Linux publishes packet facts but does not validate this macOS IOHID transport or the attached firmware's descriptor/capacity. No physical sender is enabled. |
| Xbox accepted effects | Captures pairing raw encoded download/play/stop/erase requests with device replies and observed slot/stop behavior; constant/ramp/periodic/condition acceptance per firmware, errors and late replies across reconnect | Offline byte equality is now implemented. Published Linux behavior is enough for those serializers, not independent acceptance of Xbox G923 firmware on macOS. Raw-unit to game-force conversion and production client-ID reuse remain implementation/validation work, not unknown packet formats. |
| PS SDK provenance | User-supplied original DLL; independently verified Authenticode signer/chain and version bound to its hash; exact Wine source commit, complete patch/build manifest and installed-binary hash; real GUIDANDPATH plus matching container/collections | Local hash/header checks are implemented. Neither a hash nor the author's support report establishes signature trust, corresponding-source completeness or the installed runtime's behavior. |
| SDK process integration | Documented accepted game/runtime command and process-tree identity; mock-backed coordinator is implemented, but a concrete runner must supervise the entire Wine/game process tree and input-only attachment | This does not require new wheel captures to write a process adapter once the launch contract is supplied. It is an integration dependency, not a fabricated SDK-host ABI or a claim that stock CrossOver works. |
| Physical crash safety | Measured behavior after SDK crash, host loss, disconnect and failed termination; confirmed firmware watchdog/stop behavior, with no app fallback writer | A mock can prove stop requests and lease retention; it cannot prove an external process or motor actually stopped. Hardware evidence is indispensable before enabling output. |
| RS50 / G PRO | `c276`, `c268`, and ambiguous `c272` exports; independently identified physical model, firmware and report framing; PC-only G PRO identity; model-specific output/calibration/stop captures | The pinned DD specification supports further offline stream serializers, but those are still engineering work outside this focused Xbox/SDK completion pass. Physical binding, calibration, safe torque conversion and ambiguous identities remain unaccepted. This audit does not relabel all DD engineering as “needs captures.” |

The existing `FFBBridge.swift` integration overlap remains unchanged. This audit adds only core modules, tests and CLI read-only commands; it does not touch the UI working tree, shared-memory ABI, bottles or installed runtime.

Completion-audit validation: `scripts/dev test` passed **61 tests** (including nine new audit tests); app and CLI targets compiled. `git diff --check` passed. C sources did not change in this audit; the preceding sanitizer/Win64 build results still apply. Tests used synthetic files and mock process/metadata/transport objects only. No hardware inventory/export or SDK audit against a real proprietary binary was run.

Cross-review correction: motor lease tests now inject an internal lock path in unique temporary directories; they never contend on the production per-user lock. Public production construction retains the same path and identical owner/type/no-symlink/link-count checks. Isolation, reacquisition, symlink, hard-link and directory-rejection tests pass (62 total Swift tests at this checkpoint).
