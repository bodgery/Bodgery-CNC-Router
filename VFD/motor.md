# Spindle Motor: G-Penny 2.2 kW ER20

The spindle motor on The Bodgery's Techno LC 4896 CNC router, driven by the CDI-EM60 VFD.

**Product:** G-Penny 2.2KW ER20 D80 Metal working water cooled spindle motor, 400Hz-12000/800Hz-24000rpm. The 800 Hz / 24,000 rpm variant is installed.
[Product page](https://gpennymachine.com/products/g-penny-2-2kw-er20-d80-metal-working-water-cooled-spindle-motor-400hz-12000-800hz-24000rpm?variant=43362662940855). The spec tables on that page open as pop-ups when clicked.

## Specifications

| Item | Value |
|---|---|
| Rated power | 2.2 kW |
| Voltage | 220 V, 3-phase |
| Rated current | 10 A |
| Rated frequency | 800 Hz |
| Poles | 4 |
| Speed range | 12,000 - 24,000 rpm (listed) |
| Torque | 0.88 N·m, constant across the speed range |
| Collet | ER20 |
| Diameter | 80 mm |
| Cooling | Water |
| Bearings | 2 x 7005 P4 DT and 2 x 7203 P4 DT (ceramic: the bit is not grounded through the spindle) |

## Wiring

Per the listing: motor leads 1, 2, 3 go to drive outputs U, V, W, and lead **4 must go to ground** for safety. Swapping any two of U, V, W reverses rotation. P0.0.06 can also reverse it in software.

## Speed, voltage and power

The motor's V/f curve is a straight line from 0 to 220 V at 800 Hz, and torque is constant (0.88 N·m). Power therefore rises in proportion to speed:

| Frequency | Speed | Approx. power available |
|---|---|---|
| 400 Hz | 12,000 rpm | 1.1 kW |
| 600 Hz | 18,000 rpm | 1.65 kW |
| 800 Hz | 24,000 rpm | 2.2 kW |

Speed = frequency x 30 for this 4-pole motor (rpm = 120 x f / poles). Full rated power is only available at top speed, which is worth remembering when slowing the spindle down for heavy cuts.

## Drive settings that depend on this motor

These come from the motor spec and PwnCNC's 4-pole supplement. The current values are in `settings.csv`, which is the source of truth.

| Parameter | Setting | Why |
|---|---|---|
| P0.0.07 Max frequency | 800.00 | 24,000 rpm top speed |
| P0.0.08 Upper limit frequency | 800.00 | Same as max |
| P0.0.14 Motor rated power | 2.2 | kW |
| P0.0.15 Motor rated frequency | 800.00 | Hz |
| P0.0.16 Motor rated voltage | 220 | V (verify at the drive) |
| P0.0.17 Motor rated current | 10.00 | A; the drive's motor overload protection is based on this |
| P0.0.18 Motor rated speed | 24000 | rpm |
| P5.0.15 Display coefficient | 3.0000 | Makes the keypad display read spindle rpm |

If the spindle is ever replaced with a 2-pole motor (400 Hz = 24,000 rpm), all of these change. PwnCNC's standard 2-pole values are 400.00 Hz and a display coefficient of 6.0000.
