# Wheel UI and offline previews

The menu presents connection, steering, pedal and force readings in aligned rows.
The main window uses a quiet sidebar and an inset workspace, with all existing
wheel, force, input, library and application settings reachable from the sidebar.
The layout was informed by the owner's notes app at revision
`299471eebf40c5853655119e9cdbd6a93105552a`, particularly `WorkspaceView.swift`,
`CompactChrome.swift` and `NeutralSidebarSelection.swift`. No notes files changed.

## Capability visibility

TrueForce controls appear only with a running bridge, a connected G923 from the
existing supported model set, an available TrueForce interface, and a status update
no older than one second. They disappear on disconnect, stale status, unknown model,
G29, or loss of the TrueForce interface. Leaving a now-hidden TrueForce page returns
to wheel settings. Visibility never changes saved TrueForce preferences or enables
a backend. These controls still govern telemetry-synthesized TrueForce.

## Safe screenshots

```sh
./scripts/dev test
.build/debug/CrossoverFFBApp --snapshot /tmp/crossover-ffb-previews
```

The explicit snapshot flag constructs a preview AppModel with a separate, ephemeral
preferences domain. Initialization returns before timers, discovery, game scans,
preference writes or hardware startup. Its FFBBridge additionally rejects `start()`.
The renderer uses deterministic fixtures for every recognised model: G923 and G29
(supported), G923 for Xbox, RS50, G PRO (PlayStation / PC), the ambiguous `c272`
identity (shown as "RS50 or G PRO") and disconnected. It saves a menu and window PNG
for each from actual NSHostingView/SwiftUI rendering. It captures only its own view
contents, and labels them as previews. No shared-memory publication, motor commands,
normal app launch or game installation is needed.

Add `--snapshot-all` to render every settings destination for each fixture as well.
This also exercises the hidden-page fallback for G29 and disconnected fixtures.

## Unsupported wheels

`WheelPresentation.detected` names a recognised Logitech wheel the bridge does not drive.
It is shown only while no supported wheel is connected and status is fresh: an orange
"Not supported yet" state, no rim, input, force output or TrueForce, and the list of
supported models. Nothing is attached or written. Only preview fixtures set it today;
live passive discovery is not wired into the app yet.
The preview launcher does not modify the installed app.

## Rim artwork

`WheelRim.swift` is the single model-aware rendering boundary. G29 and G923 now use local user-supplied product images, isolated with the built-in
ImageGen tool. Both paddle sets are retained and stationary motor housings are removed.
Unknown connected models retain the original schematic fallback; disconnected views ask the user to connect their wheel over USB. See
`Sources/CrossoverFFBApp/Resources/Rims/NOTICE.txt` for source provenance and restrictions. Manufacturer downloads must not be bundled without redistribution
rights. Future assets should be square transparent cutouts, with the steering axis
at the canvas centre; both menu and wheel page rotate about that centre using the
existing steering angle. Only G29 and G923 are selectable models. A base PID does
not establish which interchangeable rim is attached.

## Interactive demo

Run `CrossoverFFBApp --demo` for a persistent, hardware-disabled workspace. The header says “Preview · no hardware”; the compact Fixture menu switches between all fixtures above. The window title is hidden and content runs under the transparent title bar, so the header is a single 38-point row. The demo uses the real menu-bar controller, with its status item labelled FFB Demo. A native demo bundle may set the Info.plist boolean FFBHardwareDisabledDemo to true, so opening it from Finder remains hardware-disabled without shell arguments. Quit with Command-Q. Discovery, bridge workers, installers, calibration, login-item changes and persistent preferences are disabled. Readouts are fixtures, not hardware measurements.

## Menu bar

`MenuBarController` owns the status item and a borderless, non-activating, clear `NSPanel` hosting `MenuView`. It replaced `MenuBarExtra(.window)`, which on this Mac drew an opaque, almost square panel behind the content. Neither `containerBackground(.clear, for: .window)` on the content nor at the scene root removed it, so the menu's 24-point glass corners showed that panel. The panel has no system shadow, because the window server drew it, and its rim, around the rectangular frame rather than the glass shape. The menu closes on a status-item click, a click elsewhere or Escape.

The surface is regular Liquid Glass on macOS 26+, a behind-window popover material on macOS 13–15, and an opaque system background with Reduce Transparency. Sliders and switches are native controls at their default size, so macOS 26 draws them as Liquid Glass. That depends on the SDK version recorded in the binary. SwiftPM's default `swiftbuild` backend recorded SDK 13.0 (the deployment target), which made AppKit draw legacy controls: a gray circular knob with no glass while dragging. `scripts/dev` and `scripts/package-app` therefore pass `--build-system native`, which records the real SDK (27.2 here). Check with `otool -l <binary> | grep -A4 LC_BUILD_VERSION`.

`CrossoverFFBApp --simulate-wheel <fixture>` shows the normal app chrome over a fixture, still hardware-disabled. Add `--open-menu` to open the menu at launch, which lets a script capture it. Verified 2026-11-24: just outside the glass corner the window pixels have alpha 0.08 (previously 1.0), and a full-screen capture shows no rectangle behind the menu.
