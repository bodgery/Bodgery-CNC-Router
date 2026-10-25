# ESP32-S3 USB HID CNC Jog Pendant (TechnoCNC LC series)

Ten Cherry MX momentary switches plus three status LEDs (Step, Continuous,
and Enable/armed), acting as a USB keyboard jog pendant over the ESP32-S3
native USB (OTG) port.

## Wiring

Every switch is a simple SPST momentary contact: one terminal to the GPIO,
the other to GND (internal pull-ups enabled, no external resistor needed).

| Function    | GPIO | Type                    | Key sent to host | Notes |
|-------------|------|-------------------------|-------------------|-------|
| +X          | 4    | Axis (tap = 1, hold = stream) | Right arrow       | |
| -X          | 5    | Axis (tap = 1, hold = stream) | Left arrow        | |
| +Y          | 6    | Axis (tap = 1, hold = stream) | Up arrow          | |
| -Y          | 7    | Axis (tap = 1, hold = stream) | Down arrow        | |
| +Z          | 15   | Axis (tap = 1, hold = stream) | Shift+"=" (i.e. "+") | See note below if you meant the numpad "+" |
| -Z          | 16   | Axis (tap = 1, hold = stream) | "-"               | |
| Step        | 17   | Mode select (tap)       | F8                | Lights its LED, turns off Continuous's |
| Continuous  | 18   | Mode select (tap)       | F9                | Lights its LED, turns off Step's |
| Enable      | 8    | Hold 3 s (toggle)       | *(nothing -- local only)* | Does **not** gate any other switch |
| Abort       | 9    | Immediate tap           | Escape            | Always forces the local armed flag off |

The "+"/"-" keys are sent as standard top-row keys (Shift+"=" for "+", plain
"-" for "-"). If TechnoCNC LC actually expects the numpad +/- keys instead,
swap the +Z/-Z entries in `axis_switches[]` for `HID_KEY_KEYPAD_ADD` /
`HID_KEY_KEYPAD_SUBTRACT` (no shift modifier needed for either).

| LED             | GPIO | Lit when                          |
|-----------------|------|------------------------------------|
| Step mode LED   | 10   | Step last selected                |
| Continuous LED  | 11   | Continuous last selected           |
| Enable LED      | 12   | Pendant is armed (Enable held 3 s) |

Wire each LED through a ~330 ohm current-limiting resistor to GND. All three
start off at boot. The Step/Continuous LED lights as soon as either mode
switch is pressed. The Enable LED lights when the 3-second hold arms the
pendant, and turns off when it's disarmed -- either by holding Enable again
for 3 s, or instantly by pressing Abort.

## Behavior

- **Axis switches (+X/-X/+Y/-Y/+Z/-Z):** typematic-style.
  - A quick tap sends exactly one key press+release -- one character.
  - Holding past 400 ms (`JOG_REPEAT_DELAY_MS`) starts a steady stream of
    key press+release pulses, one every 60 ms (`JOG_REPEAT_INTERVAL_MS`),
    for as long as the switch is held.
  - Releasing stops the stream immediately -- no more characters are sent.
  - Always active (no enable gating).
- **Step / Continuous:** mutually exclusive. Pressing one sends a single key
  tap (not held) and updates the LEDs; the previous mode's LED turns off.
  Always active.
- **Enable:** hold continuously for 3 seconds to toggle an internal
  armed/disarmed flag. **Nothing is sent to the host for this switch** --
  it only affects this firmware's own state, which Abort force-resets.
  Releasing before 3 s cancels the attempt. This switch does **not** block
  or gate the axis or mode switches -- all other buttons work regardless of
  the armed state.
- **Abort:** works immediately on a single press, no hold required. Sends
  its key tap right away and always forces the armed state to disarmed,
  regardless of what it was. Treat it like a software e-stop signal; actual
  motion stopping still depends on how TechnoCNC LC responds to that key.

Change any pin, key, or timing at the top of `main/main.c`
(`axis_switches[]`, `mode_switches[]`, `ENABLE_*`, `ABORT_*`,
`ENABLE_HOLD_MS`, `TAP_DOWN_MS`, `JOG_REPEAT_DELAY_MS`,
`JOG_REPEAT_INTERVAL_MS`).

## Build & flash (ESP-IDF 5.1+)

```
idf.py set-target esp32s3
idf.py build
idf.py -p <PORT> flash monitor
```

The first build downloads `espressif/esp_tinyusb` automatically. This project
pins `^3.0.0` (the current `.descriptor.*`/`.phy.*`-style API), needed for
recent ESP-IDF releases such as 6.0.x. If you've built this before with an
older pin, delete `build/`, `managed_components/`, and
`dependencies.lock` first so the component manager re-resolves cleanly.

## Using the two USB-C ports

- **UART / COM port:** use this one for flashing and the serial monitor.
- **USB (native) port:** plug this into the computer running TechnoCNC LC.

Once TinyUSB is running, the native port becomes the keyboard, so the
built-in USB-Serial-JTAG console is not available on it. If you ever need to
force download mode, hold BOOT, tap RESET, release BOOT.

## Notes

- All switches are debounced (20 ms).
- Every character sent to the host, whether from an axis repeat, a mode
  select, or Abort, is a brief discrete key press+release (15 ms down by
  default via `TAP_DOWN_MS`), not a sustained "key held down" state. If your
  TechnoCNC LC setup needs a true held key instead of a stream of taps for
  continuous jogging, that's a different design -- ask and I can switch it.
- This targets `esp_tinyusb` 3.x's `TINYUSB_DEFAULT_CONFIG()` +
  `.descriptor.*` API. If you intentionally pin an older `esp_tinyusb` 1.x,
  the config struct is flat (`.device_descriptor`, `.string_descriptor`,
  `.configuration_descriptor`, `.external_phy`, no count field) and
  `main.c`'s `app_main()` USB setup block needs rewriting to match.
