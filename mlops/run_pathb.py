#!/usr/bin/env python3
"""
THERMOSTAT — run the whole Path B pipeline with one command.

Path B overlays a real weather trace onto PPG-DaLiA physiology that was never
recorded under it. Its purpose is to prove the pipeline runs end to end —
ingest, label, leave-one-subject-out training, baselines, model export, Dart
parity — before any of your own telemetry exists. It is the thing to run live
at a progress check when someone asks whether the machine learning works.

Its metrics are NOT results. See ingest_dalia.py's docstring for the three
reasons why, and fetch_weather.py for the third.

Everything Path B produces is kept in its own subdirectories —
data/clean/pathb/ and results/pathb/ — so it can never be confused with, or
silently swept into, a training run over real data.

Paths resolve against the repository, not the shell's working directory, so
this works from anywhere:

    python run_pathb.py --environment ../data/weather_zamboanga.csv
    python mlops/run_pathb.py --environment data/weather_zamboanga.csv
"""
from __future__ import annotations

import argparse
import csv
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

DALIA_DEFAULT = ROOT / "data" / "raw" / "ppg+dalia" / "data" / "PPG_FieldStudy"
CLEAN = ROOT / "data" / "clean" / "pathb"
RESULTS = ROOT / "results" / "pathb"
# Deliberately NOT app/assets/model.json — see --install-model below.
MODEL_OUT = ROOT / "app" / "assets" / "model.pathb_test.json"


def run(cmd: list, step: str) -> None:
    """Run a stage, echoing the real command so it can be reproduced by hand."""
    print(f"\n\033[1m── {step} ─────────────────────────────────\033[0m")
    printable = " ".join(str(c) for c in cmd)
    print(f"$ {printable}\n")
    result = subprocess.run([str(c) for c in cmd], cwd=HERE)
    if result.returncode != 0:
        raise SystemExit(
            f"\n!! {step} failed (exit {result.returncode}).\n"
            "   Nothing downstream ran. Fix this stage and re-run —\n"
            "   completed stages are cheap to redo.")


def read_profiles(path: Path) -> list[dict]:
    if not path.exists():
        raise SystemExit(f"{path} not found — the ingest stage did not finish")
    with path.open() as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        raise SystemExit(f"{path} is empty")
    return rows


def numeric(row: dict, key: str):
    raw = (row.get(key) or "").strip()
    if raw in ("", "nan", "None"):
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--environment", required=True,
                    help="weather CSV from fetch_weather.py")
    ap.add_argument("--dalia", default=str(DALIA_DEFAULT),
                    help="the PPG_FieldStudy directory")
    ap.add_argument("--trees", type=int, default=60)
    ap.add_argument("--depth", type=int, default=8)
    ap.add_argument("--install-model", action="store_true",
                    help="ALSO copy the exported forest to app/assets/model.json, "
                         "so the phone runs it. Only for a live demo.")
    ap.add_argument("--keep", action="store_true",
                    help="keep previous Path B outputs instead of clearing them")
    args = ap.parse_args()

    env_csv = Path(args.environment)
    if not env_csv.is_absolute():
        # Accept a path relative to either the repo root or mlops/.
        for base in (Path.cwd(), HERE, ROOT):
            if (base / env_csv).exists():
                env_csv = (base / env_csv).resolve()
                break
    if not env_csv.exists():
        raise SystemExit(
            f"weather file not found: {args.environment}\n"
            "  Get one first:  python fetch_weather.py")

    dalia = Path(args.dalia)
    if not dalia.is_absolute():
        dalia = (Path.cwd() / dalia).resolve()
    if not dalia.exists():
        raise SystemExit(f"PPG_FieldStudy not found: {dalia}")

    print("=" * 68)
    print("PATH B — SYNTHETIC ENVIRONMENTAL PAIRING")
    print("Pipeline test. Every output is a demonstration that the machinery")
    print("runs. None of it is a finding about heat physiology.")
    print("=" * 68)
    print(f"\n  physiology   {dalia}")
    print(f"  environment  {env_csv}")
    print(f"  outputs      {CLEAN}  and  {RESULTS}")

    if not args.keep and CLEAN.exists():
        shutil.rmtree(CLEAN)
    CLEAN.mkdir(parents=True, exist_ok=True)
    RESULTS.mkdir(parents=True, exist_ok=True)

    # 1 — the foundation. Everything downstream inherits any error here.
    run([sys.executable, "labeling.py", "--self-test"], "1/6  self-test")

    # 2 — ingest with the environment overlaid
    run([sys.executable, "ingest_dalia.py", dalia,
         "--out", CLEAN, "--environment", env_csv], "2/6  ingest")

    # 3 — label each subject from its own profile
    profiles = read_profiles(CLEAN / "profiles_dalia.csv")
    print(f"\n\033[1m── 3/6  label {len(profiles)} subjects "
          f"───────────────────\033[0m")
    labeled, skipped = 0, []
    for row in profiles:
        pid = row["participant"]
        age = numeric(row, "age_years")
        height = numeric(row, "height_cm")
        weight = numeric(row, "weight_kg")
        rest = numeric(row, "resting_hr_bpm_ESTIMATED")
        if None in (age, height, weight, rest):
            skipped.append(pid)
            continue
        csv_path = CLEAN / f"{pid}_dalia_SYNTHETIC.csv"
        if not csv_path.exists():
            skipped.append(pid)
            continue
        proc = subprocess.run(
            [sys.executable, "labeling.py", str(csv_path),
             "--user-id", pid, "--age", f"{age:.0f}", "--height", f"{height:.0f}",
             "--weight", f"{weight:.0f}", "--rest-hr", f"{rest:.0f}"],
            cwd=HERE, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"  {pid}: FAILED\n{proc.stdout[-500:]}{proc.stderr[-500:]}")
            skipped.append(pid)
        else:
            labeled += 1
            print(f"  {pid}: labeled")
    if skipped:
        print(f"  skipped (incomplete profile or missing file): "
              f"{', '.join(skipped)}")
    if labeled < 2:
        raise SystemExit("need at least 2 labeled subjects for "
                         "leave-one-subject-out cross-validation")
    print(f"  {labeled} subjects labeled")

    files = sorted(str(p) for p in CLEAN.glob("*_SYNTHETIC_labeled.csv"))

    # 4 — train under LOSO, with ablation and persistence baseline
    run([sys.executable, "train_model.py", *files, "--out", RESULTS],
        "4/6  train (LOSO + ablation + persistence)")

    # 5 — the baselines that justify not reporting accuracy
    run([sys.executable, "compare_baselines.py", *files], "5/6  baselines")

    # 6 — export, with the Python/Dart parity assertion inside
    MODEL_OUT.parent.mkdir(parents=True, exist_ok=True)
    run([sys.executable, "export_model_dart.py", *files,
         "--out", MODEL_OUT, "--trees", args.trees, "--depth", args.depth],
        "6/6  export to Dart asset")

    if args.install_model:
        live = ROOT / "app" / "assets" / "model.json"
        shutil.copy2(MODEL_OUT, live)
        print(f"\n  !! installed to {live}")
        print("     The app will now run a forest trained on synthetic")
        print("     pairings. Fine for a demo. Delete it before the app goes")
        print("     anywhere near a participant.")

    print("\n" + "=" * 68)
    print("PATH B COMPLETE — the pipeline runs end to end.")
    print("=" * 68)
    print(f"""
What you just demonstrated, in order:
  the labeling engine passes its own self-tests
  15 subjects ingested and paired with observed weather
  {labeled} subjects labeled through the PAGASA + PSI fusion rule
  a Random Forest trained under leave-one-subject-out CV
  measured against an environment-only ablation and a persistence baseline
  exported to a Dart asset, with sklearn/pure-Python parity asserted

Report per-fold metrics: {RESULTS / 'training_report.json'}
Model asset:             {MODEL_OUT}

What you may say about this:
  "The pipeline is implemented and runs end to end on public data."
What you may not say:
  any number it printed, as a performance result.
The environment and the physiology were never co-recorded, and the weather
day was chosen for being hot. The metrics describe that choice.""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
