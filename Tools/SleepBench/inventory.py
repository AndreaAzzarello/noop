#!/usr/bin/env python3
"""Inventory of what a NOOP database copy can offer the sleep-staging replay. Read-only, aggregates only.

    mkdir -p ~/noop-eval && chmod 700 ~/noop-eval
    unzip -p ~/Backup.noopbak noop-backup.sqlite > ~/noop-eval/noop.sqlite
    python3 -I Tools/SleepBench/inventory.py ~/noop-eval/noop.sqlite

The question it answers is "which candidate recipes are worth building on THESE nights". The channels a
candidate would read are not equally present: a recipe that needs R-R is pointless on a night that carries
few beats, and a gravity fix only matters where the stager actually meets heart rate without gravity.

What it prints: counts, percentages of 30 s epochs, and medians / p10 / p90 across nights. What it never
prints: a timestamp, a date (the raw-data span is given as a month), or any sample value. It opens the file
with `mode=ro&immutable=1`, so it cannot write, and the database stays outside the repository.

Epoch bookkeeping mirrors `SleepStagerV2.features`: 30 s epochs on the wall-clock grid, an epoch is SKIPPED
when it holds neither a heart-rate nor a gravity second, and an epoch with fewer than two gravity seconds has
no computable jerk (the stager then reads it as perfectly still).
"""
import argparse
import json
import pathlib
import sqlite3
import sys
from collections import Counter

EPOCH_S = 30
BLOCK_EPOCHS = 10          # a 5-minute block, the span of the stager's HR-variability window
BLOCK_MIN_BEATS = 100      # about a third of the ~300 beats a 5-minute block carries at 60 bpm
RR_EPOCH_MIN_BEATS = 10    # about a third of the ~30 beats a 30 s epoch carries at 60 bpm
RR_CLAMP_LO, RR_CLAMP_HI = 300, 2000   # the stager's own clamp on R-R values (ms)

# The proposed gate for the R-R candidate. NOT validated: it is a stated threshold so the decision is made
# against a number written down beforehand, not chosen after seeing it.
RR_GATE_MEDIAN_PCT = 50.0
RR_GATE_P10_PCT = 20.0


def open_ro(path):
    uri = pathlib.Path(path).resolve().as_uri() + "?mode=ro&immutable=1"
    return sqlite3.connect(uri, uri=True)


def per_epoch(con, table, device, lo, hi):
    """{epoch index: row count} for rows of `table` in [lo, hi). `table` is one of a fixed internal set."""
    return dict(con.execute(
        f"SELECT ts/{EPOCH_S}, COUNT(*) FROM {table} WHERE deviceId = ? AND ts >= ? AND ts < ? GROUP BY 1",
        (device, lo, hi)))


def longest_run_min(flags):
    best = cur = 0
    for f in flags:
        cur = cur + 1 if f else 0
        best = max(best, cur)
    return best * EPOCH_S / 60.0


def pct(num, den):
    return 100.0 * num / den if den else float("nan")


def grid(start, end):
    """(first epoch index, last epoch index) of the epochs the stager would build over [start, end)."""
    return -(-start // EPOCH_S), (end - 1) // EPOCH_S


def coverage(con, stream, start, end):
    """Per-night coverage figures, or None when the window holds no epoch."""
    k0, k1 = grid(start, end)
    n = k1 - k0 + 1
    if n <= 0:
        return None
    lo, hi = k0 * EPOCH_S, end
    hr = per_epoch(con, "hrSample", stream, lo, hi)
    rr = per_epoch(con, "rrInterval", stream, lo, hi)
    grav = per_epoch(con, "gravitySample", stream, lo, hi)
    band = per_epoch(con, "sleepStateSample", stream, lo, hi)
    ks = range(k0, k1 + 1)

    rr_out, rr_total = con.execute(
        "SELECT COALESCE(SUM(CASE WHEN rrMs < ? OR rrMs > ? THEN 1 ELSE 0 END), 0), COUNT(*) "
        "FROM rrInterval WHERE deviceId = ? AND ts >= ? AND ts < ?",
        (RR_CLAMP_LO, RR_CLAMP_HI, stream, lo, hi)).fetchone()
    resp_rows = con.execute(
        "SELECT COUNT(*) FROM respSample WHERE deviceId = ? AND ts >= ? AND ts < ?",
        (stream, lo, hi)).fetchone()[0]
    states = Counter(dict(con.execute(
        "SELECT state, COUNT(*) FROM sleepStateSample WHERE deviceId = ? AND ts >= ? AND ts < ? GROUP BY state",
        (stream, lo, hi))))

    blocks = [sum(rr.get(k, 0) for k in range(b, b + BLOCK_EPOCHS)) for b in range(k0, k1 + 1 - BLOCK_EPOCHS + 1, BLOCK_EPOCHS)]
    skipped = [hr.get(k, 0) == 0 and grav.get(k, 0) == 0 for k in ks]
    no_hr = [hr.get(k, 0) == 0 for k in ks]
    return {
        "epochs": n,
        "inbed_min": (end - start) / 60.0,
        "hr": pct(sum(1 for k in ks if hr.get(k, 0) > 0), n),
        "rr1": pct(sum(1 for k in ks if rr.get(k, 0) >= 1), n),
        "rr10": pct(sum(1 for k in ks if rr.get(k, 0) >= RR_EPOCH_MIN_BEATS), n),
        "rr_blk": pct(sum(1 for b in blocks if b >= BLOCK_MIN_BEATS), len(blocks)),
        "beats_min": rr_total / (n * EPOCH_S / 60.0),
        "rr_out": pct(rr_out, rr_total),
        "grav2": pct(sum(1 for k in ks if grav.get(k, 0) >= 2), n),
        "hr_no_grav": pct(sum(1 for k in ks if hr.get(k, 0) > 0 and grav.get(k, 0) < 2), n),
        "skipped": pct(sum(skipped), n),
        "skip_run_min": longest_run_min(skipped),
        "hr_gap_min": longest_run_min(no_hr),
        "band": pct(sum(1 for k in ks if band.get(k, 0) > 0), n),
        "band_asleep": pct(states.get(2, 0), sum(states.values())) if states else float("nan"),
        "resp_rows": resp_rows,
    }


def quantile(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    idx = p * (len(sorted_vals) - 1)
    lo = int(idx)
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (idx - lo)


def f(v, w=6, p=1):
    return f"{'n/a':>{w}}" if v != v else f"{v:{w}.{p}f}"


def stages_shape(raw):
    if raw is None:
        return "null"
    try:
        v = json.loads(raw)
    except ValueError:
        return "unparsable"
    if isinstance(v, dict):
        return "csv-dict"        # per-stage minutes only: what the WHOOP CSV import writes
    if isinstance(v, list) and v:
        first = v[0] if isinstance(v[0], dict) else {}
        if "start" in first:
            return "segments"    # a per-epoch timeline: what the on-device stagers write
        if "min" in first:
            return "minutes-list"
    return "empty"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("db", help="a COPY of the NOOP database (opened read-only, immutable)")
    ap.add_argument("--stream-device", help="deviceId of the raw streams (default: the one with most hrSample rows)")
    ap.add_argument("--session-device", help="deviceId of the computed sleep sessions (default: <stream>-noop, else the stream id)")
    ap.add_argument("--min-hours", type=float, default=3.0, help="in-bed length that counts as a night (default 3)")
    args = ap.parse_args()

    con = open_ro(args.db)
    q = lambda sql, p=(): con.execute(sql, p).fetchall()

    streams = q("SELECT deviceId, COUNT(*) FROM hrSample GROUP BY deviceId ORDER BY 2 DESC")
    if not streams:
        print("no hrSample rows in this database", file=sys.stderr)
        return 1
    stream = args.stream_device or streams[0][0]

    print("=" * 78 + "\n0. DEVICES AND RAW HISTORY\n" + "=" * 78)
    for table in ("hrSample", "rrInterval", "gravitySample", "respSample", "sleepStateSample"):
        rows = q(f"SELECT deviceId, COUNT(*) FROM {table} GROUP BY deviceId ORDER BY 2 DESC")
        print(f"{table:<17}", ", ".join(f"{d}={n}" for d, n in rows) or "(empty)")
    first, last, days = q("SELECT strftime('%Y-%m', MIN(ts), 'unixepoch'), strftime('%Y-%m', MAX(ts), 'unixepoch'), "
                          "COUNT(DISTINCT ts/86400) FROM hrSample WHERE deviceId = ?", (stream,))[0]
    print(f"streams read from {stream!r}: heart rate on {days} distinct UTC days, {first} .. {last}")

    cols = {r[1] for r in q("PRAGMA table_info(sleepSession)")}
    extra = [c for c in ("userEdited", "sleepStateJSON") if c in cols]
    sessions = [dict(zip(["dev", "start", "end", "stages"] + extra, r))
                for r in q(f"SELECT deviceId, startTs, endTs, stagesJSON{''.join(', ' + c for c in extra)} "
                           "FROM sleepSession ORDER BY startTs")]
    by_device = Counter(s["dev"] for s in sessions)
    session_device = args.session_device or (stream + "-noop" if (stream + "-noop") in by_device else stream)

    print("\n" + "=" * 78 + "\n1. SLEEP SESSIONS BY DEVICE AND STAGE-DATA SHAPE\n" + "=" * 78)
    for dev in by_device:
        mine = [s for s in sessions if s["dev"] == dev]
        shapes = Counter(stages_shape(s["stages"]) for s in mine)
        edited = sum(1 for s in mine if s.get("userEdited"))
        band_json = sum(1 for s in mine if s.get("sleepStateJSON"))
        print(f"{dev}: {len(mine)} sessions; shapes {dict(shapes)}; userEdited {edited}; with sleepStateJSON {band_json}")
    locks = q("SELECT COUNT(*) FROM cursors WHERE value = 1 AND name LIKE 'stagelock:%'")[0][0] \
        if q("SELECT name FROM sqlite_master WHERE name = 'cursors'") else 0
    print(f"stage-locked (human-authored hypnogram) sessions: {locks}")
    print(f"per-night table below uses sessions of {session_device!r}")

    print("\n" + "=" * 78 + f"\n2. PER-NIGHT COVERAGE (sessions >= {args.min_hours:g} h; % are of 30 s epochs)\n" + "=" * 78)
    print("   hr = epochs with heart rate | rr1/rr10 = epochs with >=1 / >=%d beats | rrBlk = 5-min blocks with >=%d beats"
          % (RR_EPOCH_MIN_BEATS, BLOCK_MIN_BEATS))
    print("   grav2 = epochs with >=2 gravity seconds | hrNoGrav = heart rate but <2 gravity s | skip = neither HR nor gravity")
    print("   band = epochs with a sleep_state sample | bandAsl = share of those samples that read 'asleep' (2)")
    print("  #  inbed   hr   rr1  rr10 rrBlk beats/m rrOut grav2 hrNoGr  skip skRun hrGap  band bandAsl  resp")
    nights = []
    mine = [s for s in sessions if s["dev"] == session_device and (s["end"] - s["start"]) >= args.min_hours * 3600
            and stages_shape(s["stages"]) != "csv-dict"]
    for i, s in enumerate(mine, 1):
        c = coverage(con, stream, s["start"], s["end"])
        if c is None:
            continue
        nights.append(c)
        print(f"{i:3d} {f(c['inbed_min'], 6, 0)} {f(c['hr'], 5, 0)} {f(c['rr1'], 5, 0)} {f(c['rr10'], 5, 0)} "
              f"{f(c['rr_blk'], 5, 0)} {f(c['beats_min'], 7)} {f(c['rr_out'], 5)} {f(c['grav2'], 5, 0)} "
              f"{f(c['hr_no_grav'], 6)} {f(c['skipped'], 5)} {f(c['skip_run_min'], 5, 0)} {f(c['hr_gap_min'], 5, 0)} "
              f"{f(c['band'], 5, 0)} {f(c['band_asleep'], 7, 0)} {c['resp_rows']:5d}")
    if not nights:
        print("(no qualifying nights for that session device)")

    print("\n" + "=" * 78 + f"\n3. ACROSS {len(nights)} NIGHTS: median / p10 / p90\n" + "=" * 78)
    labels = [("inbed_min", "in bed (min)"), ("hr", "epochs with HR %"), ("rr1", "epochs with >=1 RR %"),
              ("rr10", f"epochs with >={RR_EPOCH_MIN_BEATS} RR %"), ("rr_blk", "5-min blocks >= %d beats %%" % BLOCK_MIN_BEATS),
              ("beats_min", "RR beats / minute"), ("rr_out", f"RR outside {RR_CLAMP_LO}-{RR_CLAMP_HI} ms %"),
              ("grav2", "epochs with >=2 gravity s %"), ("hr_no_grav", "HR but no usable gravity %"),
              ("skipped", "epochs skipped (no HR, no gravity) %"), ("skip_run_min", "longest skipped run (min)"),
              ("hr_gap_min", "longest HR gap (min)"), ("band", "epochs with band state %")]
    summary = {}
    for key, label in labels:
        vals = sorted(c[key] for c in nights if c[key] == c[key])
        summary[key] = (quantile(vals, 0.5), quantile(vals, 0.1), quantile(vals, 0.9))
        print(f"{label:<38} median {f(summary[key][0], 7)}   p10 {f(summary[key][1], 7)}   p90 {f(summary[key][2], 7)}")
    nights_hr_no_grav = sum(1 for c in nights if c["hr_no_grav"] > 1.0)
    nights_skipped = sum(1 for c in nights if c["skipped"] > 1.0)
    print(f"\nnights with >1 % epochs of HR-without-gravity: {nights_hr_no_grav} of {len(nights)}")
    print(f"nights with >1 % epochs skipped (interior holes): {nights_skipped} of {len(nights)}")
    print(f"nights with any resp rows: {sum(1 for c in nights if c['resp_rows'] > 0)} of {len(nights)}")
    if nights:
        med, p10 = summary["rr10"][0], summary["rr10"][1]
        verdict = "KEEP" if (med >= RR_GATE_MEDIAN_PCT and p10 >= RR_GATE_P10_PCT) else "DISCARD"
        print(f"\nR-R candidate gate (proposed, not validated): median rr>={RR_EPOCH_MIN_BEATS} {f(med, 0, 1).strip()} % "
              f"(need >= {RR_GATE_MEDIAN_PCT:g}), p10 {f(p10, 0, 1).strip()} % (need >= {RR_GATE_P10_PCT:g}) -> {verdict}")

    print("\n" + "=" * 78 + "\n4. WHOOP CSV SESSIONS AND OVERLAP WITH RAW STREAMS\n" + "=" * 78)
    csv = [s for s in sessions if stages_shape(s["stages"]) == "csv-dict"]
    computed = [s for s in sessions if stages_shape(s["stages"]) == "segments"]
    print(f"WHOOP CSV sessions (per-stage minutes only, no timeline): {len(csv)}; "
          f">= {args.min_hours:g} h: {sum(1 for s in csv if s['end'] - s['start'] >= args.min_hours * 3600)}")
    with_hr = with_rr = with_noop = usable = 0
    for s in csv:
        if s["end"] - s["start"] < args.min_hours * 3600:
            continue
        c = coverage(con, stream, s["start"], s["end"])
        raw_ok = c is not None and c["hr"] >= 50.0
        with_hr += raw_ok
        with_rr += bool(raw_ok and c["rr10"] >= 50.0)
        span = s["end"] - s["start"]
        overlap = any(min(s["end"], o["end"]) - max(s["start"], o["start"]) >= 0.5 * span for o in computed)
        with_noop += overlap
        usable += bool(raw_ok or overlap)
    print(f"  of those with raw heart rate on >= 50 % of epochs (replayable): {with_hr}")
    print(f"  of those also with >= {RR_EPOCH_MIN_BEATS}-beat R-R on >= 50 % of epochs: {with_rr}")
    print(f"  of those overlapping a NOOP-computed session by >= 50 % of their span: {with_noop}")
    print(f"  usable for a per-stage-minutes comparison (replayable or already staged): {usable}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
