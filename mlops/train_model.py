#!/usr/bin/env python3
"""
THERMOSTAT — offline model training and honest evaluation.

Loads one or more labeled session CSVs (output of labeling.py), trains a
Random Forest to forecast risk_class_future, and evaluates under
LEAVE-ONE-SUBJECT-OUT cross-validation with the metrics that survive class
imbalance: per-class recall and macro PR-AUC. Accuracy is printed but
explicitly de-emphasised.

Also runs, automatically:
  · a PERSISTENCE BASELINE (predict current band as the future band) — the
    bar the model must clear to justify existing;
  · a BIOMETRIC ABLATION (environment-only features) — if biometrics add
    nothing, that is a finding to report, not to bury.

Usage:
    py train_model.py sessions/*_labeled.csv
    py train_model.py sessions/*_labeled.csv --out results/
"""
from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import (average_precision_score, confusion_matrix,
                             recall_score)

SEED = 20260821  # fixed project seed — never change between runs
TARGET = "risk_class_future"

# Columns that must NEVER be features (leakage: they encode the label or the
# rule's intermediates at time t in ways that trivialise the forecast).
LEAK = {
    TARGET, "risk_class", "risk_name", "baseline_class", "pagasa_class",
    "iso7243_class", "env_class", "psi_class", "personalization_delta",
    "horizon_min", "user_id", "timestamp", "sensor_fault", "spo2_desat",
}
BIOMETRIC_MARKERS = ("heart_rate", "spo2", "psi", "skin_temp",
                     "age_years", "bmi", "cardiovascular_flag")


def feature_columns(df: pd.DataFrame, biometrics: bool = True) -> list[str]:
    cols = [c for c in df.columns
            if c not in LEAK and pd.api.types.is_numeric_dtype(df[c])]
    if not biometrics:
        cols = [c for c in cols
                if not any(m in c for m in BIOMETRIC_MARKERS)]
    return sorted(cols)


def macro_pr_auc(y_true: np.ndarray, proba: np.ndarray,
                 classes: np.ndarray) -> float:
    """One-vs-rest average precision, macro-averaged over classes present."""
    scores = []
    for i, cls in enumerate(classes):
        mask = (y_true == cls).astype(int)
        if mask.sum() == 0 or mask.sum() == len(mask):
            continue  # class absent from this fold's truth — skip, don't fake
        scores.append(average_precision_score(mask, proba[:, i]))
    return float(np.mean(scores)) if scores else float("nan")


def evaluate_loso(df: pd.DataFrame, cols: list[str], label: str) -> dict:
    """Leave-one-subject-out: hold each user out, train on the rest."""
    users = sorted(df["user_id"].unique())
    if len(users) < 2:
        print(f"  !! only {len(users)} subject(s) — LOSO needs >= 2; "
              f"reporting apparent (optimistic) fit instead")
    per_fold = []
    all_true, all_pred = [], []

    for held_out in users:
        tr = df[df["user_id"] != held_out] if len(users) > 1 else df
        te = df[df["user_id"] == held_out]
        X_tr = tr[cols].fillna(tr[cols].median(numeric_only=True))
        X_te = te[cols].fillna(tr[cols].median(numeric_only=True))  # train stats
        y_tr, y_te = tr[TARGET].values, te[TARGET].values

        clf = RandomForestClassifier(
            n_estimators=400, class_weight="balanced",
            min_samples_leaf=3, random_state=SEED, n_jobs=-1)
        clf.fit(X_tr, y_tr)
        proba = clf.predict_proba(X_te)
        pred = clf.classes_[np.argmax(proba, axis=1)]

        fold = {
            "held_out": held_out,
            "n_test": int(len(te)),
            "pr_auc_macro": macro_pr_auc(y_te, proba, clf.classes_),
            "recall_per_class": {
                int(c): float(r) for c, r in zip(
                    np.unique(y_te),
                    recall_score(y_te, pred, average=None,
                                 labels=np.unique(y_te), zero_division=0))
            },
            "accuracy_do_not_headline": float((pred == y_te).mean()),
        }
        per_fold.append(fold)
        all_true.extend(y_te)
        all_pred.extend(pred)
        print(f"  [{label}] fold {held_out}: n={fold['n_test']:>5} "
              f"PR-AUC={fold['pr_auc_macro']:.3f} "
              f"recall={fold['recall_per_class']}")

    cm = confusion_matrix(all_true, all_pred).tolist()
    summary = {
        "label": label,
        "n_subjects": len(users),
        "pr_auc_macro_mean": float(np.nanmean(
            [f["pr_auc_macro"] for f in per_fold])),
        "per_fold": per_fold,
        "pooled_confusion_matrix": cm,
    }
    print(f"  [{label}] mean macro PR-AUC over folds: "
          f"{summary['pr_auc_macro_mean']:.3f}")
    return summary


def persistence_baseline(df: pd.DataFrame) -> dict:
    """Predict future band = current band. The bar to clear."""
    y_true = df[TARGET].values
    y_pred = df["risk_class"].values
    classes = np.unique(np.concatenate([y_true, y_pred]))
    # Degenerate 'probabilities': 1 on the predicted class.
    proba = np.zeros((len(y_pred), len(classes)))
    for i, cls in enumerate(classes):
        proba[y_pred == cls, i] = 1.0
    rec = recall_score(y_true, y_pred, average=None,
                       labels=np.unique(y_true), zero_division=0)
    out = {
        "label": "persistence",
        "pr_auc_macro": macro_pr_auc(y_true, proba, classes),
        "recall_per_class": {int(c): float(r)
                             for c, r in zip(np.unique(y_true), rec)},
        "accuracy_do_not_headline": float((y_pred == y_true).mean()),
    }
    print(f"  [persistence] PR-AUC={out['pr_auc_macro']:.3f} "
          f"recall={out['recall_per_class']}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+", help="labeled session CSVs (globs ok)")
    ap.add_argument("--out", default="results")
    args = ap.parse_args()

    paths = sorted(p for g in args.csvs for p in glob.glob(g))
    if not paths:
        print("no input files matched")
        return 1
    df = pd.concat([pd.read_csv(p) for p in paths], ignore_index=True)
    df = df.dropna(subset=[TARGET])
    df[TARGET] = df[TARGET].astype(int)
    print(f"loaded {len(df):,} rows from {len(paths)} file(s), "
          f"{df['user_id'].nunique()} subject(s)")
    print("target distribution:")
    print(df[TARGET].value_counts(normalize=True).sort_index()
          .round(4).to_string())

    full_cols = feature_columns(df, biometrics=True)
    env_cols = feature_columns(df, biometrics=False)
    print(f"\nfeatures: {len(full_cols)} full / {len(env_cols)} environment-only")

    print("\n== FULL MODEL (environment + biometrics + profile) ==")
    full = evaluate_loso(df, full_cols, "full")

    print("\n== ABLATION (environment only) ==")
    ablation = evaluate_loso(df, env_cols, "env-only")

    print("\n== PERSISTENCE BASELINE ==")
    persist = persistence_baseline(df)

    # ---- the honest verdicts, computed not asserted ----------------------
    delta_bio = full["pr_auc_macro_mean"] - ablation["pr_auc_macro_mean"]
    delta_persist = full["pr_auc_macro_mean"] - persist["pr_auc_macro"]
    print("\n== VERDICTS ==")
    print(f"biometrics contribution: {delta_bio:+.3f} PR-AUC "
          f"({'justified' if delta_bio > 0.01 else 'NOT JUSTIFIED on this data — report it'})")
    print(f"vs persistence:          {delta_persist:+.3f} PR-AUC "
          f"({'model adds value' if delta_persist > 0.01 else 'NOT beating persistence — report it'})")

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "training_report.json").write_text(json.dumps({
        "seed": SEED, "inputs": paths,
        "full": full, "ablation_env_only": ablation,
        "persistence": persist,
        "verdict": {"biometrics_delta_pr_auc": delta_bio,
                    "persistence_delta_pr_auc": delta_persist},
    }, indent=2))
    print(f"\nwrote {out_dir / 'training_report.json'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
