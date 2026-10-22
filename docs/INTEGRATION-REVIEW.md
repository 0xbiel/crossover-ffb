# Local UI / native backend integration review

This review branch combines UI/G29/artwork/demo commit `016e0fdd7bdb03eec416555473d26e9d80149728` and audited backend commit `b741c0ab7711673b64411c0986f1bb6d2484967f`. Both source branches/worktrees are preserved. This is local assembly only, not a main-branch merge, release or hardware acceptance.

## Deliberate bridge resolution

- Preserve immutable `hardwareEnabled` and `outputMode` together. Preview and passive modes reject start before any worker, lease, shared memory or HID activity; the worker repeats that guard defensively. Calibration requests and both low-level report writers honor the combined gates.
- SDK input-only attach and tick use the same status publisher: model, connected input, raw steering and freshness update together, while telemetry/TrueForce availability/streaming/output and stale game/effect indicators are cleared. Existing telemetry controls cannot appear for an SDK-owned session.
- Disconnect resets the complete status payload, preserving only worker-running state and the new timestamp/message until worker shutdown completes.
- Experimental inventory profiles remain separate from the supported `BridgeWheelModel` and artwork selection. No new PID is admitted to live output or game identity.

## Validation

The Swift suite includes the source branches' tests plus combined regressions for hardware-disabled starts in all output modes, SDK input-only identity/freshness and hidden telemetry controls, complete disconnect reset, and experimental inventory exclusion from game identity/artwork. Asset transparency/paddle and interactive-preview tests run without launching the application.

C checks use `scripts/build-bridge`: host tests with AddressSanitizer/UndefinedBehaviorSanitizer, x64 Windows DLL compilation, and PE export/KERNEL32-only import inspection. No toolchain installation was needed.

No hardware inventory, SDK execution, game/app launch, driver installation, bottle/registry changes or running-demo replacement is part of this integration. The original UI thread continues to own its live glass-hosting verification; a later UI commit must be reviewed and incorporated separately before claiming its final visual changes are included. Hardware/runtime acceptance blockers remain in `NATIVE-WHEEL-FOUNDATION.md`.

Validated checkpoint: 74 Swift tests passed (68 WheelCore + 6 AppPresentation); app/CLI compiled. C sanitizer tests and Win64 DLL/PE checks passed. `git diff --check` passed. No confirmed integration defect remains in the pinned inputs; pending visual refinement is separate from this checkpoint.
