# Changelog

## 0.3.0

- **Experimental G29 identity**: the new bridge, still a work in progress, presents a connected
  G29 to games as a G29 (product `c24f`) instead of a G923. It hasn't been tested on a G29 yet,
  so please report how it works ([#1](https://github.com/0xbiel/crossover-ffb/issues/1)). Games
  that bind controls to the wheel's product, such as Assetto Corsa set up in Content Manager,
  may need the wheel selected again. Update the bridge in each game from the Library, since app
  and bridge must both be 0.3.0.
- **New menu bar menu**: one Liquid Glass surface with no panel behind it, native sliders and
  switches, and the bridge switch in the header. It closes on a second click, a click elsewhere
  or Escape.
- **Redesigned settings window** with a slimmer header, clearer empty states and page titles
  that match the sidebar.
- Recognised but unsupported wheels (G923 for Xbox, RS50, G PRO) are named and marked as not
  supported yet. They are never attached or written to.
- Sliders and switches use the current macOS design. Builds previously recorded an old SDK,
  which made macOS draw legacy controls.
- The bridge log (`crossover-ffb-observe.log`) now records which wheel each game was offered,
  tagged `cfb-bridge-v3`.
- Groundwork for Logitech's native SDK and newer wheels, disabled and not hardware-tested.
- **App icon and installer**: the app has its own icon, and the disk image opens to a styled
  window with drag-to-Applications and first-launch instructions.

## 0.2.1

- **Steering Wheel settings**, the G HUB options for the G923 and G29:
  - operating range from 40° to 900°, with presets and a live rotation dial;
  - steering and per-pedal sensitivity curves;
  - a centering spring, optionally also in force-feedback games;
  - torque and audio-effects strength;
  - combined pedals.
- **Rev lights**: the G923/G29 LEDs follow engine rpm in Assetto Corsa, ACC and AC EVO, and
  flash at the limiter.
- Fixed: with TrueForce on, all in-game forces could be reversed on wheels whose classic motor
  direction is inverted. Springs and dampers then pushed the wheel away from centre, and the
  wheel drifted to one side at low speed. TrueForce now uses its own fixed direction.
- Fixed: constant, ramp and periodic forces now follow DirectInput's convention, where a
  direction says where the force comes from. Together with the TrueForce fix, ACC's forces
  now point the right way both at standstill and while driving, with **Reverse** off.
- The bridge DLL also passes the car's max rpm to the app. Games installed with 0.2.0 show
  **Update** in the Library. Quit the game and press it.

## 0.2.0

- First public release: menu bar app, Library with one-click install for Steam + NotProton,
  CrossOver and any Wine prefix, force feedback and simulated TrueForce.
