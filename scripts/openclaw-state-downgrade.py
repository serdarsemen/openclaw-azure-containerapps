#!/usr/bin/env python3
import argparse
import json
import shutil
import sqlite3
import time
from pathlib import Path


def columns(connection: sqlite3.Connection, table: str) -> list[str]:
    return [row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')]


def replace_common_rows(
    target: sqlite3.Connection, source: sqlite3.Connection, table: str
) -> int:
    target_columns = columns(target, table)
    source_columns = set(columns(source, table))
    shared = [name for name in target_columns if name in source_columns]
    if not shared:
        return 0
    quoted = ", ".join(f'"{name}"' for name in shared)
    placeholders = ", ".join("?" for _ in shared)
    rows = source.execute(f'SELECT {quoted} FROM "{table}"')
    target.execute(f'DELETE FROM "{table}"')
    count = 0
    for batch_start in range(0, 1_000_000_000, 2000):
        batch = rows.fetchmany(2000)
        if not batch:
            break
        target.executemany(
            f'INSERT OR REPLACE INTO "{table}" ({quoted}) VALUES ({placeholders})',
            batch,
        )
        count += len(batch)
    return count


def cron_row(store_key: str, job_json: str, state_json: str, metadata: dict) -> dict:
    job = json.loads(job_json)
    state = {
        **(job.get("state") or {}),
        **json.loads(state_json or "{}"),
    }
    schedule = job.get("schedule") or {}
    payload = job.get("payload") or {}
    delivery = job.get("delivery") or {}
    failure_delivery = job.get("failureDelivery") or {}
    failure_alert = job.get("failureAlert") or {}
    completion = delivery.get("completion") or {}
    return {
        "store_key": store_key,
        "job_id": job["id"],
        "name": job.get("name") or job["id"],
        "description": job.get("description"),
        "enabled": int(bool(job.get("enabled", True))),
        "delete_after_run": job.get("deleteAfterRun"),
        "created_at_ms": job.get("createdAtMs") or int(time.time() * 1000),
        "agent_id": job.get("agentId"),
        "session_key": job.get("sessionKey"),
        "schedule_kind": schedule.get("kind") or "cron",
        "schedule_expr": schedule.get("expr"),
        "schedule_tz": schedule.get("tz"),
        "every_ms": schedule.get("everyMs"),
        "anchor_ms": schedule.get("anchorMs"),
        "at": schedule.get("at"),
        "stagger_ms": schedule.get("staggerMs"),
        "session_target": job.get("sessionTarget") or "isolated",
        "wake_mode": job.get("wakeMode") or "now",
        "payload_kind": payload.get("kind") or "agentTurn",
        "payload_message": (
            payload.get("text")
            if payload.get("kind") == "systemEvent"
            else json.dumps(
                {
                    key: value
                    for key, value in payload.items()
                    if key not in ("kind", "timeoutSeconds")
                },
                separators=(",", ":"),
            )
            if payload.get("kind") == "command"
            else payload.get("message")
        ),
        "payload_model": payload.get("model"),
        "payload_fallbacks_json": json.dumps(payload.get("fallbacks"))
        if payload.get("fallbacks") is not None
        else None,
        "payload_thinking": payload.get("thinking"),
        "payload_timeout_seconds": payload.get("timeoutSeconds"),
        "payload_allow_unsafe_external_content": payload.get(
            "allowUnsafeExternalContent"
        ),
        "payload_external_content_source_json": json.dumps(
            payload.get("externalContentSource")
        )
        if payload.get("externalContentSource") is not None
        else None,
        "payload_light_context": payload.get("lightContext"),
        "payload_tools_allow_json": json.dumps(payload.get("toolsAllow"))
        if payload.get("toolsAllow") is not None
        else None,
        "delivery_mode": delivery.get("mode"),
        "delivery_channel": delivery.get("channel"),
        "delivery_to": delivery.get("to"),
        "delivery_thread_id": delivery.get("threadId"),
        "delivery_account_id": delivery.get("accountId"),
        "delivery_best_effort": delivery.get("bestEffort"),
        "failure_delivery_mode": failure_delivery.get("mode"),
        "failure_delivery_channel": failure_delivery.get("channel"),
        "failure_delivery_to": failure_delivery.get("to"),
        "failure_delivery_account_id": failure_delivery.get("accountId"),
        "failure_alert_disabled": failure_alert.get("disabled"),
        "failure_alert_after": failure_alert.get("after"),
        "failure_alert_channel": failure_alert.get("channel"),
        "failure_alert_to": failure_alert.get("to"),
        "failure_alert_cooldown_ms": failure_alert.get("cooldownMs"),
        "failure_alert_include_skipped": failure_alert.get("includeSkipped"),
        "failure_alert_mode": failure_alert.get("mode"),
        "failure_alert_account_id": failure_alert.get("accountId"),
        "next_run_at_ms": state.get("nextRunAtMs"),
        "running_at_ms": state.get("runningAtMs"),
        "last_run_at_ms": state.get("lastRunAtMs"),
        "last_run_status": state.get("lastRunStatus") or state.get("lastStatus"),
        "last_error": state.get("lastError"),
        "last_duration_ms": state.get("lastDurationMs"),
        "consecutive_errors": state.get("consecutiveErrors"),
        "consecutive_skipped": state.get("consecutiveSkipped"),
        "schedule_error_count": state.get("scheduleErrorCount"),
        "last_delivery_status": state.get("lastDeliveryStatus"),
        "last_delivery_error": state.get("lastDeliveryError"),
        "last_delivered": state.get("lastDelivered"),
        "last_failure_alert_at_ms": state.get("lastFailureAlertAtMs"),
        "job_json": job_json,
        "state_json": state_json or "{}",
        "runtime_updated_at_ms": metadata.get("runtime_updated_at_ms"),
        "schedule_identity": metadata.get("schedule_identity"),
        "sort_order": metadata.get("sort_order") or 0,
        "updated_at": metadata.get("updated_at") or int(time.time() * 1000),
        "delivery_completion_mode": completion.get("mode"),
        "delivery_completion_to": completion.get("to"),
        "payload_tools_allow_is_default": payload.get("toolsAllowIsDefault"),
    }


def replace_cron_jobs(
    target: sqlite3.Connection, source: sqlite3.Connection
) -> int:
    target_columns = columns(target, "cron_jobs")
    quoted = ", ".join(f'"{name}"' for name in target_columns)
    placeholders = ", ".join("?" for _ in target_columns)
    target.execute("DELETE FROM cron_jobs")
    count = 0
    for row in source.execute(
        """
        SELECT store_key, job_json, state_json, runtime_updated_at_ms,
               schedule_identity, sort_order, updated_at
        FROM cron_jobs
        ORDER BY store_key, job_id
        """
    ):
        metadata = {
            "runtime_updated_at_ms": row[3],
            "schedule_identity": row[4],
            "sort_order": row[5],
            "updated_at": row[6],
        }
        mapped = cron_row(row[0], row[1], row[2], metadata)
        target.execute(
            f"INSERT INTO cron_jobs ({quoted}) VALUES ({placeholders})",
            [mapped.get(name) for name in target_columns],
        )
        count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compatible", required=True)
    parser.add_argument("--current", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    compatible = Path(args.compatible)
    current = Path(args.current)
    output = Path(args.output)
    shutil.copy2(compatible, output)

    target = sqlite3.connect(output)
    source = sqlite3.connect(f"file:{current}?mode=ro", uri=True)
    result = {}
    try:
        target.execute("PRAGMA foreign_keys=OFF")
        target.execute("BEGIN")
        result["cron_jobs"] = replace_cron_jobs(target, source)
        for table in (
            "task_runs",
            "delivery_queue_entries",
            "plugin_state_entries",
            "flow_runs",
        ):
            result[table] = replace_common_rows(target, source, table)
        target.execute("COMMIT")
        target.execute("PRAGMA user_version=1")
        target.execute(
            """
            UPDATE schema_meta
            SET schema_version=1, app_version=NULL, updated_at=?
            WHERE meta_key='primary' AND role='global'
            """,
            (int(time.time() * 1000),),
        )
        target.commit()
        target.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        integrity = target.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"integrity_check failed: {integrity}")
    except Exception:
        target.rollback()
        raise
    finally:
        source.close()
        target.close()
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
