# RPM-Control Test Session — VFD Procedure

**Keep with the VFD enclosure.** For test sessions on the new (RPM-control) spindle controller while the original (frequency-control) controller stays in service.

> ⚠️ **P5.0.19 = 60 restores the backup. NEVER 9 or 19 — those are factory resets.**

## One time, before the first test session

1. With the machine in its normal working state, read every changed parameter: set **P0.0.01 = 2** (Check mode). The keypad then lists only parameters that differ from factory, with a `C` prefix. Write each one down, then set **P0.0.01 = 0**.
2. Also write down P0.0.11, P0.0.12, P0.0.14–P0.0.23 and P1.0.22. Check mode may not show them.
3. Enter everything in the `freq_control` column of `VFD/settings.csv`.
4. Save the production settings in the drive: **P5.0.19 = 30**.

## Start of session

> ⚠️ **Change the drive settings BEFORE plugging in the new controller.** At the normal settings, FM1 outputs up to 10 V, which can damage the controller's 3.3 V ADC.

1. Spindle stopped.
2. Change the drive parameters (current list in **`VFD/differences.md` → "Changing from freq_control to rpm_control"**):

| Code | Set to | What it does |
|---|---|---|
| P2.0.15 | 3.30 | VF1: 3.3 V from the controller = full speed (800 Hz) |
| P2.0.37 | 0.30 | FM1: feedback to the controller scaled to 0–3.0 V |

3. Unplug the converter box from the **GX16-8** on the VFD enclosure.
4. Set the **DI4–COM switch (SW3)** to **open** (new controller: speed from VF1).
5. Plug the new controller into the GX16-8.

## End of session — machine back in service

1. Spindle stopped.
2. Unplug the new controller from the GX16-8 (before restoring settings, so it never sees 10 V on FM1).
3. Restore production settings: **P5.0.19 = 60**.
4. Set the **DI4–COM switch (SW3)** to **closed** (original controller: speed from the panel knob).
5. Plug the converter box back into the GX16-8.
6. **Test:** run the spindle from the original controller, set speed with the VFD panel knob, and confirm the warning light.

If you changed a value that should become part of the `rpm_control` configuration, record it in `settings.csv` with a note saying why.
