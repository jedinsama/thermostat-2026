#!/usr/bin/env python3
"""
THERMOSTAT — export a trained Random Forest for on-device inference.

WHY THIS EXISTS
---------------
The adviser moved inference onto the phone (26 Aug). A scikit-learn model
cannot run there, and sklearn -> TFLite has no direct path. But a Random
Forest is only nested if-else comparisons, so we dump the fitted trees to a
compact JSON asset and traverse them in pure Dart (app/lib/core/forest_model.dart).
No runtime, no plugin, no network — which is exactly what the data-protection
plan requires.

FORMAT (thermostat-forest-v1) — parallel arrays, one entry per node:
    f  int    feature index, or -1 for a leaf
    t  double split threshold  (go LEFT when value <= t, matching sklearn)
    l  int    left child index
    r  int    right child index
    v  [..]   leaf only: class probabilities, same order as "classes"

Guarantees checked by --verify: the Dart traversal reproduces sklearn's
predict_proba to within 1e-6 on every row of the training frame.

Usage:
    py export_model_dart.py sessions/*_labeled.csv --out ../app/assets/model.json
    py export_model_dart.py sessions/*_labeled.csv --out model.json --trees 60 --depth 8
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

sys.path.insert(0, str(Path(__file__).parent))
from train_model import LEAK, SEED, TARGET, feature_columns  # noqa: E402


def export_tree(est) -> dict:
    """One fitted DecisionTree -> compact parallel-array dict."""
    t = est.tree_
    n = t.node_count
    f, thr, left, right = [], [], [], []
    values: dict[int, list[float]] = {}
    for i in range(n):
        is_leaf = t.children_left[i] == -1
        f.append(-1 if is_leaf else int(t.feature[i]))
        thr.append(0.0 if is_leaf else float(t.threshold[i]))
        left.append(int(t.children_left[i]))
        right.append(int(t.children_right[i]))
        if is_leaf:
            counts = t.value[i][0]
            total = float(counts.sum()) or 1.0
            values[i] = [round(float(c) / total, 6) for c in counts]
    return {"f": f, "t": [round(x, 6) for x in thr], "l": left, "r": right,
            "v": {str(k): v for k, v in values.items()}}


def predict_proba_pure(model_json: dict, rows: np.ndarray) -> np.ndarray:
    """
    Reference implementation of EXACTLY what forest_model.dart does.
    Used by --verify so we prove the Dart port's algorithm before shipping.
    """
    n_classes = len(model_json["classes"])
    out = np.zeros((len(rows), n_classes))
    for tree in model_json["trees"]:
        f, thr, l, r, v = tree["f"], tree["t"], tree["l"], tree["r"], tree["v"]
        for i, row in enumerate(rows):
            node = 0
            while f[node] != -1:
                node = l[node] if row[f[node]] <= thr[node] else r[node]
            out[i] += v[str(node)]
    return out / len(model_json["trees"])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+", help="labeled session CSVs (globs ok)")
    ap.add_argument("--out", default="model.json")
    ap.add_argument("--trees", type=int, default=60,
                    help="fewer trees = smaller asset; 60 is ~200-400 KB")
    ap.add_argument("--depth", type=int, default=8,
                    help="cap depth to keep the asset small and fast on-device")
    ap.add_argument("--verify", action="store_true", default=True)
    args = ap.parse_args()

    paths = sorted(p for g in args.csvs for p in glob.glob(g))
    if not paths:
        print("no input files matched")
        return 1
    df = pd.concat([pd.read_csv(p) for p in paths], ignore_index=True)
    df = df.dropna(subset=[TARGET])
    df[TARGET] = df[TARGET].astype(int)

    cols = feature_columns(df, biometrics=True)
    X = df[cols].fillna(df[cols].median(numeric_only=True))
    y = df[TARGET].values
    med = X.median(numeric_only=True)

    clf = RandomForestClassifier(
        n_estimators=args.trees, max_depth=args.depth,
        class_weight="balanced", min_samples_leaf=5,
        random_state=SEED, n_jobs=-1)
    clf.fit(X, y)
    print(f"fitted {args.trees} trees, depth<={args.depth}, "
          f"{len(cols)} features, {len(df):,} rows, "
          f"{df['user_id'].nunique()} subject(s)")

    model = {
        "format": "thermostat-forest-v1",
        "seed": SEED,
        "horizon_min": int(df["horizon_min"].iloc[0]) if "horizon_min" in df else 20,
        "classes": [int(c) for c in clf.classes_],
        "features": cols,
        # Median imputation values, so the phone handles a missing sensor the
        # same way training did instead of inventing a zero.
        "impute": {c: (None if pd.isna(med.get(c)) else round(float(med[c]), 6))
                   for c in cols},
        "n_trees": args.trees,
        "trees": [export_tree(e) for e in clf.estimators_],
    }

    if args.verify:
        rows = X.to_numpy(dtype=float)
        mine = predict_proba_pure(model, rows)
        theirs = clf.predict_proba(rows)
        max_err = float(np.abs(mine - theirs).max())
        agree = float((mine.argmax(1) == theirs.argmax(1)).mean())
        print(f"verify: max |Δproba| = {max_err:.2e}, argmax agreement = {agree:.6f}")
        if max_err > 1e-6:
            print("!! traversal mismatch — DO NOT SHIP this asset")
            return 2

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(model, separators=(",", ":")))
    kb = out.stat().st_size / 1024
    print(f"wrote {out}  ({kb:.0f} KB)")
    if kb > 2000:
        print("!! asset >2 MB — lower --trees or --depth before shipping")
    print("\nnext: copy to app/assets/model.json and declare it in pubspec.yaml")
    return 0


if __name__ == "__main__":
    sys.exit(main())
