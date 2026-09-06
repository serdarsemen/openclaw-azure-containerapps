#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import shutil
import sqlite3
import uuid
from pathlib import Path


def backup_state(data_dir: Path, keep: int) -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup_dir = data_dir / "backups" / f"pre-update-{timestamp}-{uuid.uuid4().hex}"
    backup_dir.mkdir(parents=True, mode=0o700)

    config = data_dir / "openclaw.json"
    if config.exists():
        shutil.copy2(config, backup_dir / "openclaw.json")

    database = data_dir / "state" / "openclaw.sqlite"
    if database.exists():
        source = sqlite3.connect(database, timeout=60)
        destination = sqlite3.connect(backup_dir / "openclaw.sqlite")
        try:
            source.backup(destination, pages=4096, sleep=0.05)
        finally:
            destination.close()
            source.close()

    manifest = {
        "createdAt": timestamp,
        "source": str(data_dir),
        "files": sorted(path.name for path in backup_dir.iterdir()),
    }
    (backup_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    backups = sorted(
        (path for path in (data_dir / "backups").glob("pre-update-*") if path.is_dir()),
        key=lambda path: path.name,
        reverse=True,
    )
    for stale in backups[max(1, keep) :]:
        shutil.rmtree(stale)
    return backup_dir


def maintain_database(data_dir: Path, retention_days: int, compact: bool) -> dict:
    database = data_dir / "state" / "openclaw.sqlite"
    if not database.exists():
        return {"database": "missing", "deletedTaskRuns": 0}

    cutoff_ms = int(
        (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=retention_days)).timestamp() * 1000
    )
    connection = sqlite3.connect(database, timeout=60)
    deleted = 0
    try:
        connection.execute("PRAGMA busy_timeout=60000")
        table_exists = connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='task_runs'"
        ).fetchone()
        if table_exists:
            while True:
                cursor = connection.execute(
                    """
                    DELETE FROM task_runs
                    WHERE task_id IN (
                      SELECT task_id
                      FROM task_runs
                      WHERE ended_at IS NOT NULL AND ended_at < ?
                      LIMIT 5000
                    )
                    """,
                    (cutoff_ms,),
                )
                connection.commit()
                deleted += cursor.rowcount
                if cursor.rowcount < 5000:
                    break
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        if compact:
            connection.execute("VACUUM")
    finally:
        connection.close()
    return {"database": str(database), "deletedTaskRuns": deleted, "compacted": compact}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--backup", action="store_true")
    parser.add_argument("--maintain", action="store_true")
    parser.add_argument("--compact", action="store_true")
    parser.add_argument("--keep-backups", type=int, default=5)
    parser.add_argument("--retention-days", type=int, default=30)
    args = parser.parse_args()

    data_dir = Path(args.data_dir).expanduser().resolve()
    result = {}
    if args.backup:
        result["backup"] = str(backup_state(data_dir, args.keep_backups))
    if args.maintain:
        result["maintenance"] = maintain_database(
            data_dir, max(1, args.retention_days), args.compact
        )
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
