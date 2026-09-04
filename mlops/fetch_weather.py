#!/usr/bin/env python3
"""
THERMOSTAT — fetch a REAL weather trace for the collection site.

Path B pairs PPG-DaLiA physiology with an environment it was never recorded
under. The pairing is synthetic no matter what. The weather itself does not
have to be: inventing a sine wave and calling it Zamboanga would be a second
fabrication stacked on the first, and the whole defence of Path B is that
exactly one thing about it is invented.

So this pulls observed hourly temperature and humidity from the Open-Meteo
historical archive (ERA5 reanalysis, free, no API key) for real coordinates on
real dates, and writes the two-column CSV that ingest_dalia.py --environment
expects.

WHICH DAY IT PICKS, AND WHY THAT MATTERS
----------------------------------------
By default it takes the HOTTEST day in the requested window. For a pipeline
test that is the right choice — you want the labeller to exercise the Danger
classes rather than emit 4,000 Safe rows. But understand what you are doing:
you are selecting the day most likely to produce alarming labels. That is a
third reason Path B numbers are not results, on top of the two already in
ingest_dalia.py's docstring. Use --pick median if you want a typical day.

Usage:
    python fetch_weather.py                      # Zamboanga, last 30 days, hottest
    python fetch_weather.py --pick median
    python fetch_weather.py --start 2026-04-01 --end 2026-04-30
    python fetch_weather.py --lat 14.5995 --lon 120.9842 --name manila

If the machine has no internet, fill data/weather_manual.csv by hand from a
PAGASA bulletin with the header this script writes, and pass that instead.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Zamboanga City. Change with --lat/--lon for a different collection site.
DEFAULT_LAT = 6.9214
DEFAULT_LON = 122.0790

ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
ARCHIVE_LAG_DAYS = 7        # ERA5 reanalysis publishes on a delay
HEADER = ("timestamp", "ambient_temp_c", "relative_humidity_pct")


def project_root() -> Path:
    """Resolve paths against the repo, not the shell's cwd."""
    return Path(__file__).resolve().parent.parent


def build_url(lat: float, lon: float, start: str, end: str) -> str:
    return ARCHIVE_URL + "?" + urllib.parse.urlencode({
        "latitude": lat,
        "longitude": lon,
        "start_date": start,
        "end_date": end,
        "hourly": "temperature_2m,relative_humidity_2m",
        "timezone": "Asia/Manila",
    })


def fetch(url: str, timeout: int = 60) -> dict:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:400]
        raise SystemExit(f"Open-Meteo returned HTTP {e.code}\n  {body}\n"
                         f"  requested: {url}")
    except urllib.error.URLError as e:
        raise SystemExit(
            f"could not reach Open-Meteo: {e.reason}\n"
            "  If this machine has no internet, write the CSV by hand from a\n"
            "  PAGASA bulletin using the header:\n"
            f"    {','.join(HEADER)}")


def parse_hourly(payload: dict) -> list[tuple[str, float, float]]:
    """
    Validate the response shape before trusting it. A silently-missing field
    would otherwise surface much later as an all-NaN heat index.
    """
    hourly = payload.get("hourly")
    if not isinstance(hourly, dict):
        raise SystemExit(f"unexpected response: no 'hourly' object\n"
                         f"  keys present: {sorted(payload)}")

    for key in ("time", "temperature_2m", "relative_humidity_2m"):
        if key not in hourly:
            raise SystemExit(
                f"unexpected response: 'hourly' is missing {key!r}\n"
                f"  keys present: {sorted(hourly)}\n"
                "  The Open-Meteo field names may have changed; check\n"
                "  https://open-meteo.com/en/docs/historical-weather-api")

    times = hourly["time"]
    temps = hourly["temperature_2m"]
    rhs = hourly["relative_humidity_2m"]
    if not (len(times) == len(temps) == len(rhs)):
        raise SystemExit(f"ragged response: {len(times)} times, "
                         f"{len(temps)} temps, {len(rhs)} humidities")
    if not times:
        raise SystemExit(
            "the archive returned zero hours for that date range.\n"
            "  ERA5 publishes on a delay — try an end date at least a week "
            "in the past.")

    rows = [(t, float(a), float(h))
            for t, a, h in zip(times, temps, rhs)
            if a is not None and h is not None]
    if not rows:
        raise SystemExit("every hour in the range was null")
    return rows


def group_by_day(rows) -> dict:
    days: dict[str, list] = {}
    for t, a, h in rows:
        days.setdefault(t[:10], []).append((t, a, h))
    # A partial day would produce a truncated trace; require most of one.
    return {d: v for d, v in days.items() if len(v) >= 20}


def choose_day(days: dict, how: str) -> str:
    ranked = sorted(days, key=lambda d: max(a for _, a, _ in days[d]))
    if how == "hottest":
        return ranked[-1]
    return ranked[len(ranked) // 2]


def main() -> int:
    today = dt.date.today()
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, default=DEFAULT_LAT)
    ap.add_argument("--lon", type=float, default=DEFAULT_LON)
    ap.add_argument("--name", default="zamboanga",
                    help="used in the output filename")
    ap.add_argument("--start", default=str(today - dt.timedelta(
        days=ARCHIVE_LAG_DAYS + 30)))
    ap.add_argument("--end", default=str(today - dt.timedelta(
        days=ARCHIVE_LAG_DAYS)))
    ap.add_argument("--pick", choices=("hottest", "median"), default="hottest")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    out = Path(args.out) if args.out else \
        project_root() / "data" / f"weather_{args.name}.csv"
    out.parent.mkdir(parents=True, exist_ok=True)

    url = build_url(args.lat, args.lon, args.start, args.end)
    print(f"Open-Meteo historical archive (ERA5)")
    print(f"  site   {args.lat}, {args.lon}  ({args.name})")
    print(f"  window {args.start} .. {args.end}\n")

    days = group_by_day(parse_hourly(fetch(url)))
    if not days:
        raise SystemExit("no complete day in that range")

    chosen = choose_day(days, args.pick)
    trace = days[chosen]
    temps = [a for _, a, _ in trace]
    rhs = [h for _, _, h in trace]

    with out.open("w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(HEADER)
        for t, a, h in trace:
            w.writerow([t.replace("T", " "), round(a, 1), round(h, 1)])

    print(f"{len(days)} complete days available; picked the "
          f"{args.pick}: {chosen}")
    print(f"  temperature  {min(temps):.1f} – {max(temps):.1f} °C")
    print(f"  humidity     {min(rhs):.0f} – {max(rhs):.0f} %")
    print(f"  {len(trace)} hourly observations -> {out}\n")

    if args.pick == "hottest":
        print("Note: you selected the hottest day in the window. That is the")
        print("right choice for exercising the labeller, and one more reason")
        print("the resulting metrics are a pipeline test, not a result.")

    rel = out.relative_to(project_root())
    print(f"\nNext:\n  python run_pathb.py --environment ../{rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
