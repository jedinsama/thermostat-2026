# THERMOSTAT

**Personalized heat-stroke risk forecasting from wearable telemetry.**

A capstone research system for the BS Information Technology program, Western
Mindanao State University. THERMOSTAT pairs a custom ESP32-C3 wearable with a
Flutter application to forecast an individual's heat-stress risk twenty minutes
ahead, using that person's own physiology rather than a population average.

Existing heat warnings are regional and generic. PAGASA publishes a heat index
for a city; the Rothfusz regression behind it assumes a standardised human of
5'7" and 147 lb. A 62-year-old with a cardiovascular history and a 20-year-old
athlete standing on the same street receive the same warning. THERMOSTAT
narrows that to the individual and the square metre they occupy.

---

## Status

**Pre-clearance. No model has been trained on human-subject data, and none
will be until the Research Ethics Oversight Committee approves the protocol.**

| Component | State |
|---|---|
| Firmware — ESP32-C3, BLE wire protocol | Implemented, self-testing |
| Flutter app — BLE, risk engine, SOS, collector mode | Implemented |
| MLOps — labeling, training, evaluation, export | Implemented, self-testing |
| Python ↔ Dart parity contract | Implemented, 248 golden vectors |
| Trained model | **None.** Blocked on ethics clearance |
| Thermal coupling constant *k* | **Unmeasured.** Ships as 0.0 |

The pipeline runs end to end on public data. That demonstrates the machinery,
not a result — see *Honest limitations* below.

---

## How it works

**Hardware.** An ESP32-C3 SuperMini reads a BME280 (ambient temperature,
humidity, pressure), a MAX30102 (heart rate, SpO₂) and a MAX30205 (skin
temperature), packs them into a 41-byte binary frame with a CRC-16/CCITT-FALSE
checksum, and transmits over Bluetooth Low Energy.

**Risk labels are derived, not observed.** Nobody is diagnosed with heat stress
during collection, so there is no observed ground truth to learn from. The label
fuses two published instruments:

- a **PAGASA heat-index band** from the Rothfusz regression over ambient
  temperature and relative humidity, and
- a **heart-rate Physiological Strain Index** (Moran et al., 1998), normalised
  by that person's heart-rate reserve.

Personalisation lives in the PSI denominator, via the Tanaka formula
`HRmax = 208 − 0.7 × age`. The same 130 bpm means something different for a
20-year-old and a 55-year-old, and this is where that difference enters.

**The model forecasts; it does not describe.** Features over rolling 5-, 15- and
60-minute windows at time *t* are trained against the derived risk class at
*t + 20 minutes*. A model that reproduced the current rule output would be a
lookup table. The twenty-minute margin is the warning time the system exists to
provide.

**Inference runs on the phone.** A fitted scikit-learn forest is exported to
JSON and traversed in pure Dart — no TFLite, no ONNX. Before writing the asset,
the exporter re-implements that traversal in Python and asserts it matches
sklearn's `predict_proba`; a mismatch aborts the export, so a broken asset
cannot ship.

**Personal calibration may raise a risk band, never lower one.** Survey
responses shift the user's thresholds asymmetrically — up to +8 °C protective,
−3 °C permissive — but a hard floor prevents calibration from talking the system
out of a rule-level Danger warning.

---

## Repository layout

```
firmware/thermostat_node/    ESP32-C3 sketch, 41-byte frame, CRC self-test
app/lib/core/                protocol, BLE, risk rules, calibration,
                             feature windows, forest inference, SOS
app/lib/ui/                  dashboard, profile, survey, collector mode
app/test/                    Dart side of the parity contract
mlops/                       labeling, ingestion, training, export, audit
data/README.md               dataset DOIs and reproduction steps
```

---

## Quick start

```bash
cd mlops
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

python labeling.py --self-test     # must print ALL SELF-TESTS PASSED
python audit_datasets.py           # what each dataset in data/raw/ can do
```

Full pipeline, dataset by dataset, in [`mlops/RUNBOOK.md`](mlops/RUNBOOK.md).
Dataset sources and DOIs in [`data/README.md`](data/README.md).

---

## The two halves must not drift

The same arithmetic exists twice: in `mlops/labeling.py` and in the Dart port
under `app/lib/core/`. If they diverge, the app feeds the model features unlike
those it trained on, silently and with no error. `verify_dart_parity.py`
generates 212 scalar cases and 36 windowed features as golden vectors, and
`app/test/parity_test.dart` asserts the Dart side matches.

Run it after **any** change to a threshold, window, or escalation rule:

```bash
cd mlops && python verify_dart_parity.py && cp golden_vectors.json ../app/test/
cd ../app && flutter test test/parity_test.dart
```

---

## Honest limitations

**No public dataset can train this model.** The risk label needs ambient
temperature, humidity and heart rate measured at the same time on the same
person. `audit_datasets.py` was written to establish this rather than assert it,
and reports across four corpora:

| Dataset | Environment | Physiology | Verdict |
|---|---|---|---|
| Tartarini / Liu | yes | yes | Labels, but pre-windowed at irregular vote times — cannot forecast |
| PPG-DaLiA | no | ECG-derived | No ambient measurement at all |
| ASHRAE Global DB II | yes | no | No physiology |
| WESAD | no | raw ECG only | No ambient, no derived heart rate |

This is the justification for primary data collection.

**Path B results are not results.** `run_pathb.py` overlays a real weather trace
on PPG-DaLiA physiology to prove the pipeline runs end to end. The two were
never co-recorded, it pairs a German office worker's day with Philippine
weather, and `fetch_weather.py` selects the hottest day in its window by
default. Every row lands in Extreme Caution or Danger; the environment decides
the label and the heart rate is decoration. Outputs are quarantined under
`data/clean/pathb/` and stamped in a `provenance` column. **Say the pipeline
runs; never quote its numbers as performance.**

**Accuracy is not reported anywhere in this project.** The majority-class
baseline scores above 0.90 on our own data. Any metric a trivial baseline can
beat is not evidence. We report per-class recall and PR-AUC, and
`compare_baselines.py` prints the embarrassing majority-class number on purpose.

**A negative verdict is a finding.** `train_model.py` prints explicit
`justified` / `NOT JUSTIFIED` and `adds value` / `NOT beating persistence`
lines. Whichever it prints is what gets reported.

**The thermal coupling constant is unmeasured.** `T_ambient = T_BME − k·(T_SKIN
− T_BME)` compensates for body heat conducted into the ambient sensor. Until a
bench session measures *k*, it ships as 0.0 and is declared in the limitations.

---

## What is deliberately not in this repository

**Participant telemetry. Ever.** The ethics protocol names exactly three
locations where research data may reside, and a public repository is not one of
them. `data/raw/`, `data/clean/`, `sessions/` and any file matching
`P-NN_*.csv` are git-ignored. Removing a file from git history is far harder
than never committing it, and deleting it from a remote does not remove it from
the clones others already hold.

**Raw public datasets.** They are large — PPG-DaLiA alone is 2.7 GB
compressed — and separately licensed. `data/README.md` carries the DOIs and
download steps, and the ingestion scripts carry the column mappings, so the
pipeline is fully reproducible without shipping the ingredients.

**Manuscript and ethics working documents.** They contain draft material and
third-party correspondence.

---

## Team

| | |
|---|---|
| **Anas Mohammad E. Demonteverde** | Project management, documentation, ethics protocol |
| **Jaden L. Mosot** | Mobile application |
| **Sophia E. Tolosa** | Machine learning and research |
| **Ria Jeanel Dagalea** | Hardware and firmware |

Adviser: Engr. Elvin Rey S.G. Saavedra
Course instructor: Jason A. Catadman
College of Computing Studies, Western Mindanao State University

---

## References

- Moran, Shitzer & Pandolf (1998). A physiological strain index to evaluate heat
  stress. *Am. J. Physiol.* 275(1), R129–R134.
- Tanaka, Monahan & Seals (2001). Age-predicted maximal heart rate revisited.
  *J. Am. Coll. Cardiol.* 37(1), 153–156.
- Rothfusz (1990). *The heat index equation.* NWS Technical Attachment SR 90-23.
- Tartarini, Schiavon, Quintana & Miller (2022). *Indoor Air* 32(11), e13160.
  DOI [10.1111/ina.13160](https://doi.org/10.1111/ina.13160)
- Reiss, Indlekofer, Schmidt & Van Laerhoven (2019). Deep PPG. *Sensors* 19(14),
  3079. DOI [10.3390/s19143079](https://doi.org/10.3390/s19143079)
