# Changelog

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
