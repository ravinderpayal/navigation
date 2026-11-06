#!/usr/bin/env python3
"""Turns the VinFast free-charger CSV into the compact asset the app loads.

One row per connector -> one record per location, with junk removed.
Usage: python3 tool/build_chargers.py
"""
import csv, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "VINFAST LIST_Free Charging Points_India_250726.csv"
OUT = ROOT / "assets" / "free_chargers.json"
JUNK_NAME = re.compile(r"\b(test|testing|dummy|demo|orphan|orphant|sample|trial)\b", re.I)


def fix_text(s):
    s = " ".join((s or "").split())
    try:  # Undo UTF-8 read as Windows-1252 ("â€“" -> "–").
        return s.encode("cp1252").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return s


def coords(row):
    try:
        lat, lng = float(row["Lat"]), float(row["Long"])
    except ValueError:
        return None
    if 6 <= lat <= 38 and 68 <= lng <= 98:
        return lat, lng
    if 6 <= lng <= 38 and 68 <= lat <= 98:  # Lat/long swapped by data entry.
        return lng, lat
    return None


def main():
    locations, dropped = {}, {"no_coords": set(), "junk_name": set()}
    with SRC.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            lid, name = row["Location Id"], fix_text(row["Location Name"])
            if JUNK_NAME.search(name):
                dropped["junk_name"].add(f"{lid}: {name}")
                continue
            pos = coords(row)
            if pos is None:
                dropped["no_coords"].add(f"{lid}: {name} ({row['Lat']},{row['Long']})")
                continue
            loc = locations.setdefault(lid, {
                "id": lid, "name": name, "cpo": row["Party Id"],
                "city": fix_text(row["City Name"]), "state": fix_text(row["State Name"]),
                "address": fix_text(row["Address"]),
                "lat": round(pos[0], 6), "lng": round(pos[1], 6),
                "dcKw": 0.0, "dcCount": 0, "acKw": 0.0, "acCount": 0,
            })
            try:
                kw = float(row["Capacity (kWh)"])  # Column is mislabelled: this is kW.
            except ValueError:
                kw = 0.0
            kind = "dc" if row["Power Type"] == "DC" else "ac"
            loc[kind + "Kw"] = max(loc[kind + "Kw"], kw)
            loc[kind + "Count"] += 1
    records = list(locations.values())
    OUT.write_text(json.dumps(records, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    dc = sum(1 for r in records if r["dcKw"] >= 20)
    print(f"{len(records)} locations ({dc} with DC >= 20 kW) -> {OUT.name}, {OUT.stat().st_size//1024} KiB", file=sys.stderr)
    for why, items in dropped.items():
        print(f"dropped {why}: {len(items)}", file=sys.stderr)
        for item in sorted(items)[:40]:
            print("   ", item, file=sys.stderr)


if __name__ == "__main__":
    main()
