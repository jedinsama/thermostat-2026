#!/usr/bin/env python3
"""
THERMOSTAT — ingest a public dataset into the labeling.py schema.

WHY THIS IS NEEDED
------------------
labeling.py requires four columns:

    timestamp, ambient_temp_c, relative_humidity_pct, heart_rate_bpm
    (spo2_pct optional)

No public dataset ships with exactly those names, and — this is the important
part — **most public datasets contain only half of what the risk rule needs**:

    Tartarini (Dryad 10.15146/R3S68S)  HR + environment      -> FULL pipeline
    PPG-DaLiA (UCI 495)                physiology only       -> HR path only
    WESAD (UCI / ICMI 2018)            physiology only       -> HR path only
    ASHRAE Global DB II (Dryad)        environment only      -> env path only

A physiology-only dataset cannot drive the risk label on its own, because
there is no ambient temperature or humidity to compute a heat index from.
This script therefore does two things and never silently confuses them:

  1. MAP an existing dataset's columns onto our schema (--map), and
  2. optionally PAIR a physiology file with a separate environment file
     (--environment), stamping every row with `provenance` so the pairing is
     visible in the data itself and can be disclosed in Chapter IV.

A paired row is a synthetic construction. It is legitimate for validating
that the pipeline runs end to end; it is NOT evidence about real people in
real heat, and the provenance column exists so nobody can lose track of that.

USAGE
-----
  # Tartarini-style file that already has both halves
  py ingest_public.py raw/tartarini.csv --out clean/tartarini.csv \\
      --map ts=timestamp,t_a=ambient_temp_c,rh=relative_humidity_pct,hr=heart_rate_bpm

  # physiology-only file, paired with a separate environment series
  py ingest_public.py raw/dalia_S3.csv --out clean/dalia_S3.csv \\
      --map time=timestamp,HR=heart_rate_bpm \\
      --environment raw/ashrae_manila.csv \\
      --environment-map ts=timestamp,ta=ambient_temp_c,rh=relative_humidity_pct

  # inspect columns before deciding a mapping
  py ingest_public.py raw/whatever.csv --inspect
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

REQUIRED = ["timestamp", "ambient_temp_c", "relative_humidity_pct",
            "heart_rate_bpm"]
OPTIONAL = ["spo2_pct", "skin_temp_c"]

# Column names we can recognise without being told, lowercased.
GUESSES = {
    "timestamp": ["timestamp", "time", "datetime", "date_time", "ts", "t"],
    "ambient_temp_c": ["ambient_temp_c", "air_temp", "ta", "t_a", "temp_c",
                       "air_temperature", "ta_c", "temperature"],
    "relative_humidity_pct": ["relative_humidity_pct", "rh", "humidity",
                              "relative_humidity", "rh_pct"],
    "heart_rate_bpm": ["heart_rate_bpm", "hr", "heart_rate", "heartrate",
                       "bpm", "pulse"],
    "spo2_pct": ["spo2_pct", "spo2", "sp02", "oxygen_saturation", "sao2"],
    "skin_temp_c": ["skin_temp_c", "skin_temperature", "tsk", "t_skin",
                    "wrist_temp"],
}


def parse_map(s: str | None) -> dict[str, str]:
    """'a=timestamp,b=heart_rate_bpm' -> {'a': 'timestamp', ...}"""
    if not s:
        return {}
    out = {}
    for pair in s.split(","):
        if "=" not in pair:
            raise SystemExit(f"bad --map entry '{pair}', expected source=target")
        src, dst = pair.split("=", 1)
        out[src.strip()] = dst.strip()
    return out


def auto_guess(df: pd.DataFrame) -> dict[str, str]:
    """Best-effort column detection; every guess is printed for review."""
    lower = {c.lower().strip(): c for c in df.columns}
    found = {}
    for target, candidates in GUESSES.items():
        for cand in candidates:
            if cand in lower:
                found[lower[cand]] = target
                break
    return found


def resample_to_minute(df: pd.DataFrame) -> pd.DataFrame:
    """
    Collapse to one row per minute by median.

    Public physiology datasets are sampled at 4-64 Hz. Feeding that straight
    into labeling.py would produce millions of near-identical rows that inflate
    the dataset without adding information, and the 5/15/60-minute rolling
    windows would be enormous. The median also rejects the motion artefacts
    that dominate wrist PPG.
    """
    out = df.set_index("timestamp").sort_index()
    num = out.select_dtypes(include=[np.number])
    res = num.resample("1min").median()
    res = res.dropna(how="all").reset_index()
    return res


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="raw dataset CSV")
    ap.add_argument("--out", help="output CSV in labeling.py schema")
    ap.add_argument("--map", help="source=target,source=target …")
    ap.add_argument("--environment", help="separate environment CSV to pair with")
    ap.add_argument("--environment-map", help="mapping for the environment CSV")
    ap.add_argument("--inspect", action="store_true",
                    help="print columns and a guessed mapping, then exit")
    ap.add_argument("--source-name", default=None,
                    help="provenance label (defaults to the input filename)")
    ap.add_argument("--no-resample", action="store_true",
                    help="keep the native sampling rate (not recommended)")
    args = ap.parse_args()

    df = pd.read_csv(args.csv)
    print(f"read {args.csv}: {len(df):,} rows, {len(df.columns)} columns")

    if args.inspect:
        print("\ncolumns:")
        for c in df.columns:
            print(f"  {c:<32} {str(df[c].dtype):<10} e.g. {df[c].dropna().iloc[0] if df[c].notna().any() else '—'}")
        guess = auto_guess(df)
        print("\nguessed mapping (verify before using):")
        if guess:
            print("  --map " + ",".join(f"{k}={v}" for k, v in guess.items()))
        else:
            print("  (nothing recognised — you must supply --map yourself)")
        return 0

    if not args.out:
        raise SystemExit("--out is required unless --inspect is given")

    mapping = parse_map(args.map) or auto_guess(df)
    if not mapping:
        raise SystemExit("no mapping supplied and nothing auto-detected; "
                         "run with --inspect first")
    print("applying mapping:")
    for k, v in mapping.items():
        print(f"  {k}  ->  {v}")
    df = df.rename(columns=mapping)
    keep = [c for c in REQUIRED + OPTIONAL if c in df.columns]
    df = df[keep].copy()

    if "timestamp" not in df.columns:
        raise SystemExit("no timestamp column after mapping — cannot proceed")
    df["timestamp"] = pd.to_datetime(df["timestamp"], errors="coerce")
    df = df.dropna(subset=["timestamp"])

    if not args.no_resample:
        before = len(df)
        df = resample_to_minute(df)
        print(f"resampled to 1-minute medians: {before:,} -> {len(df):,} rows")

    src = args.source_name or Path(args.csv).stem
    df["provenance"] = src

    # ---- pair with a separate environment series, if asked ----------------
    if args.environment:
        env = pd.read_csv(args.environment)
        env_map = parse_map(args.environment_map) or auto_guess(env)
        env = env.rename(columns=env_map)
        env_keep = [c for c in ["timestamp", "ambient_temp_c",
                                "relative_humidity_pct"] if c in env.columns]
        env = env[env_keep].copy()
        if "timestamp" not in env.columns:
            raise SystemExit("environment file has no timestamp after mapping")
        env["timestamp"] = pd.to_datetime(env["timestamp"], errors="coerce")
        env = env.dropna(subset=["timestamp"])
        if not args.no_resample:
            env = resample_to_minute(env)

        # Align by position from each series' own start, not by wall-clock:
        # the two recordings are unrelated in absolute time.
        n = min(len(df), len(env))
        if n == 0:
            raise SystemExit("nothing to pair — one of the files is empty")
        df = df.iloc[:n].reset_index(drop=True)
        env = env.iloc[:n].reset_index(drop=True)
        for c in ["ambient_temp_c", "relative_humidity_pct"]:
            if c in env.columns:
                df[c] = env[c].values
        env_src = Path(args.environment).stem
        df["provenance"] = f"{src}+{env_src}(SYNTHETIC PAIRING)"
        print(f"\n!! PAIRED physiology from '{src}' with environment from "
              f"'{env_src}' over {n:,} rows.")
        print("   These recordings are NOT of the same people at the same time.")
        print("   Every row is stamped in the `provenance` column. This data is")
        print("   valid for PIPELINE VALIDATION ONLY and must be reported as")
        print("   such in Chapter IV — never as evidence about real exposure.")

    # ---- honest completeness report --------------------------------------
    print("\ncoverage against labeling.py requirements:")
    missing = []
    for c in REQUIRED:
        if c in df.columns:
            pct = 100.0 * df[c].notna().mean()
            print(f"  {c:<26} present, {pct:5.1f}% complete")
        else:
            print(f"  {c:<26} MISSING")
            missing.append(c)
    for c in OPTIONAL:
        if c in df.columns:
            print(f"  {c:<26} present (optional), "
                  f"{100.0 * df[c].notna().mean():5.1f}% complete")

    if missing:
        print(f"\n!! {len(missing)} required column(s) missing: {missing}")
        print("   labeling.py will refuse this file. Either map them from")
        print("   another column, or pair an environment file with")
        print("   --environment. Do NOT invent values.")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out, index=False)
    print(f"\nwrote {out}  ({len(df):,} rows)")
    if not missing:
        print("\nnext:")
        print(f"  py labeling.py {out} --user-id P-01 --age 30 "
              f"--height 170 --weight 70 --rest-hr 60")
    return 0


if __name__ == "__main__":
    sys.exit(main())
