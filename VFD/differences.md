# VFD settings — differences

_Generated from settings.csv by tools/differences.py. Do not edit by hand._

A dash (—) means the value has not been recorded for that configuration.

## Parameters changed from factory

| Code | Parameter | Factory | freq_control | rpm_control | Notes |
|---|---|---|---|---|---|
| P0.0.00 | Inverter type | machine-type | 1 | 1 | freq_control: Mike's setup notes: G type (constant torque) |
| P0.0.03 | Run command source | 0 | 1 | 1 | freq_control: Mike's setup notes: terminal control so DI1 (FWD) from the switch box starts the spindle; PwnCNC shipped 0 |
| P0.0.04 | Frequency source A | 2 | 3 | 3 | freq_control: Mike's setup notes: source A = VF1 analog (used when DI4 is open); PwnCNC shipped 2. Needs P0.1.00=8 and P0.1.01=2 - verify |
| P0.0.05 | Keyboard frequency reference | 50.00 | 400.0 | 400.0 | freq_control: Mike's setup notes: keyboard frequency reference; only used if a keyboard source is selected |
| P0.0.07 | Max frequency | 50.00 | 800.0 | 800.0 | freq_control: G-Penny spindle: 24,000 rpm at 800 Hz (PwnCNC 4-pole supplement; Mike's notes) |
| P0.0.08 | Upper limit frequency | 50.00 | 800.0 | 800.0 | freq_control: Upper limit = max frequency (PwnCNC 4-pole supplement; Mike's notes) |
| P0.0.09 | Lower limit frequency | 0.00 | 0.0 | 0.0 | freq_control: Mike's setup notes (same as factory) |
| P0.0.11 | Acceleration time 1 | machine-type | 6.0 | 6.0 | freq_control: PwnCNC: spin-up time |
| P0.0.12 | Deceleration time 1 | machine-type | 6.0 | 6.0 | freq_control: PwnCNC: spin-down time |
| P0.0.14 | Motor rated power | machine-type | 2.2 | 2.2 | freq_control: G-Penny spindle spec: 2.2 kW |
| P0.0.15 | Motor rated frequency | 50.00 | 800.0 | 800.0 | freq_control: G-Penny spindle spec: 800 Hz (4-pole, 24,000 rpm); also PwnCNC 4-pole supplement |
| P0.0.17 | Motor rated current | machine-type | 10.00 | 10.00 | freq_control: G-Penny spindle spec: 10 A (matches PwnCNC 220 V kit value) |
| P0.0.18 | Motor rated speed | machine-type | 24000 | 24000 | freq_control: G-Penny spindle spec: 24,000 rpm at 800 Hz |
| P1.0.23 | Fan control | 0 | 2 | 2 | freq_control: PwnCNC: cooling fan runs by heatsink temperature |
| P2.0.02 | DI3 terminal function | 9 | 21 | 21 | freq_control: Mike's setup notes: DI3 = run command select 1; DI3 is not wired, so no effect (if tied to COM, control switches to keypad). PwnCNC shipped 9 |
| P2.0.03 | DI4 terminal function | 10 | 18 | 18 | freq_control: Mike's setup notes: DI4 = frequency source select 1. DI4-COM closed (SW3) = source B (panel pot); open = source A (VF1). Requires P0.1.00=8 |
| P2.0.13 | Curve 1 minimum input | 0.00 | 0.10 | 0.10 | freq_control: PwnCNC: analog curve 1 minimum input 0.1 V (VF1 is not used by this controller) |
| P2.0.15 | Curve 1 maximum input | 10.00 | 10.00 | 3.30 | rpm_control: PROPOSED: controller DAC runs at 3.3 V, so 3.3 V on VF1 = 100% (800 Hz). Confirm with Steve |
| P2.0.37 | FM1 output gain | 1.00 | 1.00 | 0.30 | rpm_control: PROPOSED: scales FM1 to 0-3.0 V so it stays under the 3.3 V ADS1115 input limit (800 Hz = 3.0 V). Confirm with Steve |
| P5.0.02 | Run display items 1 | H.001F | H.0801 | H.0801 | freq_control: PwnCNC: run display shows frequency (bit 0) and custom value = spindle RPM (bit 11) |
| P5.0.15 | Custom display coefficient | 1.0000 | 3.0000 | 3.0000 | freq_control: PwnCNC 4-pole motor supplement: display coefficient so the keypad shows spindle RPM |
| P5.0.16 | Custom display control | b001 | b000 | b000 | freq_control: PwnCNC: RPM display with no decimal places |

## Changing from freq_control to rpm_control

Frequency-control spindle controller (original) → RPM-control spindle controller. These are the parameters to change at the start of each rpm_control session and restore at the end.

| Code | Parameter | freq_control | rpm_control | Can change while running? | Why (rpm_control) |
|---|---|---|---|---|---|
| P2.0.15 | Curve 1 maximum input | 10.00 | 3.30 | yes | PROPOSED: controller DAC runs at 3.3 V, so 3.3 V on VF1 = 100% (800 Hz). Confirm with Steve |
| P2.0.37 | FM1 output gain | 1.00 | 0.30 | yes | PROPOSED: scales FM1 to 0-3.0 V so it stays under the 3.3 V ADS1115 input limit (800 Hz = 3.0 V). Confirm with Steve |
