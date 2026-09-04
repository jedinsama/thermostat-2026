#!/usr/bin/env python3
"""
THERMOSTAT — Risk Labeling Engine
==================================

Turns raw wearable telemetry into personalized heat-stress risk labels, and
builds the *forecasting* target the ML models are actually trained against.

WHAT THIS IS
------------
We cannot observe clinical heatstroke, and we cannot ethically induce it.
So the label is DERIVED from established standards rather than observed:

    environmental half : Rothfusz heat index -> PAGASA danger bands
                         (+ estimated WBGT -> ISO 7243 occupational bands)
    physiological half : heart-rate Physiological Strain Index (Moran et al.)
    personalization    : age, BMI, cardiovascular history, SpO2 desaturation

The ML model does NOT learn to reproduce this rule — reproducing a rule you
already have is worthless. It learns to ANTICIPATE the rule's output
`FORECAST_HORIZON_MIN` minutes ahead from the trajectory of telemetry. That
distinction is the project's actual contribution and must be stated plainly
in Chapter 3. Framing this as diagnosis invites a fatal objection at defense;
framing it as early-warning forecasting is accurate and defensible.

DESIGN DECISIONS (flagged for team review)
------------------------------------------
1. WBGT is ESTIMATED, not measured. True ISO 7243 WBGT needs a globe
   thermometer and wind speed; the BME280 gives neither. We use the
   Australian BoM shade approximation and label it as an approximation
   everywhere it appears. Do not present it as measured WBGT.
2. PSI uses the heart-rate-only variant. Standard PSI needs core temperature.
   HR-PSI is validated in the occupational literature and computable from
   MAX30102 alone.
3. Windowing follows Tartarini et al. (Dryad 10.15146/R3S68S), which uses
   mean/gradient/sd over 5/15/60/480-minute windows. Citing an existing
   published schema is stronger than inventing our own.
4. Labels are ORDINAL (0-4). Misclassifying Safe as Extreme must cost more
   than Safe as Caution. Train with ordinal-aware loss or regression+threshold.

Usage:
    from labeling import UserProfile, label_dataframe, make_forecast_target

    profile = UserProfile(user_id="P01", age_years=34, height_cm=170,
                          weight_kg=68, resting_hr_bpm=62,
                          cardiovascular_condition=False)
    labeled = label_dataframe(df, profile)
    train   = make_forecast_target(labeled, horizon_min=20)

CLI:
    py labeling.py telemetry.csv --age 34 --height 170 --weight 68 --rest-hr 62
    py labeling.py --self-test
"""

from __future__ import annotations

import argparse
import math
import sys
from dataclasses import dataclass, field
from typing import Iterable

import numpy as np
import pandas as pd

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

FORECAST_HORIZON_MIN = 20        # how far ahead the model must predict
FEATURE_WINDOWS_MIN = (5, 15, 60)  # per Tartarini et al.
SPO2_DESAT_THRESHOLD = 94.0      # sustained below this = desaturation
SPO2_DESAT_SUSTAIN_S = 60        # for at least this long
RISK_CLASS_MAX = 4
# Cap on the total personalized vulnerability bump, in bands.
#
# Set to 1: a vulnerable user is rated at most ONE band worse than the
# environment alone would suggest. Higher values saturate the label (at 2, a
# multiply-vulnerable user sat at Extreme Danger for 62% of a realistic
# 14-day window, versus 12% for a healthy user on identical telemetry).
#
# Losing the distinction between one risk factor and three is acceptable here
# because age, BMI and cardiovascular_flag are all model INPUTS. The rule is a
# coarse clinical prior; the trained model is free to learn finer gradations
# than the rule can express. Treat this as a tunable hyperparameter and report
# sensitivity to it in Chapter 4.
MAX_ESCALATION = 1

RISK_NAMES = {
    0: "Safe",
    1: "Caution",
    2: "Extreme Caution",
    3: "Danger",
    4: "Extreme Danger",
}

# Physically plausible sensor ranges. Anything outside is a sensor fault, not
# a measurement, and must be excluded rather than silently labeled. This is
# the same lesson the dataset profiler taught us: never let a pipeline
# substitute a plausible-looking wrong answer for a failure.
SENSOR_RANGES = {
    "ambient_temp_c": (-10.0, 60.0),
    "relative_humidity_pct": (0.0, 100.0),
    "heart_rate_bpm": (25.0, 230.0),
    "spo2_pct": (50.0, 100.0),
}


# --------------------------------------------------------------------------
# User profile (Specific Objective 1)
# --------------------------------------------------------------------------

@dataclass
class UserProfile:
    """
    Static per-user profile. This is what makes the score personalized rather
    than population-average, and it is precisely what the Rothfusz equation
    throws away by assuming a 5'7", 147 lb reference human.
    """

    user_id: str
    age_years: float
    height_cm: float
    weight_kg: float
    resting_hr_bpm: float
    cardiovascular_condition: bool = False
    acclimatized: bool = True
    # ISO 7243 metabolic class: 0 rest, 1 low, 2 moderate, 3 high, 4 very high
    metabolic_class: int = 2

    def __post_init__(self) -> None:
        if not (0 < self.age_years < 120):
            raise ValueError(f"implausible age: {self.age_years}")
        if not (50 < self.height_cm < 250):
            raise ValueError(f"implausible height_cm: {self.height_cm}")
        if not (10 < self.weight_kg < 400):
            raise ValueError(f"implausible weight_kg: {self.weight_kg}")
        if not (25 < self.resting_hr_bpm < 130):
            raise ValueError(f"implausible resting_hr_bpm: {self.resting_hr_bpm}")
        if self.metabolic_class not in range(5):
            raise ValueError(f"metabolic_class must be 0-4: {self.metabolic_class}")

    @property
    def bmi(self) -> float:
        return self.weight_kg / ((self.height_cm / 100.0) ** 2)

    @property
    def hr_max(self) -> float:
        """
        Tanaka et al. (2001): 208 - 0.7*age. More accurate across age than the
        classic 220-age, which systematically underestimates in older adults —
        material for us, since the elderly are a named target demographic.
        """
        return 208.0 - 0.7 * self.age_years

    @property
    def hr_reserve(self) -> float:
        reserve = self.hr_max - self.resting_hr_bpm
        if reserve <= 0:
            raise ValueError(
                f"non-positive HR reserve for {self.user_id}: resting HR "
                f"{self.resting_hr_bpm} >= max HR {self.hr_max:.0f}"
            )
        return reserve

    @property
    def is_age_vulnerable(self) -> bool:
        return self.age_years >= 65 or self.age_years <= 12

    @property
    def is_obese(self) -> bool:
        return self.bmi >= 30.0


# --------------------------------------------------------------------------
# Environmental physics
# --------------------------------------------------------------------------

def rothfusz_heat_index_c(temp_c: float, rh_pct: float) -> float:
    """
    NWS Rothfusz regression heat index with both standard adjustments.
    Reference: Rothfusz, L.P. (1990), NWS Technical Attachment SR 90-23.

    This is the equation THERMOSTAT critiques. We compute it deliberately:
    it is the baseline the personalized model must beat, and the margin of
    improvement over it is the headline result.
    """
    try:
        temp_c = float(temp_c)
        rh_pct = float(rh_pct)
    except (TypeError, ValueError):
        return float("nan")
    if math.isnan(temp_c) or math.isnan(rh_pct):
        return float("nan")

    temp_f = temp_c * 9.0 / 5.0 + 32.0
    simple = 0.5 * (temp_f + 61.0 + ((temp_f - 68.0) * 1.2) + (rh_pct * 0.094))
    if (simple + temp_f) / 2.0 < 80.0:
        return (simple - 32.0) * 5.0 / 9.0

    hi_f = (
        -42.379
        + 2.04901523 * temp_f
        + 10.14333127 * rh_pct
        - 0.22475541 * temp_f * rh_pct
        - 0.00683783 * temp_f * temp_f
        - 0.05481717 * rh_pct * rh_pct
        + 0.00122874 * temp_f * temp_f * rh_pct
        + 0.00085282 * temp_f * rh_pct * rh_pct
        - 0.00000199 * temp_f * temp_f * rh_pct * rh_pct
    )
    if rh_pct < 13.0 and 80.0 <= temp_f <= 112.0:
        hi_f -= ((13.0 - rh_pct) / 4.0) * math.sqrt((17.0 - abs(temp_f - 95.0)) / 17.0)
    elif rh_pct > 85.0 and 80.0 <= temp_f <= 87.0:
        hi_f += ((rh_pct - 85.0) / 10.0) * ((87.0 - temp_f) / 5.0)

    return (hi_f - 32.0) * 5.0 / 9.0


def pagasa_risk_class(heat_index_c: float) -> int:
    """PAGASA heat-index danger bands -> ordinal class 0..4."""
    if heat_index_c is None or (isinstance(heat_index_c, float)
                                and math.isnan(heat_index_c)):
        return -1
    if heat_index_c < 27:
        return 0
    if heat_index_c <= 32:
        return 1
    if heat_index_c <= 41:
        return 2
    if heat_index_c <= 51:
        return 3
    return 4


def estimate_wbgt_c(temp_c: float, rh_pct: float) -> float:
    """
    APPROXIMATE shade WBGT from dry-bulb temperature and relative humidity
    (Australian Bureau of Meteorology approximation):

        e    = (RH/100) * 6.105 * exp(17.27*T / (237.7+T))
        WBGT = 0.567*T + 0.393*e + 3.94

    !! This is NOT measured WBGT. True ISO 7243 WBGT requires a globe
       thermometer and air velocity, neither of which the BME280 provides.
       It systematically underestimates WBGT in direct sun. Report it as
       "estimated WBGT" everywhere, and state the limitation in Chapter 3.
    """
    try:
        temp_c = float(temp_c)
        rh_pct = float(rh_pct)
    except (TypeError, ValueError):
        return float("nan")
    if math.isnan(temp_c) or math.isnan(rh_pct):
        return float("nan")

    vapour_pressure = (rh_pct / 100.0) * 6.105 * math.exp(
        17.27 * temp_c / (237.7 + temp_c)
    )
    return 0.567 * temp_c + 0.393 * vapour_pressure + 3.94


# ISO 7243 reference WBGT limits (deg C) by metabolic class.
# Index: 0 rest, 1 low, 2 moderate, 3 high, 4 very high.
ISO7243_LIMITS_ACCLIMATIZED = (33.0, 30.0, 28.0, 26.0, 25.0)
ISO7243_LIMITS_UNACCLIMATIZED = (32.0, 29.0, 26.0, 23.0, 20.0)


def iso7243_risk_class(wbgt_c: float, profile: UserProfile) -> int:
    """
    Occupational risk band from estimated WBGT against the ISO 7243 limit for
    this user's metabolic class and acclimatization state.

    Expressed as a ratio to the limit so it stays interpretable:
        < 0.85  -> 0    0.85-0.95 -> 1    0.95-1.05 -> 2
        1.05-1.15 -> 3  >= 1.15   -> 4
    """
    if wbgt_c is None or (isinstance(wbgt_c, float) and math.isnan(wbgt_c)):
        return -1
    limits = (ISO7243_LIMITS_ACCLIMATIZED if profile.acclimatized
              else ISO7243_LIMITS_UNACCLIMATIZED)
    limit = limits[profile.metabolic_class]
    ratio = wbgt_c / limit
    if ratio < 0.85:
        return 0
    if ratio < 0.95:
        return 1
    if ratio < 1.05:
        return 2
    if ratio < 1.15:
        return 3
    return 4


# --------------------------------------------------------------------------
# Physiological strain
# --------------------------------------------------------------------------

def psi_heart_rate(hr_bpm: float, profile: UserProfile) -> float:
    """
    Heart-rate-only Physiological Strain Index, scaled 0-10.

        PSI = 5 * (HR_t - HR_rest) / (HR_max - HR_rest)

    Adapted from Moran, D.S. et al. (1998), "A physiological strain index to
    evaluate heat stress", Am. J. Physiol. 275(1). The full index weights
    core temperature and heart rate equally; with no core-temp sensor we use
    the HR term at full scale.

    HR_rest is per-user, captured during onboarding — this is exactly what
    Specific Objective 1's profiling module exists to provide, and it is what
    makes the strain score personalized.
    """
    try:
        hr_bpm = float(hr_bpm)
    except (TypeError, ValueError):
        return float("nan")
    if math.isnan(hr_bpm):
        return float("nan")

    psi = 5.0 * (hr_bpm - profile.resting_hr_bpm) / profile.hr_reserve
    return float(np.clip(psi, 0.0, 10.0))


def psi_risk_class(psi: float) -> int:
    """
    Moran's PSI severity bands collapsed onto our 0-4 ordinal scale:
        0-2 none/little | 3-4 low | 5-6 moderate | 7-8 high | 9-10 very high
    """
    if psi is None or (isinstance(psi, float) and math.isnan(psi)):
        return -1
    if psi < 3:
        return 0
    if psi < 5:
        return 1
    if psi < 7:
        return 2
    if psi < 9:
        return 3
    return 4


# --------------------------------------------------------------------------
# Input validation
# --------------------------------------------------------------------------

def validate_telemetry(df: pd.DataFrame,
                       drop_invalid: bool = False) -> pd.DataFrame:
    """
    Range-check every sensor column, marking out-of-range readings as NaN and
    recording a per-row `sensor_fault` flag.

    A reading outside physical range is a sensor fault. Labeling it anyway
    produces confident nonsense — the exact failure mode that bit the dataset
    profiler. Fail loudly instead.
    """
    out = df.copy()
    fault = pd.Series(False, index=out.index)

    for col, (lo, hi) in SENSOR_RANGES.items():
        if col not in out.columns:
            continue
        series = pd.to_numeric(out[col], errors="coerce")
        bad = series.notna() & ((series < lo) | (series > hi))
        n_bad = int(bad.sum())
        if n_bad:
            print(f"  [validate] {col}: {n_bad:,} reading(s) outside "
                  f"[{lo}, {hi}] -> NaN")
        series[bad] = np.nan
        out[col] = series
        fault |= bad | series.isna()

    out["sensor_fault"] = fault
    n_fault = int(fault.sum())
    if n_fault:
        print(f"  [validate] {n_fault:,}/{len(out):,} row(s) flagged "
              f"({100.0 * n_fault / max(len(out), 1):.1f}%)")

    if drop_invalid:
        out = out[~out["sensor_fault"]].copy()
        print(f"  [validate] dropped faulty rows -> {len(out):,} remain")

    return out


# --------------------------------------------------------------------------
# SpO2 desaturation
# --------------------------------------------------------------------------

def spo2_desaturation_flag(df: pd.DataFrame,
                           timestamp_col: str = "timestamp",
                           threshold: float = SPO2_DESAT_THRESHOLD,
                           sustain_s: int = SPO2_DESAT_SUSTAIN_S) -> pd.Series:
    """
    True where SpO2 has been continuously below `threshold` for at least
    `sustain_s` seconds.

    A single low sample is almost always a motion artefact — the MAX30102 is
    notoriously motion-sensitive on a moving wrist. Requiring sustained
    desaturation is what makes this usable in the field rather than a
    false-alarm generator.
    """
    if "spo2_pct" not in df.columns:
        return pd.Series(False, index=df.index)

    spo2 = pd.to_numeric(df["spo2_pct"], errors="coerce")
    below = spo2 < threshold

    ts = pd.to_datetime(df[timestamp_col])
    # Identify runs of consecutive `below` values and measure each run's span.
    run_id = (below != below.shift()).cumsum()
    flag = pd.Series(False, index=df.index)

    for _, idx in below.groupby(run_id).groups.items():
        if not below.loc[idx].iloc[0]:
            continue  # this run is "not below"
        span = (ts.loc[idx].max() - ts.loc[idx].min()).total_seconds()
        if span >= sustain_s:
            flag.loc[idx] = True

    return flag


# --------------------------------------------------------------------------
# Fusion rule — the ground-truth generator
# --------------------------------------------------------------------------

def fuse_risk(env_class: int,
              psi_class: int,
              profile: UserProfile,
              spo2_desat: bool = False) -> int:
    """
    Combine environmental and physiological bands, then apply personalized
    escalations.

        base = max(env_class, psi_class)
        +1 if cardiovascular condition AND env_class >= 2
        +1 if BMI >= 30              AND env_class >= 2
        +1 if age >= 65 or <= 12
        +1 if sustained SpO2 desaturation
        clipped to [0, 4]

    The escalations are gated on env_class >= 2 for comorbidity and obesity
    because those conditions amplify heat vulnerability — they do not create
    risk in a cool environment. Age and desaturation are ungated: an 80-year-
    old is at elevated baseline risk, and sustained hypoxaemia is a concern
    regardless of ambient conditions.

    NOTE: these weights are a defensible starting point drawn from the
    epidemiological literature on heat vulnerability, not empirically tuned.
    Chapter 3 must present them as an a-priori clinical prior, and the
    sensitivity of results to them should be reported.
    """
    if env_class < 0 and psi_class < 0:
        return -1

    base = max(env_class, psi_class)
    escalation = 0

    if profile.cardiovascular_condition and env_class >= 2:
        escalation += 1
    if profile.is_obese and env_class >= 2:
        escalation += 1
    if profile.is_age_vulnerable:
        escalation += 1
    if spo2_desat:
        escalation += 1

    # Cap the total vulnerability adjustment, and cap it harder at the top of
    # the scale.
    #
    # Two failures this prevents, both observed on realistic Manila telemetry:
    #  1. Unbounded stacking. A 68-year-old with high BMI and cardiac history
    #     collects +3 before any physiology is considered. Risk factors do
    #     compound, but sub-additively, so the total is capped.
    #  2. Saturation at the top. When conditions are already Danger, adding
    #     +2 pins every vulnerable user at Extreme Danger all day — clinically
    #     implausible and useless as a training signal.
    #
    # The tighter cap at base >= 3 also encodes the project's actual thesis:
    # personalization carries the most information in the MIDDLE bands, where
    # a generic heat-index system tells a vulnerable person they are fine and
    # they are not. When the environment is dangerous for everyone, a
    # personalized system has little left to add.
    effective_cap = MAX_ESCALATION if base <= 2 else 1
    escalation = min(escalation, effective_cap)

    return int(np.clip(base + escalation, 0, RISK_CLASS_MAX))


# --------------------------------------------------------------------------
# Windowed feature engineering
# --------------------------------------------------------------------------

def add_windowed_features(df: pd.DataFrame,
                          columns: Iterable[str],
                          windows_min: Iterable[int] = FEATURE_WINDOWS_MIN,
                          timestamp_col: str = "timestamp") -> pd.DataFrame:
    """
    For each column and window, add mean / gradient / standard deviation —
    the schema used by Tartarini et al., so we inherit a published precedent
    rather than inventing one.

    The GRADIENT terms are the ones that matter most for forecasting. A tree
    model cannot see trajectory from a single timestamp; the rate of change
    of heart rate under rising ambient temperature is the early-warning
    signal that a static snapshot cannot express.
    """
    out = df.copy()
    ts = pd.to_datetime(out[timestamp_col])
    out = out.set_index(ts)

    for col in columns:
        if col not in out.columns:
            continue
        series = pd.to_numeric(out[col], errors="coerce")
        for w in windows_min:
            win = f"{w}min"
            roll = series.rolling(win, min_periods=2)
            out[f"mean.{col}_{w}"] = roll.mean()
            out[f"sd.{col}_{w}"] = roll.std()
            # Gradient: change across the window, per minute.
            first = roll.apply(lambda a: a[0] if len(a) else np.nan, raw=True)
            out[f"grad.{col}_{w}"] = (series - first) / float(w)

    return out.reset_index(drop=True)


# --------------------------------------------------------------------------
# Main entry points
# --------------------------------------------------------------------------

def label_dataframe(df: pd.DataFrame,
                    profile: UserProfile,
                    timestamp_col: str = "timestamp",
                    validate: bool = True,
                    use_iso_in_fusion: bool = False) -> pd.DataFrame:
    """
    Attach every intermediate quantity and the final risk class to a telemetry
    frame.

    Required columns:
        timestamp, ambient_temp_c, relative_humidity_pct, heart_rate_bpm
    Optional:
        spo2_pct

    Every intermediate is kept, not just the final label. When a panelist asks
    "why is this row Danger?", you must be able to point at the heat index,
    the PSI, and each escalation that fired.
    """
    required = {timestamp_col, "ambient_temp_c",
                "relative_humidity_pct", "heart_rate_bpm"}
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"missing required column(s): {sorted(missing)}")

    out = validate_telemetry(df, drop_invalid=False) if validate else df.copy()
    out[timestamp_col] = pd.to_datetime(out[timestamp_col])
    out = out.sort_values(timestamp_col).reset_index(drop=True)

    # --- environmental ---------------------------------------------------
    out["heat_index_c"] = [
        rothfusz_heat_index_c(t, r)
        for t, r in zip(out["ambient_temp_c"], out["relative_humidity_pct"])
    ]
    out["wbgt_est_c"] = [
        estimate_wbgt_c(t, r)
        for t, r in zip(out["ambient_temp_c"], out["relative_humidity_pct"])
    ]
    out["pagasa_class"] = [pagasa_risk_class(h) for h in out["heat_index_c"]]
    out["iso7243_class"] = [iso7243_risk_class(w, profile)
                            for w in out["wbgt_est_c"]]

    # !! DO NOT fuse ISO 7243 into the environmental band by default.
    #
    # ISO 7243's WBGT reference limits were derived for temperate industrial
    # settings. In Philippine conditions the estimated WBGT exceeds the
    # moderate-work limit (28 C) for essentially the entire working day, so
    # iso7243_class pins at 3-4 from sunrise onward. Fusing it with max()
    # saturates the label: on a realistic Manila day it produced 93-100%
    # "Extreme Danger", which carries no information and would train a model
    # that predicts the majority class and looks accurate while being useless.
    #
    # PAGASA bands are calibrated for exactly this climate, so they are the
    # primary environmental signal. ISO 7243 is retained as an ADVISORY
    # column — it is the right standard to cite for occupational exposure
    # limits, and Ria/Sophia may want it for work-rest cycling advice — but
    # it does not drive the training label unless explicitly enabled.
    if use_iso_in_fusion:
        out["env_class"] = out[["pagasa_class", "iso7243_class"]].max(axis=1)
    else:
        out["env_class"] = out["pagasa_class"]

    # --- physiological ---------------------------------------------------
    out["psi"] = [psi_heart_rate(h, profile) for h in out["heart_rate_bpm"]]
    out["psi_class"] = [psi_risk_class(p) for p in out["psi"]]
    out["spo2_desat"] = spo2_desaturation_flag(out, timestamp_col)

    # --- profile (constant, but carried so the model can use them) -------
    out["age_years"] = profile.age_years
    out["bmi"] = profile.bmi
    out["cardiovascular_flag"] = int(profile.cardiovascular_condition)
    out["user_id"] = profile.user_id

    # --- fusion ----------------------------------------------------------
    out["risk_class"] = [
        fuse_risk(int(e), int(p), profile, bool(s))
        for e, p, s in zip(out["env_class"], out["psi_class"], out["spo2_desat"])
    ]
    out["risk_name"] = out["risk_class"].map(RISK_NAMES).fillna("Unknown")

    # Baseline for comparison: what the generic Rothfusz-only system would
    # have said. The margin between this and risk_class IS the contribution.
    out["baseline_class"] = out["pagasa_class"]
    out["personalization_delta"] = out["risk_class"] - out["baseline_class"]

    _check_label_saturation(out)
    return out


def _check_label_saturation(df: pd.DataFrame,
                            threshold: float = 0.80) -> None:
    """
    Warn when the label collapses onto a single class.

    A saturated label is worse than no label: a classifier trained on it
    reaches high accuracy by predicting the majority class and appears to
    work. This check exists because fusing ISO 7243 into the environmental
    band produced exactly that failure on realistic Philippine conditions,
    and nothing in the pipeline would otherwise have caught it.
    """
    counts = df["risk_class"].value_counts(normalize=True)
    if counts.empty:
        return
    top_class = int(counts.index[0])
    top_frac = float(counts.iloc[0])
    if top_frac >= threshold:
        print(f"  [labeling] !! LABEL SATURATION WARNING")
        print(f"             {top_frac * 100:.1f}% of rows are class "
              f"{top_class} ({RISK_NAMES.get(top_class)}).")
        print(f"             A model trained on this will predict the majority")
        print(f"             class and look accurate while being useless.")
        print(f"             Check the environmental banding before training.")
    n_classes = int((counts > 0.01).sum())
    if n_classes < 3:
        print(f"  [labeling] !! only {n_classes} class(es) above 1% — the "
              f"label lacks the resolution to train an ordinal model.")


def make_forecast_target(df: pd.DataFrame,
                         horizon_min: int = FORECAST_HORIZON_MIN,
                         timestamp_col: str = "timestamp",
                         feature_columns: Iterable[str] | None = None
                         ) -> pd.DataFrame:
    """
    Build the supervised learning frame: features at time t, label at t+H.

    This is the step that turns a rule evaluation into a forecasting problem.
    Rows without a future observation at the horizon are dropped — they have
    no label, and inventing one would leak.
    """
    if feature_columns is None:
        feature_columns = ["ambient_temp_c", "relative_humidity_pct",
                           "heart_rate_bpm"]
        if "spo2_pct" in df.columns:
            feature_columns.append("spo2_pct")

    out = add_windowed_features(df, feature_columns,
                                timestamp_col=timestamp_col)
    out[timestamp_col] = pd.to_datetime(df[timestamp_col].values)

    # For each row, find the risk_class observed horizon_min later.
    ts = out[timestamp_col]
    target_time = ts + pd.Timedelta(minutes=horizon_min)
    lookup = pd.Series(out["risk_class"].values, index=ts)

    future = lookup.reindex(
        lookup.index.union(target_time)
    ).ffill().reindex(target_time)

    out["risk_class_future"] = future.values
    out["horizon_min"] = horizon_min

    # Drop rows whose horizon extends past the end of the recording.
    valid = target_time <= ts.max()
    dropped = int((~valid).sum())
    out = out[valid & out["risk_class_future"].notna()].copy()
    out["risk_class_future"] = out["risk_class_future"].astype(int)

    print(f"  [forecast] horizon {horizon_min} min: {len(out):,} labeled row(s), "
          f"{dropped:,} dropped past end of recording")
    dist = out["risk_class_future"].value_counts(normalize=True).sort_index()
    print("  [forecast] target distribution:")
    for cls, frac in dist.items():
        print(f"      {RISK_NAMES.get(int(cls), cls):<16} {frac * 100:6.2f}%")
    danger = float(dist.get(3, 0)) + float(dist.get(4, 0))
    if danger < 0.05:
        print(f"  [forecast] !! Danger+ is only {danger * 100:.2f}% of rows.")
        print("             Use stratified splits, class weighting, and report")
        print("             PR-AUC and per-class recall — NOT accuracy.")

    return out


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------

def _self_test() -> int:
    """Assertions covering the physics, the fusion rule, and the pipeline."""
    print("Running THERMOSTAT labeling engine self-test\n")

    p = UserProfile(user_id="T01", age_years=30, height_cm=170,
                    weight_kg=70, resting_hr_bpm=60)

    # --- heat index against published NWS chart values -------------------
    for t, rh, expect in [(35, 80, 56.5), (32, 70, 40.4), (25, 90, 25.9)]:
        got = rothfusz_heat_index_c(t, rh)
        assert abs(got - expect) < 0.3, f"HI({t},{rh})={got}, expected {expect}"
    print("  OK  heat index matches NWS reference values")

    assert pagasa_risk_class(rothfusz_heat_index_c(25, 40)) == 0
    assert pagasa_risk_class(rothfusz_heat_index_c(35, 80)) == 4
    assert pagasa_risk_class(float("nan")) == -1
    print("  OK  PAGASA banding")

    # --- WBGT sanity: must be below dry-bulb in unsaturated air ----------
    w = estimate_wbgt_c(35, 50)
    assert 20 < w < 35, w
    assert estimate_wbgt_c(35, 90) > estimate_wbgt_c(35, 20), "WBGT must rise with RH"
    print(f"  OK  estimated WBGT monotonic in humidity ({w:.1f} C at 35C/50%)")

    # --- PSI --------------------------------------------------------------
    assert psi_heart_rate(60, p) == 0.0, "resting HR must give PSI 0"
    assert abs(psi_heart_rate(p.hr_max, p) - 5.0) < 0.01, "HR max -> PSI 5"
    assert psi_risk_class(psi_heart_rate(60, p)) == 0
    print(f"  OK  PSI (HR_max={p.hr_max:.0f}, reserve={p.hr_reserve:.0f})")

    # --- profile guards ---------------------------------------------------
    for bad in [dict(age_years=-5), dict(height_cm=10),
                dict(weight_kg=0), dict(resting_hr_bpm=200)]:
        kw = dict(user_id="X", age_years=30, height_cm=170,
                  weight_kg=70, resting_hr_bpm=60)
        kw.update(bad)
        try:
            UserProfile(**kw)
        except ValueError:
            pass
        else:
            raise AssertionError(f"profile guard missed {bad}")
    print("  OK  profile validation rejects implausible inputs")

    # --- fusion rule ------------------------------------------------------
    assert fuse_risk(0, 0, p) == 0
    assert fuse_risk(3, 1, p) == 3, "base is the max of the two bands"
    # comorbidity escalates only in heat
    p_cvd = UserProfile("T02", 30, 170, 70, 60, cardiovascular_condition=True)
    assert fuse_risk(2, 0, p_cvd) == 3, "CVD must escalate at env>=2"
    assert fuse_risk(1, 0, p_cvd) == 1, "CVD must NOT escalate below env 2"
    # obesity
    p_ob = UserProfile("T03", 30, 170, 95, 60)          # BMI 32.9
    assert p_ob.is_obese
    assert fuse_risk(2, 0, p_ob) == 3
    # age, ungated
    p_old = UserProfile("T04", 72, 170, 70, 60)
    assert fuse_risk(0, 0, p_old) == 1, "age escalation is ungated"
    # clipping
    p_all = UserProfile("T05", 80, 170, 100, 60, cardiovascular_condition=True)
    assert fuse_risk(4, 4, p_all, spo2_desat=True) == 4, "must clip at 4"
    print("  OK  fusion rule: gating, escalation and clipping")

    # --- sensor validation ------------------------------------------------
    bad_df = pd.DataFrame({
        "timestamp": pd.date_range("2026-08-21 08:00", periods=4, freq="1min"),
        "ambient_temp_c": [30.0, 999.0, 31.0, 32.0],     # 999 = fault
        "relative_humidity_pct": [70.0, 70.0, 70.0, 70.0],
        "heart_rate_bpm": [80.0, 82.0, 5.0, 85.0],       # 5 bpm = fault
    })
    checked = validate_telemetry(bad_df)
    assert checked["ambient_temp_c"].isna().sum() == 1
    assert checked["heart_rate_bpm"].isna().sum() == 1
    assert int(checked["sensor_fault"].sum()) == 2
    print("  OK  sensor faults caught, not labeled")

    # --- SpO2 sustained desaturation --------------------------------------
    n = 300
    desat_df = pd.DataFrame({
        "timestamp": pd.date_range("2026-08-21 08:00", periods=n, freq="1s"),
        "spo2_pct": [98.0] * 100 + [92.0] * 10 + [98.0] * 90 + [91.0] * 100,
    })
    flag = spo2_desaturation_flag(desat_df)
    assert not flag.iloc[100:110].any(), "10 s dip must NOT flag (artefact)"
    assert flag.iloc[200:300].all(), "100 s desaturation MUST flag"
    print("  OK  SpO2 desaturation requires sustained duration")

    # --- end-to-end pipeline ---------------------------------------------
    n = 240
    ramp = pd.DataFrame({
        "timestamp": pd.date_range("2026-08-21 09:00", periods=n, freq="1min"),
        "ambient_temp_c": np.linspace(26, 41, n),
        "relative_humidity_pct": np.linspace(55, 85, n),
        "heart_rate_bpm": np.linspace(65, 150, n),
        "spo2_pct": np.linspace(99, 95, n),
    })
    labeled = label_dataframe(ramp, p)
    assert labeled["risk_class"].iloc[0] < labeled["risk_class"].iloc[-1], \
        "risk must rise as conditions worsen"
    assert set(labeled["risk_class"].unique()) - set(range(5)) == set()
    print(f"  OK  end-to-end: risk {labeled['risk_class'].iloc[0]} -> "
          f"{labeled['risk_class'].iloc[-1]} across the ramp")

    # --- forecasting target ----------------------------------------------
    train = make_forecast_target(labeled, horizon_min=20)
    assert "risk_class_future" in train.columns
    assert len(train) < len(labeled), "horizon rows must be dropped at the tail"
    assert any(c.startswith("grad.") for c in train.columns), "no gradient features"
    # The future label must genuinely differ from the present one somewhere,
    # otherwise we have built a trivial identity task.
    assert (train["risk_class_future"] != train["risk_class"]).any(), \
        "forecast target is identical to present label — not a forecast"
    print("  OK  forecast target built and is non-trivial")

    print("\nALL SELF-TESTS PASSED")
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="THERMOSTAT risk labeling engine")
    ap.add_argument("csv", nargs="?", help="telemetry CSV to label")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--user-id", default="P01")
    ap.add_argument("--age", type=float, default=30.0)
    ap.add_argument("--height", type=float, default=170.0, help="cm")
    ap.add_argument("--weight", type=float, default=70.0, help="kg")
    ap.add_argument("--rest-hr", type=float, default=60.0, help="bpm")
    ap.add_argument("--cvd", action="store_true", help="cardiovascular condition")
    ap.add_argument("--unacclimatized", action="store_true")
    ap.add_argument("--metabolic-class", type=int, default=2, choices=range(5))
    ap.add_argument("--horizon", type=int, default=FORECAST_HORIZON_MIN)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.self_test:
        return _self_test()

    if not args.csv:
        ap.print_help()
        return 1

    profile = UserProfile(
        user_id=args.user_id,
        age_years=args.age,
        height_cm=args.height,
        weight_kg=args.weight,
        resting_hr_bpm=args.rest_hr,
        cardiovascular_condition=args.cvd,
        acclimatized=not args.unacclimatized,
        metabolic_class=args.metabolic_class,
    )
    print(f"Profile {profile.user_id}: age {profile.age_years:.0f}, "
          f"BMI {profile.bmi:.1f}, HR_max {profile.hr_max:.0f}, "
          f"reserve {profile.hr_reserve:.0f} bpm")

    df = pd.read_csv(args.csv)
    labeled = label_dataframe(df, profile)
    train = make_forecast_target(labeled, horizon_min=args.horizon)

    out_path = args.out or args.csv.replace(".csv", "_labeled.csv")
    train.to_csv(out_path, index=False)
    print(f"\nwrote {len(train):,} labeled rows -> {out_path}")

    n_esc = int((labeled["personalization_delta"] > 0).sum())
    print(f"personalization changed the band on {n_esc:,} row(s) "
          f"({100.0 * n_esc / max(len(labeled), 1):.1f}%) vs the "
          f"generic heat-index baseline")
    return 0


if __name__ == "__main__":
    sys.exit(main())
