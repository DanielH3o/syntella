#!/usr/bin/env python3
import json
import os
import sqlite3
import sys
from pathlib import Path

WORKSPACE = Path(os.environ.get("SYNTELLA_WORKSPACE", os.path.expanduser("~/.openclaw/workspace")))
DB_PATH = WORKSPACE / "tasks.db"
VALID_STATUSES = {"backlog", "in_progress", "review", "done"}
VALID_PRIORITIES = {"low", "medium", "high"}
TERMINAL_RUN_STATUSES = {"review", "done", "cancelled", "failed"}


def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def utc_now_iso():
    import datetime as _dt
    return _dt.datetime.now(_dt.timezone.utc).isoformat()


def ensure_schema(conn):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS task_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER NOT NULL,
            agent_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'started',
            started_at TEXT NOT NULL,
            ended_at TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.commit()


def ensure_task_run_state(conn, task_id, assignee, status):
    assignee = (assignee or "").strip()
    if not assignee:
        return
    ensure_schema(conn)
    cursor = conn.cursor()
    open_run = cursor.execute(
        """
        SELECT id, task_id, agent_id, status, started_at, ended_at
        FROM task_runs
        WHERE task_id = ? AND ended_at IS NULL
        ORDER BY started_at DESC, id DESC
        LIMIT 1
        """,
        (task_id,),
    ).fetchone()
    now = utc_now_iso()

    if status == "in_progress":
        if open_run and open_run["agent_id"] == assignee:
            return
        if open_run:
            cursor.execute(
                """
                UPDATE task_runs
                SET status = ?, ended_at = ?, updated_at = CURRENT_TIMESTAMP
                WHERE id = ?
                """,
                ("reassigned", now, open_run["id"]),
            )
        cursor.execute(
            """
            INSERT INTO task_runs (task_id, agent_id, status, started_at)
            VALUES (?, ?, ?, ?)
            """,
            (task_id, assignee, "started", now),
        )
        conn.commit()
        return

    if open_run:
        final_status = status if status in TERMINAL_RUN_STATUSES else "stopped"
        cursor.execute(
            """
            UPDATE task_runs
            SET status = ?, ended_at = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            (final_status, now, open_run["id"]),
        )
        conn.commit()


def normalize_task(row):
    if row is None:
        return None
    item = dict(row)
    return {
        "id": item.get("id"),
        "title": item.get("title"),
        "description": item.get("description") or "",
        "assignee": item.get("assignee") or "",
        "status": item.get("status") or "backlog",
        "priority": item.get("priority") or "medium",
        "created_at": item.get("created_at"),
        "updated_at": item.get("updated_at"),
    }


def list_tasks(payload, mine=False):
    limit = payload.get("limit") or 20
    try:
        limit = max(1, min(int(limit), 100))
    except Exception:
        limit = 20
    assignee = (payload.get("assignee") or payload.get("agent_id") or payload.get("__agent_id") or "").strip()
    conn = get_conn()
    try:
        if mine:
            rows = conn.execute(
                """
                SELECT id, title, description, assignee, status, priority, created_at, updated_at
                FROM tasks
                WHERE assignee = ?
                ORDER BY
                  CASE status
                    WHEN 'in_progress' THEN 1
                    WHEN 'review' THEN 2
                    WHEN 'backlog' THEN 3
                    WHEN 'done' THEN 4
                    ELSE 5
                  END,
                  updated_at DESC,
                  id DESC
                LIMIT ?
                """,
                (assignee, limit),
            ).fetchall()
            return {"ok": True, "scope": f"assignee={assignee}", "tasks": [normalize_task(row) for row in rows]}
        rows = conn.execute(
            """
            SELECT id, title, description, assignee, status, priority, created_at, updated_at
            FROM tasks
            ORDER BY updated_at DESC, id DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return {"ok": True, "scope": "all", "tasks": [normalize_task(row) for row in rows]}
    finally:
        conn.close()


def get_task(payload):
    task_id = payload.get("task_id")
    if not task_id:
        return {"ok": False, "error": "task_id is required for get"}
    conn = get_conn()
    try:
        row = conn.execute(
            """
            SELECT id, title, description, assignee, status, priority, created_at, updated_at
            FROM tasks
            WHERE id = ?
            """,
            (int(task_id),),
        ).fetchone()
        if row is None:
            return {"ok": False, "error": f"Task {task_id} not found"}
        return {"ok": True, "task": normalize_task(row)}
    finally:
        conn.close()


def create_task(payload):
    title = (payload.get("title") or "").strip()
    if not title:
        return {"ok": False, "error": "title is required for create"}
    description = (payload.get("description") or "").strip()
    assignee = (payload.get("assignee") or payload.get("agent_id") or "").strip()
    priority = (payload.get("priority") or "medium").strip().lower()
    status = (payload.get("status") or "backlog").strip().lower()
    if priority not in VALID_PRIORITIES:
        return {"ok": False, "error": f"priority must be one of {sorted(VALID_PRIORITIES)}"}
    if status not in VALID_STATUSES:
        return {"ok": False, "error": f"status must be one of {sorted(VALID_STATUSES)}"}
    conn = get_conn()
    try:
        ensure_schema(conn)
        cursor = conn.execute(
            """
            INSERT INTO tasks (title, description, assignee, status, priority)
            VALUES (?, ?, ?, ?, ?)
            """,
            (title, description, assignee, status, priority),
        )
        ensure_task_run_state(conn, cursor.lastrowid, assignee, status)
        conn.commit()
        return get_task({"task_id": cursor.lastrowid})
    finally:
        conn.close()


def update_task(payload, field):
    task_id = payload.get("task_id")
    if not task_id:
        return {"ok": False, "error": "task_id is required"}
    value = payload.get(field)
    if field == "status":
        value = (value or "").strip().lower()
        if value not in VALID_STATUSES:
            return {"ok": False, "error": f"status must be one of {sorted(VALID_STATUSES)}"}
    else:
        value = (value or "").strip()
        if not value:
            return {"ok": False, "error": f"{field} is required"}
    conn = get_conn()
    try:
        ensure_schema(conn)
        current = conn.execute(
            "SELECT assignee, status FROM tasks WHERE id = ?",
            (int(task_id),),
        ).fetchone()
        if current is None:
            return {"ok": False, "error": f"Task {task_id} not found"}
        cursor = conn.execute(
            f"""
            UPDATE tasks
            SET {field} = ?, updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            (value, int(task_id)),
        )
        assignee = current["assignee"]
        status = value if field == "status" else current["status"]
        ensure_task_run_state(conn, int(task_id), assignee, status)
        conn.commit()
        return get_task({"task_id": task_id})
    finally:
        conn.close()


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        print(json.dumps({"ok": False, "error": "invalid JSON input"}))
        return

    action = (payload.get("action") or "").strip()
    if action == "list":
        result = list_tasks(payload, mine=False)
    elif action == "list_mine":
        result = list_tasks(payload, mine=True)
    elif action == "get":
        result = get_task(payload)
    elif action == "create":
        result = create_task(payload)
    elif action == "update_status":
        result = update_task(payload, "status")
    elif action == "update_description":
        result = update_task(payload, "description")
    else:
        result = {"ok": False, "error": f"Unknown action: {action}"}

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
