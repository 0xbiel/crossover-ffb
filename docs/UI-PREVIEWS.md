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
The renderer uses deterministic G923, G29 and disconnected fixtures and saves six
PNGs from actual NSHostingView/SwiftUI rendering. It captures only its own view
contents, and labels them as previews. No shared-memory publication, motor commands,
normal app launch or game installation is needed.

Add `--snapshot-all` to render every settings destination for each fixture as well.
This also exercises the hidden-page fallback for G29 and disconnected fixtures.
The preview launcher does not modify the installed app.

## Rim artwork

`WheelRim.swift` is the single model-aware rendering boundary. G29 and G923 now use local user-supplied product images, isolated with the built-in
ImageGen tool. Both paddle sets are retained and stationary motor housings are removed.
Unknown/disconnected models retain the original schematic fallback. See
`Sources/CrossoverFFBApp/Resources/Rims/NOTICE.txt` for source provenance and restrictions. Manufacturer downloads must not be bundled without redistribution
rights. Future assets should be square transparent cutouts, with the steering axis
at the canvas centre; both menu and wheel page rotate about that centre using the
existing steering angle. Only G29 and G923 are selectable models. A base PID does
not establish which interchangeable rim is attached.

## Interactive demo

Run `CrossoverFFBApp --demo` for a persistent, hardware-disabled workspace. The title says “Demo — No Hardware”; Fixture switches between G923, G29 and disconnected. Menu preview opens the same menu view in a native popover; if macOS has no space for the FFB Demo status item it anchors to the dashboard. Quit with Command-Q. Discovery, bridge workers, installers, calibration, login-item changes and persistent preferences are disabled. Readouts are fixtures, not hardware measurements.

The menu uses untinted native clear Liquid Glass on macOS 26+, a behind-window popover material on macOS 13–15, and an opaque system background with Reduce Transparency. Its hosting window is clear, with no navy overlay. Live screenshots are necessary to assess the backdrop; offscreen snapshot renders cannot prove translucency.
