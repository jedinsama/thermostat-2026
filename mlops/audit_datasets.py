#!/usr/bin/env python3
"""
THERMOSTAT — audit every dataset in data/raw/ and report what each can do.

This is the script that turns "no public dataset pairs dangerous heat with
concurrent physiology" from an assertion into a finding. Point it at the raw
directory and it inspects whatever is there, reports which of the four columns
`labeling.py` requires are actually present, and prints a verdict per dataset
plus a table you can lift into Chapter III.

    timestamp · ambient_temp_c · relative_humidity_pct · heart_rate_bpm

It reads nothing into the pipeline and writes nothing except an optional CSV
summary. Safe to run any time.

Usage:
    python audit_datasets.py
    python audit_datasets.py --raw ../data/raw --out ../results/dataset_audit.csv
"""
from __future__ import annotations

import argparse
import pickle
import re
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

# What each schema slot can plausibly be called in someone else's dataset.
# Matched case-insensitively as substrings, longest-alias-first.
ALIASES = {
    "ambient_temp_c": ["air temperature", "ambient", "temperature_60",
                       "temperature", "air_temp", "ta_", "tdb", "temp"],
    "relative_humidity_pct": ["relative humidity", "humidity", "rh"],
    "heart_rate_bpm": ["heart rate", "heart_rate", "heartrate", "hr_", "bpm",
                       "pulse", "hr"],
    "spo2_pct": ["spo2", "oxygen saturation", "sao2", "oxygen"],
    "skin_temp_c": ["skin temperature", "skin_temp", "wristt", "wrist_temp",
                    "tsk", "skint"],
    "timestamp": ["timestamp", "vote_time", "datetime", "date_time", "time",
                  "date"],
    "_subject": ["subject", "participant", "person", "id"],
}
REQUIRED = ("timestamp", "ambient_temp_c", "relative_humidity_pct",
            "heart_rate_bpm")

TICK, CROSS, WARN = "yes", "NO", "windowed"


def is_windowed(col) -> bool:
    """Tartarini-style pre-computed statistic, e.g. mean.Temperature_60."""
    return bool(re.match(r"^(mean|grad|sd)\.", str(col)))


def _tokens(name: str) -> set[str]:
    return set(t for t in re.split(r"[^a-z0-9]+", name.lower()) if t)


def _pick(candidates: list[str]) -> str:
    """Deterministic choice when several columns match the same slot."""
    means = [c for c in candidates if is_windowed(c) and str(c).startswith("mean.")]
    pool = means or candidates
    return sorted(pool, key=lambda c: (len(str(c)), str(c)))[0]


def match(columns: list[str], slot: str) -> str | None:
    """
    Find the best column for a schema slot, or None.

    Short aliases must match a whole token. Substring matching on 'id' or 'hr'
    is how 'Relative humidity (%)' gets mistaken for a subject identifier —
    it did, and reported 5,000 subjects in an ASHRAE file that has none.
    """
    lower = {c: str(c).lower() for c in columns}
    toks = {c: _tokens(str(c)) for c in columns}

    for alias in ALIASES[slot]:                      # 1. exact column name
        hits = [c for c, lc in lower.items() if lc == alias]
        if hits:
            return _pick(hits)
    for alias in ALIASES[slot]:                      # 2. whole token
        hits = [c for c in columns if alias in toks[c]]
        if hits:
            return _pick(hits)
    for alias in ALIASES[slot]:                      # 3. substring, long only
        if len(alias) < 4:
            continue
        hits = [c for c, lc in lower.items() if alias in lc]
        if hits:
            return _pick(hits)
    return None


def human(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return f"{n:.1f} GB"


def dir_size(p: Path) -> int:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


# ---------------------------------------------------------------------------
# ASHRAE DB II carries international city names, so it is not UTF-8. A reader
# with no fallback reports the file as UNREADABLE, which is not a finding you
# can cite — it is a missing feature in the reader.
ENCODINGS = ("utf-8", "utf-8-sig", "latin-1", "cp1252")


def read_head(path: Path, nrows: int = 5000):
    """Return (dataframe, encoding). Tries encodings in order of preference."""
    last = None
    for enc in ENCODINGS:
        try:
            return pd.read_csv(path, nrows=nrows, low_memory=False,
                               encoding=enc), enc
        except UnicodeDecodeError as e:
            last = e
            continue
        except Exception as e:
            raise e
    raise last


def audit_csv(path: Path) -> dict:
    try:
        head, encoding = read_head(path)
    except Exception as e:
        return {"name": path.name, "kind": "csv", "error": str(e)[:120]}

    cols = list(head.columns)
    # Row count without loading the whole file into memory.
    with path.open("rb") as fh:
        rows = sum(1 for _ in fh) - 1

    found = {slot: match(cols, slot) for slot in ALIASES}
    windowed = [c for c in cols if re.match(r"^(mean|grad|sd)\.", str(c))]

    subjects = None
    if found["_subject"]:
        try:
            subjects = int(head[found["_subject"]].nunique())
        except Exception:
            pass

    return {
        "name": path.name, "kind": "csv", "path": path,
        "size": human(path.stat().st_size), "rows": rows, "cols": len(cols),
        "found": found, "windowed": windowed, "subjects": subjects,
        "sample_cols": cols[:8], "encoding": encoding,
    }


def audit_dalia(root: Path) -> dict:
    pkls = sorted(root.rglob("S*.pkl"))
    if not pkls:
        return {}
    try:
        with pkls[0].open("rb") as fh:
            obj = pickle.load(fh, encoding="latin1")
    except Exception as e:
        return {"name": "PPG-DaLiA", "kind": "pkl", "error": str(e)[:120]}

    wrist = list((obj.get("signal") or {}).get("wrist", {}).keys())
    chest = list((obj.get("signal") or {}).get("chest", {}).keys())
    n_hr = len(obj.get("label", []))

    return {
        "name": "PPG-DaLiA", "kind": "pkl", "path": root,
        "size": human(dir_size(root)), "rows": n_hr * len(pkls),
        "cols": len(wrist) + len(chest) + 2, "subjects": len(pkls),
        # Environment is absent by construction — no sensor recorded it.
        "found": {
            "timestamp": "(implicit: fixed sample rate)",
            "ambient_temp_c": None, "relative_humidity_pct": None,
            "heart_rate_bpm": "label (ECG-derived, 0.5 Hz)",
            "spo2_pct": None,
            "skin_temp_c": "wrist/TEMP (4 Hz)" if "TEMP" in wrist else None,
            "_subject": "one directory per subject",
        },
        "windowed": [],
        "sample_cols": [f"wrist:{','.join(wrist)}", f"chest:{','.join(chest)}"],
    }


# ---------------------------------------------------------------------------
def verdict(a: dict) -> tuple[str, str]:
    """(short verdict, why) — the line that goes in the manuscript table."""
    if a.get("error"):
        return "UNREADABLE", a["error"]

    f = a["found"]
    missing = [s for s in REQUIRED if not f.get(s)]

    if missing:
        lack = " and ".join(
            s.replace("_c", "").replace("_pct", "").replace("_", " ")
            for s in missing)
        return "CANNOT LABEL", f"no {lack} — labeling.py will refuse it"

    # All four slots filled, but if they are filled by pre-computed statistics
    # there is no instantaneous value to shift, so a fixed forecast horizon is
    # not meaningful on this file.
    proxied = [s for s in REQUIRED if is_windowed(f.get(s))]
    if proxied:
        return "LABELS, CANNOT FORECAST", (
            f"{len(a['windowed'])} pre-windowed columns; "
            f"{', '.join(proxied)} are window means standing in for "
            "instantaneous values")

    return "FULL PIPELINE", "all four required columns present"


def show(a: dict) -> None:
    print(f"\n\033[1m{a['name']}\033[0m")
    if a.get("error"):
        print(f"  !! unreadable: {a['error']}")
        return
    subj = a["subjects"] if a["subjects"] is not None else "?"
    print(f"  {a['size']:>9} · {a['rows']:,} rows · {a['cols']} columns · "
          f"{subj} subjects")
    if a.get("encoding") and a["encoding"] != "utf-8":
        print(f"  !!    not UTF-8 — read as {a['encoding']}. Pass "
              f"encoding='{a['encoding']}' to any pd.read_csv on this file.")

    for slot in ("timestamp", "ambient_temp_c", "relative_humidity_pct",
                 "heart_rate_bpm", "spo2_pct", "skin_temp_c"):
        col = a["found"].get(slot)
        mark = "  ok " if col else "  -- "
        req = " *" if slot in REQUIRED else "  "
        print(f"  {mark}{req} {slot:<24} {col if col else '(absent)'}")

    if a["windowed"]:
        print(f"  !!    {len(a['windowed'])} pre-windowed columns "
              f"(e.g. {', '.join(a['windowed'][:3])})")

    v, why = verdict(a)
    print(f"  -> \033[1m{v}\033[0m — {why}")


NEXT_STEP = {
    "raw_data_Liu.csv":
        "python split_tartarini.py ../data/raw/raw_data_Liu.csv --out ../data/clean",
    "PPG-DaLiA":
        "python ingest_dalia.py ../data/raw/ppg+dalia/data/PPG_FieldStudy "
        "--out ../data/clean",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=str(ROOT / "data" / "raw"))
    ap.add_argument("--out", default=None, help="write the summary as CSV")
    args = ap.parse_args()

    raw = Path(args.raw)
    if not raw.is_absolute():
        raw = (Path.cwd() / raw).resolve()
    if not raw.exists():
        raise SystemExit(f"not found: {raw}")

    print("=" * 70)
    print(f"DATASET AUDIT — {raw}")
    print("labeling.py requires: " + " · ".join(REQUIRED))
    print("=" * 70)

    audits = []

    dalia_roots = [p for p in raw.rglob("PPG_FieldStudy") if p.is_dir()]
    for d in dalia_roots:
        a = audit_dalia(d)
        if a:
            audits.append(a)

    for csv_path in sorted(raw.rglob("*.csv")):
        # Skip per-subject sidecars that belong to a dataset already audited.
        if any(d in csv_path.parents for d in dalia_roots):
            continue
        audits.append(audit_csv(csv_path))

    if not audits:
        raise SystemExit(f"no datasets found under {raw}")

    for a in audits:
        show(a)

    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    print(f"  {'dataset':<26}{'env':<6}{'phys':<6}{'verdict'}")
    rows = []
    for a in audits:
        v, why = verdict(a)
        f = a.get("found", {})
        env = "yes" if f.get("ambient_temp_c") and \
            f.get("relative_humidity_pct") else "NO"
        phys = "yes" if f.get("heart_rate_bpm") else "NO"
        print(f"  {a['name'][:25]:<26}{env:<6}{phys:<6}{v}")
        rows.append({"dataset": a["name"], "size": a.get("size"),
                     "rows": a.get("rows"), "subjects": a.get("subjects"),
                     "environment": env, "physiology": phys,
                     "verdict": v, "reason": why})

    full = [r for r in rows if r["verdict"] == "FULL PIPELINE"]
    print()
    if not full:
        print("  No dataset here can drive the risk label end to end.")
        print("  That is Finding 1, reproduced from your own files: no public")
        print("  corpus pairs dangerous heat with concurrent physiology.")
        print("  It is the justification for primary data collection.")
    else:
        print(f"  {len(full)} dataset(s) can drive the full pipeline: "
              f"{', '.join(r['dataset'] for r in full)}")

    todo = [a["name"] for a in audits if a["name"] in NEXT_STEP]
    if todo:
        print("\n  ingest commands for what is here:")
        for name in todo:
            print(f"    {NEXT_STEP[name]}")

    print("\n  Not present on disk: WESAD. It is cited in the RRL as a")
    print("  physiology-only corpus; PPG-DaLiA covers the same ground with")
    print("  ECG ground truth, so downloading it is optional.")

    if args.out:
        out = Path(args.out)
        if not out.is_absolute():
            out = (Path.cwd() / out).resolve()
        out.parent.mkdir(parents=True, exist_ok=True)
        pd.DataFrame(rows).to_csv(out, index=False)
        print(f"\n  wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
