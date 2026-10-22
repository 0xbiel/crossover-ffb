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

## Final UI delta and code-level review

Integrated UI delta `d32ddb15b106fe23257b8b4d7fa05997edf86d80`. The test-file merge retains all combined bridge regressions plus the UI bundle-flag test. The audited `FFBBridge.swift` resolution is unchanged.

Fresh static review covered `AppRuntime`, SwiftUI app/scene ownership, delegate lifecycle, activation policy, `isInserted` binding, menu host/material modifiers, and the repository packaging plist template. Findings:

- Demo mode is recognized from `--demo` or the explicit `FFBHardwareDisabledDemo` bundle boolean, with insertion forced true; it does not depend on the saved menu-visibility setting. The preview model returns before timers/discovery/startup.
- The scene holds the retained singleton model; its label/content own observation. The menu uses the installed SDK's public macOS-13+ MenuBarExtra custom-label initializer and window style. No application code assigns the status window a zero-height frame or removes the demo scene.
- The app requests accessory activation and the repository's normal package template uses `LSUIElement=true`, with no `LSBackgroundOnly` setting. No confirmed lifecycle or activation defect explains the observed zero-height status window. The normal packaging script is a production packager, not a demo packager; a separate demo bundle must retain its explicit hardware-disabled flag. No bundle was built/installed/replaced in this pass.
- The menu host clears its background and opacity. The UI task also observed uniform gray with only the system popover and Reduce Transparency false. This does not isolate the custom modifier as the cause; changing materials or activation without further runtime evidence would be speculative.

**Unresolved visual blockers:** the reported actual NSStatusBarWindow frame `(0,0,83,0)` and click opening nothing, including Finder launch; and uniform-gray backdrop captures. Neither menu visibility/click behavior nor desktop translucency is verified. Menu-bar overflow is not established. Resolving this requires runtime evidence about status-item placement and event delivery / compositor sampling; this code-only pass intentionally performs no UI automation, restarts or settings changes.

Final affected validation: 75 Swift tests pass (68 WheelCore + 7 AppPresentation), including compilation of app and CLI targets; `git diff --check` passes. C code is unchanged from the integration checkpoint's passing sanitizer, Win64 DLL and PE checks. No confirmed actionable code defect was found, so no speculative UI implementation change was added beyond the requested commit.
