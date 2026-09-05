# THERMOSTAT — Datasets

**Raw dataset files are deliberately NOT committed to this repository.**
They are large (PPG-DaLiA is 2.7 GB) and separately licensed. This file gives
the DOI and the exact steps for each, so anyone can reproduce our pipeline
from scratch.

**Participant telemetry from our own study is NEVER committed here.** Our
ethics protocol names exactly three places research data may live, and a
public repository is not one of them. `data/raw/` and `data/clean/` are
git-ignored for that reason.

---

## What each dataset can and cannot do

`labeling.py` needs four columns: `timestamp`, `ambient_temp_c`,
`relative_humidity_pct`, `heart_rate_bpm` (`spo2_pct` optional). Most public
datasets have only half of that.

| Dataset | Has | Drives the risk label? |
|---|---|---|
| **Tartarini / Liu** | heart rate, skin temp, **air temp, relative humidity** | **YES — full pipeline** |
| PPG-DaLiA | BVP/PPG, ECG-derived HR, accelerometer, body temp | No — no ambient conditions |
| WESAD | BVP, EDA, body temp, accelerometer | No — no ambient conditions |
| ASHRAE Global DB II | air temp, humidity, comfort votes | No — no physiology |

A physiology-only dataset has no ambient temperature, so no heat index, so no
environmental band. `labeling.py` will refuse it. **That refusal is correct.**

---

## 1. Tartarini et al. — the one that works end to end

**Start here.** It is the only public dataset we found carrying physiology and
environment together, and it is small.

- **DOI:** `10.15146/R3S68S` — https://datadryad.org/dataset/doi:10.15146/R3S68S
- **Paper:** Tartarini, Schiavon, Quintana & Miller (2022), *Indoor Air* 32(11)
  e13160, `10.1111/ina.13160` — reference [21] in our manuscript
- **Files:** `raw_data_Liu.csv` (2.67 MB) and
  `Description of variables_Liu.docx` (16.7 KB) — **download both**, you need
  the variable description to build the column mapping
- **Contents:** 14 subjects, 2–4 weeks each; skin temperature, heart rate, air
  temperature, relative humidity

```bash
# save raw_data_Liu.csv into data/raw/, then:
cd mlops
python ingest_public.py ../data/raw/raw_data_Liu.csv --inspect
```

Read the printed columns against the .docx, then map. The exact column names
are not reproduced here because we should read them from the file rather than
guess:

```bash
python ingest_public.py ../data/raw/raw_data_Liu.csv \
    --out ../data/clean/tartarini_S01.csv \
    --map <fill in from --inspect>
```

If the file holds all 14 subjects in one table, split by its subject column
first — `labeling.py` takes one person at a time, because the profile
(age, BMI, resting HR) is per-person.

> This is also the dataset behind our 76% heart-rate completeness figure in
> the Sample Size Justification. Re-derive that number from this file and keep
> the output — it is our own measurement, not a published claim.

## 2. PPG-DaLiA — physiology only, 2.7 GB

- **UCI ID 495:** https://archive.ics.uci.edu/dataset/495/ppg+dalia
- **Paper:** Reiss, Indlekofer, Schmidt & Van Laerhoven (2019), *Sensors*
  19(14) 3079, `10.3390/s19143079` — reference [24]
- **License:** CC BY 4.0
- **Files:** `data.zip` (2.7 GB), `readme.pdf`
- **Contents:** 15 subjects; wrist BVP 64 Hz, EDA 4 Hz, body temp 4 Hz, ACC
  32 Hz; chest ECG 700 Hz with derived ground-truth heart rate
- **Format:** Python pickles, one per subject (`S1.pkl` … `S15.pkl`)

Use it to validate the PPG → heart-rate path, or pair it with an environment
series (see §4). It cannot drive the risk label alone.

## 3. WESAD — physiology only

- **Paper:** Schmidt, Reiss, Duerichen, Marberger & Van Laerhoven (2018),
  ICMI, `10.1145/3242969.3242985` — reference [23]
- Same shape as PPG-DaLiA: chest + wrist physiology, no ambient conditions.

## 4. ASHRAE Global Thermal Comfort Database II — environment only

- **DOI:** `10.6078/D1F671` — https://datadryad.org/dataset/doi:10.6078/D1F671
- **Paper:** Földváry Ličina et al. (2018), *Building and Environment* 142,
  502–512 — reference [25]
- 100k+ field records of indoor environmental conditions. Useful as a source
  of realistic environmental distributions to pair with physiology-only data.

---

## Pairing physiology with environment — and the honesty rule

```bash
python ingest_public.py ../data/raw/dalia_S3.csv \
    --out ../data/clean/dalia_S3.csv \
    --map time=timestamp,HR=heart_rate_bpm \
    --environment ../data/raw/ashrae_tropical.csv \
    --environment-map ts=timestamp,ta=ambient_temp_c,rh=relative_humidity_pct
```

The script prints a warning and stamps every row
`provenance = "dalia_S3+ashrae_tropical(SYNTHETIC PAIRING)"`.

**These are not the same people at the same time.** Paired data proves the
pipeline runs end to end. It is not evidence about real humans in real heat.
Chapter IV must state which rows came from where; the `provenance` column
exists so that nobody loses track mid-analysis.

---

## Before citing any dataset as usable

Run it through the pipeline and read the output. The acceptance test is the
one from our original feasibility study:

- Does it contain rows above the PAGASA **Danger** band?
- Does it contain concurrent physiology?

If `labeling.py` prints a **label saturation warning**, or the forecast target
shows **Danger+ under 5%**, the dataset cannot train a useful classifier. Find
that out here, not in Chapter IV.
