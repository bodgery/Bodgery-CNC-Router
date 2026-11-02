# VFD Settings Verification Checklist

**Status:** the `freq_control` column in `settings.csv` has **not yet been checked against the drive**. It was assembled from factory defaults, PwnCNC's pre-programming sheet (2/1/25), and Mike's setup notes. This checklist is the one-time check that turns it into a verified record. It should be done before any testing on the RPM-control controller.

Do this with the **original (frequency-control) controller connected** and the machine in its normal working state. Bring a phone: photos of each screen are the quickest record.

Reading a parameter on the keypad: press **MODE**, use the arrows and **>>** to select the code, press **ENTER** to see its value, then **MODE** to back out without changing it. (Manual p. 24.)

## 1. Critical reads (do these first)

These test our understanding of how SW3 (the DI4-COM switch) selects the speed source.

| Code | Expected | Why it matters |
|---|---|---|
| P0.1.00 | **8** | Frequency source switched by DI terminals. If it's 0, the DI4 explanation is wrong |
| P0.1.01 | **2** | Source B = panel potentiometer (used when SW3 is closed) |
| P0.0.02 | 0? | Mike's notes say 3, which isn't a valid option (0=V/F, 1=vector, 2=reserved) |
| P2.0.03 | 18 | DI4 = frequency source select 1 |
| P0.0.04 | 3 | Source A = VF1 (used when SW3 is open) |
| P0.0.03 | 1 | Terminal control: DI1 starts the spindle |

## 2. Check-mode comparison

1. Set **P0.0.01 = 2** (Check mode). The keypad now lists only parameters that differ from factory, with a **C** prefix instead of P.
2. Step through the list and write down every code and value.
3. Compare with the "Parameters changed from factory" table in `differences.md` (the `freq_control` column). Note anything extra, missing, or different. P0.0.01 itself will appear. Expect P0.1.00 and P0.1.01 to appear as extras (see step 1).
4. Set **P0.0.01 = 0** when done.

## 3. Parameters Check mode may not show

The manual gives no factory value for these, so read each one directly:

| Code | What it is | Expected |
|---|---|---|
| P0.0.16 | Motor rated voltage | 220 |
| P0.0.19 | Stator resistance | unknown |
| P0.0.20 | Rotor resistance | unknown |
| P0.0.21 | Leakage inductance | unknown |
| P0.0.22 | Mutual inductance | unknown |
| P0.0.23 | No-load current | unknown |
| P0.1.11 to P0.1.16 | Accel/decel times 2-4 | unknown |
| P1.0.22 | Carrier frequency | unknown |

## 4. Format and hardware

- **Decimal places:** note exactly how the keypad shows P0.0.07 (e.g. `800.0` or `800.00`).
- **Jumpers J5 and J6** on the drive's control board, near the terminals (manual p. 19). Note whether each is on the **U** (voltage) or **I** (current) side. Both should be **U** for the RPM-control controller. *Power off and wait 10 minutes before opening the drive.*

## 5. Record the results

Edit `VFD/settings.csv` on GitHub (pencil icon):

- Correct any `freq_control` values that differ, with a note saying "read at drive."
- Fill in the blank `freq_control` values from step 3.
- In `configurations.csv`, change the `freq_control` status to `in service; verified YYYY-MM-DD at the drive` and fill in `in_service`/`configured_by` if known.
- Commit with a one-line message, e.g. "freq_control verified at the drive."

If the critical reads in step 1 don't match, stop before step 6 and talk it through with Mike. The RPM-control plan depends on them.

## 6. Save the backup (last)

Only after the machine has been confirmed working normally on the original controller (spindle starts from the switch box, speed set with the panel knob, warning lights correct):

- Set **P5.0.19 = 30**. This saves the current settings as the drive's user backup. The session card uses it (P5.0.19 = 60) to put the machine back in service after RPM-control test sessions.
- **Never P5.0.19 = 9 or 19.** Those are factory resets.

Then note the date of the backup in `configurations.csv` or the commit message.
