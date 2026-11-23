#!/usr/bin/env python3
"""Export recorded nights from a NOOP database copy as CSV for `main.swift` (the Smart Wake replay).

    unzip -p ~/Backup.noopbak noop-backup.sqlite > /tmp/noop.sqlite
    python3 Tools/SmartWakeReplay/export.py /tmp/noop.sqlite /tmp/smartwake-nights

One `night_<startTs>.csv` per sleep session, with these line types:

    N,<startTs>,<endTs>             the session bounds (unix seconds)
    S,<start>,<end>,<stage>         the stored stage segments (the after-the-night V2 result)
    H,<ts>,<bpm>                    heart rate, 1 Hz
    R,<ts>,<rrMs>                   RR intervals, in the within-second order the store keeps
    B,<ts>,<state>                  the strap's own sleep_state (0 wake, 1 still, 2 asleep, 3 up)

The files hold personal health data. Write them outside the repository and delete them afterwards: nothing
under Tools/SmartWakeReplay is meant to be committed with real data in it.
"""
import argparse
import json
import os
import sqlite3
import sys


def rr_scope(rows, device, lo, hi):
    """SQL fragment + params selecting the R-R the app reads for [lo, hi], as `WhoopStore.rrIntervals` does.

    A WHOOP 5 stores each beat on two transports, 5 (v18 history) and 7 (standard BLE heart rate); the app
    reads ONE per window (the lowest present) and skips `tsSuspect` beats. Exporting every row would hand the
    live detector each beat twice, which `addBeats` turns into a tachogram running at twice the speed.
    Same rule as Tools/SleepBench `ReadOnlyDB.rrQuery`.
    """
    cols = {r[1] for r in rows("PRAGMA table_info(rrInterval)")}
    suspect = " AND (tsSuspect IS NULL OR tsSuspect <> 1)" if "tsSuspect" in cols else ""
    if "srcChannel" not in cols or not rows(
            "SELECT 1 FROM rrInterval WHERE deviceId = ? AND srcChannel IN (5, 7) LIMIT 1", (device,)):
        return suspect, ()
    chosen = rows("SELECT MIN(srcChannel) FROM rrInterval WHERE deviceId = ? AND ts >= ? AND ts <= ? "
                  "AND srcChannel IN (5, 7)" + suspect, (device, lo, hi))[0][0]
    if chosen is None:
        return " AND 0", ()
    return suspect + " AND srcChannel = ?", (chosen,)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("db", help="a COPY of the NOOP database (opened read-only)")
    parser.add_argument("outdir", help="directory for the night_*.csv files (outside the repository)")
    parser.add_argument("--stream-device", help="deviceId of the raw streams (default: the one with most hrSample rows)")
    parser.add_argument("--session-device", help="deviceId of the stored sleep sessions (default: <stream>-noop, else the stream id)")
    parser.add_argument("--min-hours", type=float, default=3.0, help="skip sessions shorter than this (default 3)")
    args = parser.parse_args()

    con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True)

    def rows(sql, params=()):
        return con.execute(sql, params).fetchall()

    streams = rows("SELECT deviceId, COUNT(*) FROM hrSample GROUP BY deviceId ORDER BY 2 DESC")
    if not streams:
        print("no hrSample rows in this database", file=sys.stderr)
        return 1
    print("hrSample devices:", ", ".join(f"{d} ({n})" for d, n in streams))
    stream = args.stream_device or streams[0][0]

    sessions_by_device = dict(rows("SELECT deviceId, COUNT(*) FROM sleepSession GROUP BY deviceId"))
    print("sleepSession devices:", ", ".join(f"{d} ({n})" for d, n in sessions_by_device.items()))
    session_device = args.session_device or (
        stream + "-noop" if (stream + "-noop") in sessions_by_device else stream)
    print(f"streams from {stream!r}, sessions from {session_device!r}")

    os.makedirs(args.outdir, exist_ok=True)
    written = 0
    for start, end, stages_json in rows(
            "SELECT startTs, endTs, stagesJSON FROM sleepSession WHERE deviceId = ? ORDER BY startTs",
            (session_device,)):
        if (end - start) < args.min_hours * 3600:
            continue
        lo, hi = start - 2 * 3600, end + 3600
        hr = rows("SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                  (stream, lo, hi))
        if len(hr) < 3600:
            continue
        rr_extra, rr_params = rr_scope(rows, stream, lo, hi)
        rr = rows("SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? AND ts <= ?" + rr_extra
                  + " ORDER BY ts, ord, rrMs, seq", (stream, lo, hi, *rr_params))
        band = rows("SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                    (stream, lo, hi))
        try:
            stages = json.loads(stages_json or "[]")
        except ValueError:
            stages = []
        path = os.path.join(args.outdir, f"night_{start}.csv")
        with open(path, "w", encoding="utf-8") as out:
            out.write(f"N,{start},{end}\n")
            for segment in stages:
                out.write(f"S,{segment['start']},{segment['end']},{segment['stage']}\n")
            for ts, bpm in hr:
                out.write(f"H,{ts},{bpm}\n")
            for ts, rr_ms in rr:
                out.write(f"R,{ts},{rr_ms}\n")
            for ts, state in band:
                out.write(f"B,{ts},{state}\n")
        written += 1
    print(f"wrote {written} night(s) to {args.outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
