# MLOps Runbook — copy-paste, top to bottom

Every command assumes you are in `mlops/`. Full explanations live in
`../README.md` §5; this file is the short version for when you just need it to
run.

```bash
cd mlops
pip install pandas numpy scikit-learn
```

---

## 0. Always first — is the foundation intact?

```bash
python labeling.py --self-test
```

Must end `ALL SELF-TESTS PASSED`. If it does not, stop — something in your
environment or a local edit broke the labeling engine, and everything
downstream inherits the error.

---

## 1. Get a dataset

See `../data/README.md` for DOIs and what each one can do.
**Start with Tartarini** — it is the only public dataset with physiology *and*
environment, and it is 2.7 MB.

Download `raw_data_Liu.csv` from https://datadryad.org/dataset/doi:10.15146/R3S68S
into `../data/raw/`.

---

## 2. Look at it before mapping it

```bash
python ingest_public.py ../data/raw/raw_data_Liu.csv --inspect
```

Prints every column, its type, a sample value, and a *guessed* `--map`.
Check the guess against the dataset's own variable description. Never trust it
blind.

---

## 3. Map it into our schema

```bash
python ingest_public.py ../data/raw/raw_data_Liu.csv \
    --out ../data/clean/tartarini_S01.csv \
    --map <from step 2>
```

Resamples to 1-minute medians, stamps `provenance`, and prints a completeness
report. If it says a required column is MISSING, it is telling you the truth —
either map it from another column or pair an environment file
(`--environment`). Do not invent values.

**One subject per file.** The profile (age, BMI, resting HR) is per-person, so
if the raw file holds several subjects, split it first.

---

## 4. Label it

```bash
python labeling.py ../data/clean/tartarini_S01.csv \
    --user-id P-01 --age 30 --height 170 --weight 70 --rest-hr 60
# add --cvd for cardiovascular history
# writes ../data/clean/tartarini_S01_labeled.csv
```

Age/height/weight/resting-HR come from that subject's profiling form (or the
dataset's own demographics). **Read the console output** — the class
distribution tells you immediately whether the file is usable:

- a **label saturation warning** means one class dominates → not trainable
- **Danger+ under 5%** means the interesting class is nearly absent

Repeat for every subject. You need at least 2 for leave-one-subject-out, and
realistically 4+ for the numbers to mean anything.

---

## 5. Train and evaluate

```bash
python train_model.py ../data/clean/*_labeled.csv --out ../results/
```

Runs automatically, in this order:

1. **Full model** — Random Forest under leave-one-subject-out CV
2. **Ablation** — same, environment features only (measures what the
   biometrics actually contribute)
3. **Persistence baseline** — "future band = current band", the bar to clear
4. **Verdict lines** — explicit `justified` / `NOT JUSTIFIED` and
   `adds value` / `NOT beating persistence`

Writes `../results/training_report.json` — per-fold metrics, pooled confusion
matrix, verdicts. Those numbers drop straight into dummy Tables A4 and A5.

**A negative verdict is a finding, not a failure.** Report it.

---

## 6. Baseline sanity numbers for the write-up

```bash
python compare_baselines.py ../data/clean/*_labeled.csv
```

Persistence, majority-class, and generic-heat-index baselines with per-class
recall — including the deliberately embarrassing majority-class accuracy,
which is the one-line justification for why accuracy is never a headline
metric in this project.

---

## 7. Ship the model to the phone

```bash
python export_model_dart.py ../data/clean/*_labeled.csv \
    --out ../app/assets/model.json --trees 60 --depth 8
```

Dumps the fitted forest to a JSON asset the Flutter app traverses in pure
Dart. Before writing the file it re-implements that traversal in Python and
asserts it matches sklearn's `predict_proba`; a mismatch aborts the export, so
a broken asset cannot ship.

Target size 150–400 KB. If it exceeds 2 MB, lower `--trees` or `--depth`.

---

## 8. Keep Dart and Python honest

Run after **any** change to a threshold, window, or escalation rule:

```bash
python verify_dart_parity.py
cp golden_vectors.json ../app/test/
cd ../app && flutter test test/parity_test.dart
```

212 scalar cases plus 36 windowed features. The same maths exists twice — in
`labeling.py` and in the Dart port — and if they drift, the app is fed
features unlike those the model trained on, silently.

---

## The whole thing, once you know the mapping

```bash
cd mlops
python labeling.py --self-test
python ingest_public.py ../data/raw/raw_data_Liu.csv --out ../data/clean/S01.csv --map <...>
python labeling.py ../data/clean/S01.csv --user-id P-01 --age 30 --height 170 --weight 70 --rest-hr 60
python train_model.py ../data/clean/*_labeled.csv --out ../results/
python compare_baselines.py ../data/clean/*_labeled.csv
python export_model_dart.py ../data/clean/*_labeled.csv --out ../app/assets/model.json
```
