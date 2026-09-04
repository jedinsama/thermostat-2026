#!/usr/bin/env python3
"""
THERMOSTAT — naive baselines the model must beat.

Three baselines, all computed on the same labeled frames as train_model.py:
  persistence  : future band = current band (hard to beat on stable data)
  majority     : always predict the most common band (what accuracy rewards)
  env-rule     : future band = current PAGASA band alone (the generic
                 heat-index system THERMOSTAT critiques)

If the trained model does not clear persistence on PR-AUC, the honest report
is that on THIS data the forecasting task is dominated by autocorrelation —
a finding about the data, stated in Chapter 4, not hidden.

Usage:  py compare_baselines.py sessions/*_labeled.csv
"""
from __future__ import annotations

import argparse
import glob
import sys

import numpy as np
import pandas as pd
from sklearn.metrics import recall_score

TARGET = "risk_class_future"


def report(name: str, y_true: np.ndarray, y_pred: np.ndarray) -> None:
    labels = np.unique(y_true)
    rec = recall_score(y_true, y_pred, average=None, labels=labels,
                       zero_division=0)
    acc = float((y_true == y_pred).mean())
    danger_recall = {int(c): float(r) for c, r in zip(labels, rec) if c >= 3}
    print(f"{name:<12} acc={acc:.3f}  per-class recall="
          f"{ {int(c): round(float(r),3) for c, r in zip(labels, rec)} }")
    if danger_recall:
        print(f"{'':<12} Danger+ recall: {danger_recall}  <- the number that matters")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+")
    args = ap.parse_args()
    paths = sorted(p for g in args.csvs for p in glob.glob(g))
    if not paths:
        print("no input files matched")
        return 1
    df = pd.concat([pd.read_csv(p) for p in paths], ignore_index=True)
    df = df.dropna(subset=[TARGET])
    y = df[TARGET].astype(int).values

    report("persistence", y, df["risk_class"].astype(int).values)
    report("majority", y, np.full_like(y, np.bincount(y).argmax()))
    report("env-rule", y, df["pagasa_class"].astype(int).values)
    print("\nNote how high the majority baseline's accuracy is — this is why "
          "accuracy is not a headline metric anywhere in this project.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
