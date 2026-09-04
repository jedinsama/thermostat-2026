#!/usr/bin/env python3
"""
THERMOSTAT — ingest PPG-DaLiA (Reiss et al. 2019) into our schema.

WHAT THIS DATASET IS, AND WHAT IT IS NOT
========================================
PPG-DaLiA is 15 subjects performing eight everyday activities — sitting,
stair climbing, table soccer, cycling, driving, lunch, walking, working —
for roughly two and a half hours each, wearing an Empatica E4 on the wrist
and a RespiBAN on the chest.

What it genuinely gives THERMOSTAT:

  heart_rate_bpm   The 'label' field, at 0.5 Hz. This is NOT a PPG estimate:
                   it is computed from chest-ECG R-peaks, so it is the
                   reference standard that our MAX30102 is trying to
                   approximate. Better than what we will collect ourselves.
  skin_temp_c      E4 wrist temperature at 4 Hz — the same anatomical site as
                   our MAX30205, which makes it the most transferable
                   temperature signal in any public dataset we have found.
  fixed intervals  Unlike Tartarini's irregular vote events, this is a real
                   time series, so the 20-minute forecast target is
                   arithmetically meaningful here.
  real HR range    Cycling and stair climbing push heart rate where a seated
                   comfort study never does. This is the only public source
                   we have for what grad/sd features look like under load.

What it does not contain, at all:

  ambient temperature · relative humidity · SpO2

CONSEQUENCE — READ THIS BEFORE RUNNING labeling.py
--------------------------------------------------
Our risk rule fuses a PAGASA heat-index band with a heart-rate strain index.
The heat index needs ambient temperature and humidity. PPG-DaLiA has neither,
so `labeling.py` will refuse the file, by design — it raises on a missing
required column rather than substituting a default. That refusal is correct.
Do not work around it by filling constants.

There are exactly two honest ways forward, and they are not equally strong.

  PATH A — physiology only.  (default; this is the one for the manuscript)
      Ingest without environment. Use the output to validate the feature
      window against real physiology, to characterise how much the grad and
      sd features actually move during daily activity, and to check the
      resting-HR estimator against a known sitting baseline. This is a
      COMPONENT VALIDATION and should be written up as one. It produces no
      risk labels and no model.

  PATH B — synthetic environmental pairing.  (--environment; pipeline test)
      Overlay a real Zamboanga weather trace onto a German ADL session. The
      environment and the physiology were never co-recorded, so the resulting
      labels describe a person who does not exist. Every row is stamped
      SYNTHETIC PAIRING, every output file is named *_SYNTHETIC.csv, and the
      provenance column travels with the data so the disclosure survives
      being copied around.

      Legitimate use: proving the pipeline runs end to end — ingest, label,
      LOSO training, model export, Dart parity — before real telemetry
      exists.

      Illegitimate use: reporting its accuracy, PR-AUC, or per-class recall
      as model performance. Those numbers are a property of the pairing you
      invented, not of heat physiology. Reporting them is claiming a finding
      about a person who does not exist, and an examiner who reads the
      provenance column will find it in one minute.

Usage
-----
    python ingest_dalia.py ~/Downloads/ppg+dalia/data/PPG_FieldStudy --inspect
    python ingest_dalia.py ~/Downloads/ppg+dalia/data/PPG_FieldStudy --out ../data/clean
    python ingest_dalia.py <root> --out ../data/clean --environment zamboanga_day.csv
"""
from __future__ import annotations

import argparse
import pickle
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd

# ---------------------------------------------------------------------------
# Sampling rates, from the dataset README. Changing these silently corrupts
# the timebase, which is why they are named constants and not literals.
# ---------------------------------------------------------------------------
FS_LABEL_HZ = 0.5      # ECG-derived HR: 8 s window, shifted by 2 s
FS_WRIST_TEMP_HZ = 4.0
FS_WRIST_ACC_HZ = 32.0
FS_ACTIVITY_HZ = 4.0

RESAMPLE = "1min"      # our schema's cadence, matching ingest_public.py

ACTIVITY_NAMES = {
    0: "transient", 1: "sitting", 2: "stairs", 3: "table_soccer",
    4: "cycling", 5: "driving", 6: "lunch", 7: "walking", 8: "working",
}
SITTING_ID = 1


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------
def load_pkl(path: Path) -> dict:
    """PPG-DaLiA pickles were written under Python 2; latin1 is required."""
    with open(path, "rb") as fh:
        return pickle.load(fh, encoding="latin1")


def _dig(d, *keys):
    """Case-insensitive nested lookup; returns None rather than raising."""
    cur = d
    for k in keys:
        if not isinstance(cur, dict):
            return None
        match = next((kk for kk in cur if str(kk).lower() == k.lower()), None)
        if match is None:
            return None
        cur = cur[match]
    return cur


def _series(arr, fs: float, start: pd.Timestamp) -> pd.Series | None:
    """Attach a synthetic timebase to a raw signal array."""
    if arr is None:
        return None
    a = np.asarray(arr, dtype=float).ravel()
    if a.size == 0:
        return None
    idx = start + pd.to_timedelta(np.arange(a.size) / fs, unit="s")
    return pd.Series(a, index=idx)


def _acc_magnitude(arr, fs: float, start: pd.Timestamp) -> pd.Series | None:
    """3-axis accelerometer -> scalar motion proxy, in g."""
    if arr is None:
        return None
    a = np.asarray(arr, dtype=float)
    if a.ndim != 2 or a.shape[1] < 3 or a.shape[0] == 0:
        return None
    mag = np.sqrt((a[:, :3] ** 2).sum(axis=1))
    # E4 reports in 1/64 g units; normalise if the scale looks raw.
    if np.nanmedian(mag) > 10:
        mag = mag / 64.0
    idx = start + pd.to_timedelta(np.arange(mag.size) / fs, unit="s")
    return pd.Series(mag, index=idx)


# ---------------------------------------------------------------------------
# Demographics
# ---------------------------------------------------------------------------
def _first_number(value):
    if value is None:
        return None
    if isinstance(value, (list, tuple, np.ndarray)):
        value = value[0] if len(value) else None
    m = re.search(r"-?\d+(?:\.\d+)?", str(value))
    return float(m.group()) if m else None


def read_profile(pkl: dict, quest_csv: Path) -> dict:
    """Demographics from the pickle's questionnaire, falling back to the CSV."""
    q = _dig(pkl, "questionnaire") or {}
    prof = {
        "age_years": _first_number(_dig(q, "AGE")),
        "height_cm": _first_number(_dig(q, "HEIGHT")),
        "weight_kg": _first_number(_dig(q, "WEIGHT")),
        "sex": str(_dig(q, "GENDER") or "").strip() or None,
        "sport_level": _first_number(_dig(q, "SPORT")),
        "profile_source": "pkl.questionnaire",
    }

    if any(prof[k] is None for k in ("age_years", "height_cm", "weight_kg")) \
            and quest_csv.exists():
        text = quest_csv.read_text(errors="replace")
        for key, pat in (("age_years", r"age\D{0,10}(\d+)"),
                         ("height_cm", r"height\D{0,10}(\d+(?:\.\d+)?)"),
                         ("weight_kg", r"weight\D{0,10}(\d+(?:\.\d+)?)")):
            if prof[key] is None:
                m = re.search(pat, text, re.IGNORECASE)
                if m:
                    prof[key] = float(m.group(1))
                    prof["profile_source"] = "quest.csv (regex fallback)"
        if prof["sex"] is None:
            m = re.search(r"gender\D{0,10}([mf])", text, re.IGNORECASE)
            if m:
                prof["sex"] = m.group(1).lower()

    # Height occasionally arrives in metres.
    if prof["height_cm"] is not None and prof["height_cm"] < 3:
        prof["height_cm"] *= 100.0
    return prof


def estimate_resting_hr(hr: pd.Series, activity: pd.Series | None) -> tuple:
    """
    Resting HR is not recorded. Prefer the sitting baseline, which is a real
    physiological state the protocol actually contains; fall back to the 5th
    percentile, matching the convention in split_tartarini.py so the two
    ingesters produce comparable profiles.
    """
    if activity is not None:
        sitting = hr[activity.reindex(hr.index, method="nearest") == SITTING_ID]
        sitting = sitting.dropna()
        if len(sitting) >= 5:
            return float(np.percentile(sitting, 10)), "sitting_p10"
    clean = hr.dropna()
    if not len(clean):
        return float("nan"), "unavailable"
    return float(np.percentile(clean, 5)), "overall_p05"


# ---------------------------------------------------------------------------
# Environment pairing (Path B)
# ---------------------------------------------------------------------------
def load_environment(path: Path) -> pd.DataFrame:
    """
    A real weather trace to overlay. Expected columns:

        timestamp,ambient_temp_c,relative_humidity_pct

    Pull one real day for your actual collection site from PAGASA or
    OpenWeatherMap. Keeping the environment real while disclosing that the
    pairing is synthetic is the weakest defensible position; inventing the
    weather too is not defensible at all.
    """
    env = pd.read_csv(path)
    need = {"timestamp", "ambient_temp_c", "relative_humidity_pct"}
    missing = need - set(env.columns)
    if missing:
        raise SystemExit(
            f"{path}: environment file missing columns {sorted(missing)}\n"
            "  expected header: timestamp,ambient_temp_c,relative_humidity_pct")
    env["timestamp"] = pd.to_datetime(env["timestamp"], errors="coerce")
    env = env.dropna(subset=["timestamp"]).sort_values("timestamp")
    env["_tod"] = (env["timestamp"].dt.hour * 3600
                   + env["timestamp"].dt.minute * 60
                   + env["timestamp"].dt.second)
    return env


def pair_environment(df: pd.DataFrame, env: pd.DataFrame) -> pd.DataFrame:
    """Match by time of day, so an 09:14 session minute gets 09:14 weather."""
    tod = (df["timestamp"].dt.hour * 3600
           + df["timestamp"].dt.minute * 60
           + df["timestamp"].dt.second)
    left = pd.DataFrame({"_tod": tod.values}).sort_values("_tod")
    merged = pd.merge_asof(
        left, env[["_tod", "ambient_temp_c", "relative_humidity_pct"]],
        on="_tod", direction="nearest")
    merged.index = left.index
    merged = merged.sort_index()
    df["ambient_temp_c"] = merged["ambient_temp_c"].values
    df["relative_humidity_pct"] = merged["relative_humidity_pct"].values
    return df


# ---------------------------------------------------------------------------
# Per-subject ingestion
# ---------------------------------------------------------------------------
def ingest_subject(pkl_path: Path, start: pd.Timestamp,
                   env: pd.DataFrame | None) -> tuple:
    pkl = load_pkl(pkl_path)

    hr_raw = _dig(pkl, "label")
    temp_raw = _dig(pkl, "signal", "wrist", "TEMP")
    acc_raw = _dig(pkl, "signal", "wrist", "ACC")
    act_raw = _dig(pkl, "activity")

    if hr_raw is None:
        raise SystemExit(f"{pkl_path.name}: no 'label' field — "
                         "run with --inspect and check the structure")

    hr = _series(hr_raw, FS_LABEL_HZ, start)
    temp = _series(temp_raw, FS_WRIST_TEMP_HZ, start)
    acc = _acc_magnitude(acc_raw, FS_WRIST_ACC_HZ, start)
    act = _series(act_raw, FS_ACTIVITY_HZ, start)

    parts = {"heart_rate_bpm": hr.resample(RESAMPLE).median()}
    if temp is not None:
        parts["skin_temp_c"] = temp.resample(RESAMPLE).median()
    if acc is not None:
        parts["motion_g"] = acc.resample(RESAMPLE).median()
    if act is not None:
        parts["activity_id"] = act.resample(RESAMPLE).median().round()

    df = pd.DataFrame(parts)
    df.index.name = "timestamp"
    df = df.reset_index()

    if "activity_id" in df.columns:
        df["activity"] = df["activity_id"].map(
            lambda v: ACTIVITY_NAMES.get(int(v), "unknown")
            if pd.notna(v) else "unknown")

    if env is not None:
        df = pair_environment(df, env)
        df["provenance"] = (
            "ppg_dalia_2019 + external_weather "
            "(SYNTHETIC PAIRING — environment and physiology "
            "were NOT co-recorded)")
    else:
        # ambient_temp_c and relative_humidity_pct are deliberately ABSENT,
        # not present-and-empty. This is load-bearing.
        #
        # An earlier draft wrote them as all-NaN columns "so the gap would be
        # visible in the file". That defeated the guard in labeling.py, whose
        # schema check only tests for the column's presence: the file sailed
        # through, every heat_index_c came out NaN, and the labeller emitted
        # 128 Safe + 2 Caution rows driven purely by heart-rate strain. The
        # output looked like a perfectly ordinary labelled dataset. Nothing
        # warned anyone that half the risk model was missing.
        #
        # Omitting the columns makes labeling.py raise
        #   ValueError: missing required column(s): ['ambient_temp_c', ...]
        # A loud failure beats a plausible-looking file every time.
        df["provenance"] = "ppg_dalia_2019(physiology_only)"

    resting, method = estimate_resting_hr(
        df.set_index("timestamp")["heart_rate_bpm"],
        df.set_index("timestamp")["activity_id"] if "activity_id" in df else None)

    return df, resting, method, pkl


# ---------------------------------------------------------------------------
def do_inspect(root: Path) -> int:
    subs = sorted(root.glob("S*/S*.pkl"))
    if not subs:
        raise SystemExit(f"no S*/S*.pkl under {root}")
    p = subs[0]
    print(f"inspecting {p}\n")
    pkl = load_pkl(p)
    print(f"top-level keys: {list(pkl.keys())}")
    sig = _dig(pkl, "signal") or {}
    for dev in sig:
        print(f"  signal[{dev!r}]: {list(sig[dev].keys())}")
        for ch, arr in sig[dev].items():
            a = np.asarray(arr)
            print(f"      {ch:<6} shape={a.shape} dtype={a.dtype} "
                  f"first={np.ravel(a)[:1]}")
    for k in ("label", "activity", "rpeaks", "subject"):
        v = _dig(pkl, k)
        if v is not None:
            a = np.asarray(v)
            print(f"  {k}: shape={a.shape} dtype={a.dtype}")
    q = _dig(pkl, "questionnaire")
    print(f"  questionnaire: {q}")
    print(f"\nsubjects found: {len(subs)}")
    print("\nverify these against PPG_FieldStudy_readme.pdf before ingesting.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="the PPG_FieldStudy directory")
    ap.add_argument("--out", default="../data/clean")
    ap.add_argument("--inspect", action="store_true",
                    help="print the pickle structure of S1 and exit")
    ap.add_argument("--environment", type=Path, default=None,
                    help="PATH B: overlay a real weather trace. Output is a "
                         "pipeline test, never a result.")
    ap.add_argument("--start", default="2026-09-04 08:00:00",
                    help="nominal session start; only differences matter")
    ap.add_argument("--min-rows", type=int, default=30)
    args = ap.parse_args()

    root = Path(args.root).expanduser()
    if args.inspect:
        return do_inspect(root)

    env = load_environment(args.environment) if args.environment else None
    if env is not None:
        print("!" * 72)
        print("PATH B — SYNTHETIC ENVIRONMENTAL PAIRING")
        print("Output files are named *_SYNTHETIC.csv and every row carries a")
        print("provenance stamp. Use them to test the pipeline. Do NOT report")
        print("their metrics as model performance.")
        print("!" * 72 + "\n")

    start = pd.Timestamp(args.start)
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    pkls = sorted(root.glob("S*/S*.pkl"),
                  key=lambda p: int(re.search(r"S(\d+)", p.stem).group(1)))
    if not pkls:
        raise SystemExit(f"no S*/S*.pkl under {root}")
    print(f"found {len(pkls)} subjects under {root}\n")

    profiles = []
    for p in pkls:
        sid = int(re.search(r"S(\d+)", p.stem).group(1))
        code = f"D-{sid:02d}"
        df, resting, method, pkl = ingest_subject(p, start, env)

        if len(df) < args.min_rows:
            print(f"  {p.stem:>4} -> {code}: {len(df)} rows — SKIPPED")
            continue

        prof = read_profile(pkl, p.parent / f"{p.stem}_quest.csv")
        suffix = "_SYNTHETIC" if env is not None else ""
        df.to_csv(out_dir / f"{code}_dalia{suffix}.csv", index=False)

        bmi = None
        if prof["height_cm"] and prof["weight_kg"]:
            bmi = round(prof["weight_kg"] / (prof["height_cm"] / 100) ** 2, 1)

        hr_ok = 100.0 * df["heart_rate_bpm"].notna().mean()
        temp_ok = (100.0 * df["skin_temp_c"].notna().mean()
                   if "skin_temp_c" in df else 0.0)

        profiles.append({
            "participant": code, "source_id": p.stem,
            "age_years": prof["age_years"], "sex": prof["sex"],
            "height_cm": prof["height_cm"], "weight_kg": prof["weight_kg"],
            "bmi": bmi,
            "resting_hr_bpm_ESTIMATED": round(resting, 1),
            "resting_hr_method": method,
            "profile_source": prof["profile_source"],
            "rows_1min": len(df),
            "hr_completeness_pct": round(hr_ok, 1),
            "skin_temp_completeness_pct": round(temp_ok, 1),
            "hr_min": round(float(df["heart_rate_bpm"].min()), 1),
            "hr_max": round(float(df["heart_rate_bpm"].max()), 1),
        })
        print(f"  {p.stem:>4} -> {code}: {len(df):>4} min, "
              f"age {prof['age_years']}, BMI {bmi}, "
              f"HR {profiles[-1]['hr_min']:.0f}–{profiles[-1]['hr_max']:.0f} bpm, "
              f"resting ~{resting:.0f} ({method})")

    if not profiles:
        raise SystemExit("no subject met --min-rows")

    pf = pd.DataFrame(profiles)
    pf.to_csv(out_dir / "profiles_dalia.csv", index=False)
    print(f"\nwrote {len(pf)} subject files + profiles_dalia.csv -> {out_dir}")
    print(f"mean HR completeness: {pf['hr_completeness_pct'].mean():.1f}%  |  "
          f"mean wrist-temp completeness: "
          f"{pf['skin_temp_completeness_pct'].mean():.1f}%")
    print(f"HR range across all subjects: "
          f"{pf['hr_min'].min():.0f}–{pf['hr_max'].max():.0f} bpm")

    if env is None:
        print("""
PATH A — physiology only. ambient_temp_c and relative_humidity_pct are empty,
so labeling.py will refuse these files. That is correct, not a bug.

What these files ARE for:
  * validating feature_window.dart / labeling.py windowing on real physiology
  * measuring how much grad and sd features move under real activity
  * checking the resting-HR estimator against a known sitting baseline
  * a defensible HR range for the manuscript, from ECG ground truth

To run the pipeline end to end you need Path B:
  python ingest_dalia.py <root> --out <dir> --environment <weather.csv>
and its numbers are a pipeline test, not a result.""")
    else:
        r = pf.iloc[0]
        print(f"""
Next — label one subject:
  python labeling.py {out_dir}/{r['participant']}_dalia_SYNTHETIC.csv \\
      --user-id {r['participant']} --age {r['age_years']:.0f} \\
      --height {r['height_cm']:.0f} --weight {r['weight_kg']:.0f} \\
      --rest-hr {r['resting_hr_bpm_ESTIMATED']:.0f}

Reminder: the labels describe a German ADL session under Philippine weather
that nobody experienced. Pipeline test only.""")
    return 0


if __name__ == "__main__":
    sys.exit(main())
