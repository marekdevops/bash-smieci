#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Atomowy generator raportów JSON (<job_id>.json oraz summary.json).
Kompatybilny z Python 2.7 (RHEL 7) oraz Python 3.x bez zewnętrznych bibliotek.
"""
from __future__ import print_function
import argparse
import glob
import io
import json
import os
import sys


def atomic_write_json(target_path, payload):
    parent = os.path.dirname(target_path)
    if not os.path.isdir(parent):
        os.makedirs(parent)
    tmp_path = "%s.tmp.%d" % (target_path, os.getpid())
    data = json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False)
    with io.open(tmp_path, "w", encoding="utf-8") as fh:
        if sys.version_info[0] < 3 and isinstance(data, str):
            data = data.decode("utf-8")
        fh.write(data)
        fh.write(u"\n")
    os.chmod(tmp_path, 0o644)
    os.rename(tmp_path, target_path)


def parse_manifest(manifest_path):
    files = []
    if not manifest_path or not os.path.isfile(manifest_path):
        return files
    with io.open(manifest_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            parts = line.split("|", 3)
            if len(parts) != 4:
                continue
            name, size_str, sha256, status = parts
            try:
                size_bytes = int(size_str)
            except ValueError:
                size_bytes = 0
            files.append({
                "name": name,
                "size_bytes": size_bytes,
                "sha256": sha256,
                "status": status,
            })
    return files


def rebuild_summary(state_dir, generated_at_epoch):
    jobs_dir = os.path.join(state_dir, "jobs")
    summary_jobs = []
    totals = {
        "jobs_total": 0,
        "jobs_ok": 0,
        "jobs_error": 0,
        "files_transferred": 0,
        "files_failed": 0,
        "bytes_transferred": 0,
    }

    for job_file in sorted(glob.glob(os.path.join(jobs_dir, "*.json"))):
        try:
            with io.open(job_file, "r", encoding="utf-8") as fh:
                job = json.load(fh)
        except Exception:
            continue

        totals["jobs_total"] += 1
        if job.get("status") == "OK":
            totals["jobs_ok"] += 1
        else:
            totals["jobs_error"] += 1

        totals["files_transferred"] += int(job.get("files_transferred", 0))
        totals["files_failed"] += int(job.get("files_failed", 0))
        totals["bytes_transferred"] += int(job.get("bytes_transferred", 0))

        summary_jobs.append({
            "job_id": job.get("job_id"),
            "description": job.get("description"),
            "owner": job.get("owner"),
            "protocol": job.get("protocol"),
            "remote_host": job.get("remote_host"),
            "remote_dir": job.get("remote_dir"),
            "status": job.get("status"),
            "exit_code": job.get("exit_code"),
            "started_at": job.get("started_at"),
            "finished_at": job.get("finished_at"),
            "finished_at_epoch": job.get("finished_at_epoch"),
            "duration_sec": job.get("duration_sec"),
            "files_total": job.get("files_total"),
            "files_transferred": job.get("files_transferred"),
            "files_failed": job.get("files_failed"),
            "bytes_transferred": job.get("bytes_transferred"),
            "error_message": job.get("error_message"),
        })

    summary_payload = {
        "generated_at_epoch": generated_at_epoch,
        "totals": totals,
        "jobs": summary_jobs,
    }
    atomic_write_json(os.path.join(state_dir, "summary.json"), summary_payload)


def main():
    parser = argparse.ArgumentParser(description="Generate atomic JSON status reports")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--description", default="")
    parser.add_argument("--owner", required=True)
    parser.add_argument("--protocol", required=True)
    parser.add_argument("--remote-host", required=True)
    parser.add_argument("--remote-dir", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--exit-code", type=int, required=True)
    parser.add_argument("--started-at", required=True)
    parser.add_argument("--finished-at", required=True)
    parser.add_argument("--finished-at-epoch", type=int, required=True)
    parser.add_argument("--duration-sec", type=int, required=True)
    parser.add_argument("--error-message", default="")
    parser.add_argument("--manifest", default="")
    args = parser.parse_args()

    files = parse_manifest(args.manifest)
    files_transferred = sum(1 for f in files if f["status"] == "transferred")
    files_failed = sum(1 for f in files if f["status"] != "transferred")
    bytes_transferred = sum(f["size_bytes"] for f in files if f["status"] == "transferred")

    job_payload = {
        "job_id": args.job_id,
        "description": args.description,
        "owner": args.owner,
        "protocol": args.protocol,
        "remote_host": args.remote_host,
        "remote_dir": args.remote_dir,
        "status": args.status,
        "exit_code": args.exit_code,
        "started_at": args.started_at,
        "finished_at": args.finished_at,
        "finished_at_epoch": args.finished_at_epoch,
        "duration_sec": args.duration_sec,
        "files_total": len(files),
        "files_transferred": files_transferred,
        "files_failed": files_failed,
        "bytes_transferred": bytes_transferred,
        "error_message": args.error_message if args.error_message else None,
        "files": files,
    }

    job_path = os.path.join(args.state_dir, "jobs", "%s.json" % args.job_id)
    atomic_write_json(job_path, job_payload)
    rebuild_summary(args.state_dir, args.finished_at_epoch)


if __name__ == "__main__":
    main()
