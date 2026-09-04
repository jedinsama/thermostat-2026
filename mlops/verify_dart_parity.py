#!/usr/bin/env python3
"""
THERMOSTAT — parity check between labeling.py and the Dart on-device port.

Two implementations of the same maths now exist: labeling.py (training) and
app/lib/core/{risk_rules,feature_window}.dart (inference). If they drift, the
model is fed features that differ from the ones it was trained on, and the
failure is silent — the app just gets quietly worse. This script pins the
contract with a golden-vector file both sides check against.

It writes `golden_vectors.json`: inputs plus the values labeling.py produces.
A matching Dart test (app/test/parity_test.dart) loads the same file and
asserts the Dart port reproduces them.

Usage:  py verify_dart_parity.py            # regenerate + self-check
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd

from labeling import (UserProfile, add_windowed_features, fuse_risk,
                      pagasa_risk_class, psi_heart_rate, psi_risk_class,
                      rothfusz_heat_index_c)

OUT = Path(__file__).parent / "golden_vectors.json"


def scalar_cases() -> list[dict]:
    """Heat index, PAGASA banding, PSI and the fusion rule."""
    p = UserProfile(user_id="G", age_years=30, height_cm=170,
                    weight_kg=70, resting_hr_bpm=60)
    p_old = UserProfile("G2", 72, 170, 70, 60)
    p_cvd = UserProfile("G3", 30, 170, 70, 60, cardiovascular_condition=True)
    p_obese = UserProfile("G4", 30, 170, 95, 60)

    cases = []
    for t, rh in [(25, 40), (30, 60), (32, 70), (35, 80), (38, 75), (41, 85)]:
        hi = rothfusz_heat_index_c(t, rh)
        cases.append({
            "kind": "heat_index",
            "temp_c": t, "rh_pct": rh,
            "heat_index_c": round(hi, 6),
            "pagasa_class": pagasa_risk_class(hi),
        })
    for hr in [60, 80, 100, 130, 160, 187]:
        psi = psi_heart_rate(hr, p)
        cases.append({
            "kind": "psi",
            "hr_bpm": hr, "resting_hr": p.resting_hr_bpm,
            "age_years": p.age_years,
            "hr_max": round(p.hr_max, 6),
            "psi": round(psi, 6), "psi_class": psi_risk_class(psi),
        })
    for name, prof in [("healthy", p), ("elderly", p_old),
                       ("cardiovascular", p_cvd), ("obese", p_obese)]:
        for env in range(5):
            for psic in range(5):
                for desat in (False, True):
                    cases.append({
                        "kind": "fusion",
                        "profile": name,
                        "age_years": prof.age_years,
                        "bmi": round(prof.bmi, 6),
                        "cardiovascular": prof.cardiovascular_condition,
                        "env_class": env, "psi_class": psic,
                        "spo2_desat": desat,
                        "risk_class": fuse_risk(env, psic, prof, desat),
                    })
    return cases


def window_case() -> dict:
    """A short deterministic series with its windowed features."""
    n = 90
    ts = pd.date_range("2026-04-20T11:00:00", periods=n, freq="1min")
    df = pd.DataFrame({
        "timestamp": ts,
        "ambient_temp_c": [30.0 + 0.05 * i for i in range(n)],
        "relative_humidity_pct": [70.0 + (i % 7) - 3 for i in range(n)],
        "heart_rate_bpm": [80.0 + 0.2 * i for i in range(n)],
        "spo2_pct": [98.0 - 0.01 * i for i in range(n)],
    })
    feat = add_windowed_features(
        df, ["ambient_temp_c", "relative_humidity_pct",
             "heart_rate_bpm", "spo2_pct"])
    last = feat.iloc[-1]
    wanted = {k: (None if (isinstance(v, float) and math.isnan(v))
                  else round(float(v), 6))
              for k, v in last.items()
              if k.startswith(("mean.", "sd.", "grad."))}
    return {
        "samples": [
            {"t_offset_min": i,
             "ambient_temp_c": float(df.ambient_temp_c[i]),
             "relative_humidity_pct": float(df.relative_humidity_pct[i]),
             "heart_rate_bpm": float(df.heart_rate_bpm[i]),
             "spo2_pct": float(df.spo2_pct[i])}
            for i in range(n)
        ],
        "expected_features": wanted,
    }


def main() -> int:
    payload = {
        "generated_by": "mlops/verify_dart_parity.py",
        "contract": "labeling.py <-> risk_rules.dart + feature_window.dart",
        "scalars": scalar_cases(),
        "window": window_case(),
    }
    OUT.write_text(json.dumps(payload, indent=1))
    n_scalar = len(payload["scalars"])
    n_feat = len(payload["window"]["expected_features"])
    print(f"wrote {OUT.name}: {n_scalar} scalar cases, "
          f"{n_feat} windowed features from a 90-minute series")
    print("Dart side: app/test/parity_test.dart must load this and match.")
    print("\nSpot checks:")
    for c in payload["scalars"][:3]:
        print(f"  HI({c['temp_c']}C,{c['rh_pct']}%) = "
              f"{c['heat_index_c']:.3f}C -> band {c['pagasa_class']}")
    g = payload["window"]["expected_features"]
    for k in ["mean.heart_rate_bpm_5", "grad.heart_rate_bpm_60",
              "sd.ambient_temp_c_15"]:
        if k in g:
            print(f"  {k} = {g[k]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
