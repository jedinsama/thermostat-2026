#!/usr/bin/env python3
"""
THERMOSTAT — split the Tartarini/Liu dataset into per-subject files.

WHAT THIS DATASET ACTUALLY IS
-----------------------------
`raw_data_Liu.csv` (Dryad 10.15146/R3S68S) is NOT a raw time series. It is
3,843 thermal-comfort *votes* from 14 subjects, each row already carrying
mean/gradient/sd features over 60- and 480-minute environmental windows and
5/15/60-minute physiological windows. Our own `labeling.py` borrowed this
windowing schema from their paper — so the file is the schema's origin, not
a sample of it.

Three consequences, stated plainly because they change what the data is good
for:

1. There is no instantaneous ambient temperature or heart rate. The closest
   honest substitutes are `mean.Temperature_60` and `mean.hr_5`, and this
   script uses them. That is an approximation and must be reported as one.
2. Votes are irregularly spaced events, not a fixed-interval series, so the
   20-minute FORECAST target in `make_forecast_target` is not meaningful
   here. Use this dataset for LABELING and for the completeness statistic,
   not for training the forecaster.
3. It is an indoor thermal-comfort study. Temperatures sit in the low 20s °C.
   Expect the labels to come out overwhelmingly Safe — that IS the finding
   (no public dataset pairs dangerous heat with physiology), and reproducing
   it here is what turns an assertion in Chapter III into evidence.

Resting heart rate is not recorded, so it is ESTIMATED per subject as the 5th
percentile of `mean.hr_60` — the lowest sustained rate that subject exhibits.
That is a defensible proxy and is written into `profiles.csv` so the estimate
is visible rather than buried.

Usage:
    py split_tartarini.py ../data/raw/raw_data_Liu.csv --out ../data/clean
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

# Our schema  <-  their column
COLMAP = {
    "Vote_time":           "timestamp",
    "mean.Temperature_60": "ambient_temp_c",
    "mean.Humidity_60":    "relative_humidity_pct",
    "mean.hr_5":           "heart_rate_bpm",
    "mean.WristT_5":       "skin_temp_c",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--out", default="../data/clean")
    ap.add_argument("--min-rows", type=int, default=30,
                    help="skip subjects with fewer usable rows than this")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    print(f"read {args.csv}: {len(df):,} rows, {df['ID'].nunique()} subjects")

    missing = [c for c in COLMAP if c not in df.columns]
    if missing:
        raise SystemExit(f"expected columns not found: {missing}")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    profiles = []

    for sid, grp in df.groupby("ID"):
        sub = grp[list(COLMAP)].rename(columns=COLMAP).copy()
        sub["timestamp"] = pd.to_datetime(sub["timestamp"], errors="coerce")
        sub = sub.dropna(subset=["timestamp"]).sort_values("timestamp")
        sub["provenance"] = "tartarini_liu_2022(windowed_means)"

        if len(sub) < args.min_rows:
            print(f"  ID {sid:>3}: {len(sub):>4} rows — SKIPPED (below --min-rows)")
            continue

        code = f"P-{int(sid):02d}"
        path = out_dir / f"{code}_tartarini.csv"
        sub.to_csv(path, index=False)

        # Profile straight from the dataset. Height is in METRES here.
        row = grp.iloc[0]
        height_cm = float(row["Height"]) * 100.0
        weight_kg = float(row["Weight"])
        hr60 = pd.to_numeric(grp["mean.hr_60"], errors="coerce").dropna()
        resting = float(np.percentile(hr60, 5)) if len(hr60) else float("nan")
        hr_completeness = 100.0 * sub["heart_rate_bpm"].notna().mean()

        profiles.append({
            "participant": code, "source_id": int(sid),
            "age_years": int(row["Age"]), "sex": row["Sex"],
            "height_cm": round(height_cm, 1), "weight_kg": weight_kg,
            "bmi": round(weight_kg / (height_cm / 100) ** 2, 1),
            "resting_hr_bpm_ESTIMATED": round(resting, 1),
            "rows": len(sub),
            "hr_completeness_pct": round(hr_completeness, 1),
        })
        print(f"  ID {sid:>3} -> {code}: {len(sub):>4} rows, age {int(row['Age'])}, "
              f"BMI {profiles[-1]['bmi']}, resting HR ~{resting:.0f} "
              f"(est), HR {hr_completeness:.1f}% complete")

    if not profiles:
        raise SystemExit("no subject met --min-rows")

    pf = pd.DataFrame(profiles)
    pf.to_csv(out_dir / "profiles.csv", index=False)

    overall = pf["hr_completeness_pct"].mean()
    print(f"\nwrote {len(pf)} subject files + profiles.csv -> {out_dir}")
    print(f"mean heart-rate completeness across subjects: {overall:.1f}%")
    print("  ^ this is the figure cited in the Sample Size Justification.")
    print("    Use the number you actually get here, not the one in the draft.")

    print("\nnext — label one subject (numbers come from profiles.csv):")
    r = pf.iloc[0]
    print(f"  py labeling.py {out_dir}/{r['participant']}_tartarini.csv \\")
    print(f"      --user-id {r['participant']} --age {r['age_years']} "
          f"--height {r['height_cm']} --weight {r['weight_kg']} "
          f"--rest-hr {r['resting_hr_bpm_ESTIMATED']}")
    print("\nExpect overwhelmingly Safe/Caution labels and a saturation")
    print("warning. That reproduces Finding 1 — no public dataset pairs")
    print("dangerous heat with concurrent physiology — and it is evidence")
    print("for Chapter III, not a failure.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
