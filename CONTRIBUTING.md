# Contributing

Thanks for helping. The most useful contributions right now are **reports from other games and
wheels**, because the project has only been tested on a G923 with a few games.

## Reporting a game

Open an issue with the **Game report** template. Include:

- the game, and where it runs (Steam + NotProton, CrossOver bottle, other Wine);
- your wheel and macOS version;
- whether the wheel shows up in the game, whether force feedback works, and whether TrueForce works;
- the DLL log `crossover-ffb-observe.log`, which is written next to the game's .exe.

If the app does not find a game, run `crossover-ffb games` (see below) and paste the output.

## Building

Requirements: macOS 13 or later, Xcode 26 (or the matching command-line tools with Swift 6),
and Homebrew LLVM plus a COFF linker to cross-compile the Windows DLL:

```sh
brew install llvm lld
```

Then:

```sh
scripts/build-bridge        # DLL unit tests (ASan/UBSan), then the Win64 dinput8.dll
./scripts/dev test          # Swift tests
./scripts/package-app       # dist/crossover-ffb.app and dist/crossover-ffb-<version>.dmg
```

Useful while developing:

```sh
.build/debug/crossover-ffb games                    # what the Library finds, and install status
.build/debug/crossover-ffb bridge-probe             # what a running game asks for (no wheel output)
.build/debug/crossover-ffb trueforce-probe 2 --buzz # TrueForce bring-up with the game closed
.build/debug/CrossoverFFBApp --snapshot /tmp/shots  # render the menu and Settings pages to PNGs
```

## Code layout

| Path | What it is |
|---|---|
| `bridge/observe.c` | The Windows `dinput8.dll`: a virtual G923 for DirectInput 8, written freestanding (KERNEL32 only) |
| `bridge/shm.h` | Shared-memory layout on the DLL side ([SHARED-MEMORY.md](bridge/SHARED-MEMORY.md)) |
| `Sources/WheelCore` | Shared logic: effect engine, shared memory, TrueForce, game discovery, installer |
| `Sources/CrossoverFFBApp` | The menu bar app (SwiftUI) and the HID bridge to the wheel |
| `Sources/crossover-ffb` | Command-line tool for diagnostics |

## Pull requests

- Keep changes focused, and add tests to `Tests/WheelCoreTests` or `bridge/tests` where you can.
- Run `scripts/build-bridge` and `./scripts/dev test` before opening the PR.
- Don't commit logs, Wine registry files or anything else from your own machine.
- Protocol knowledge must come from public documentation or your own observation. Don't copy
  code from GPL drivers or from Logitech's SDK.

## Releasing

Add a `## <version>` section to [CHANGELOG.md](CHANGELOG.md), bump the number in `VERSION` and push to `main`. The changelog section becomes the release notes. The [Release workflow](.github/workflows/release.yml)
runs the tests, builds the app and the disk image, tags `v<VERSION>` and publishes the `.dmg`
as a GitHub release. Pushing a matching `v<VERSION>` tag yourself does the same.

## Safety

This software drives a motor that can turn the wheel hard. Anything that changes force output
should keep the existing safeguards: force stops when the game goes quiet, on Stop, on quit and
on unplug.
