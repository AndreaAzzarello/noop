#!/usr/bin/env python3
"""Export the MIT-BIH Polysomnographic Database to the neutral CSVs `sleeppsg --section rrstage` reads.

WFDB is the only reason this step is Python: the format is a bespoke binary one and `wfdb` is the reference
reader. Everything after this (R-R cleaning, ln(RMSSD), ln(LF/HF), the AUC and Cohen's d) runs in Swift
through the app's own estimators, so the figures cannot drift from what the recipe would compute.

    python3 -I slpdb_export.py --slpdb ~/datasets/slpdb-x/mit-bih-polysomnographic-database-1.0.0 --out OUT_DIR

Install the reader in a virtualenv OUTSIDE this repository (it pulls numpy, scipy, pandas, matplotlib, ...):

    python3 -m venv ~/noop-eval/venv-wfdb && ~/noop-eval/venv-wfdb/bin/python -m pip install wfdb

Per record `<id>` this writes two files into OUT_DIR:

    <id>.beats.csv    t_s,symbol            one row per annotated beat; t_s = seconds from record start
    <id>.stages.csv   epoch_start_s,stage,events
                      one row per 30 s epoch. `stage` is the raw first token of the annotation
                      (W, 1, 2, 3, 4, R, or anything else the database carries); `events` is the rest
                      of the annotation (OA, CA, H, X, L, A ... space separated), empty when none.

Nothing is written to the dataset. No file here contains anything about a NOOP wearer.

Attribution (the dataset's licence requires it): Ichimaru Y, Moody GB. Development of the polysomnographic
database on CD-ROM. Psychiatry and Clinical Neurosciences 53(2):175-177 (1999). Goldberger AL et al.
PhysioBank, PhysioToolkit, and PhysioNet. Circulation 101(23):e215-e220 (2000).
"""
import argparse
import csv
import os
import sys

import wfdb

EPOCH_S = 30.0


def read_records(root):
    with open(os.path.join(root, "RECORDS"), encoding="utf-8") as fh:
        return [line.strip() for line in fh if line.strip()]


def export_record(root, rec, out_dir):
    path = os.path.join(root, rec)
    beats = wfdb.rdann(path, "ecg")
    stages = wfdb.rdann(path, "st")
    if beats.fs != stages.fs:
        raise SystemExit(f"{rec}: beat and stage annotations disagree on the sampling rate")
    fs = float(beats.fs)

    with open(os.path.join(out_dir, f"{rec}.beats.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["t_s", "symbol"])
        for sample, symbol in zip(beats.sample, beats.symbol):
            w.writerow([f"{sample / fs:.4f}", symbol])

    n_stage = 0
    with open(os.path.join(out_dir, f"{rec}.stages.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["epoch_start_s", "stage", "events"])
        for sample, note in zip(stages.sample, stages.aux_note):
            # Two records (slp41, slp45) carry a trailing NUL in every note ("W\x00"); `str.split()` does not
            # treat it as whitespace, so it would otherwise leak into the stage token and make every epoch of
            # those records unscored. Any other control character is blanked the same way.
            tokens = "".join(" " if ord(c) < 32 else c for c in note).split()
            if not tokens:
                continue
            # The annotation marks the START of its 30 s epoch (record slp01a: first annotation at sample 1,
            # 240 annotations x 7500 samples = the whole 1 800 000-sample record).
            t = round(sample / fs / EPOCH_S) * EPOCH_S
            w.writerow([f"{t:.0f}", tokens[0], " ".join(tokens[1:])])
            n_stage += 1
    return len(beats.sample), n_stage


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--slpdb", required=True, help="the extracted mit-bih-polysomnographic-database-1.0.0 directory")
    ap.add_argument("--out", required=True, help="output directory (created if missing; keep it outside the repo)")
    args = ap.parse_args()

    root = os.path.expanduser(args.slpdb)
    out_dir = os.path.expanduser(args.out)
    os.makedirs(out_dir, exist_ok=True)
    for rec in read_records(root):
        n_beats, n_stage = export_record(root, rec, out_dir)
        print(f"{rec}: {n_beats} beats, {n_stage} stage epochs", file=sys.stderr)


if __name__ == "__main__":
    main()
