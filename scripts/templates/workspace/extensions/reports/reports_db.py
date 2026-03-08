#!/usr/bin/env python3
import json
import os
import sqlite3
import sys
from pathlib import Path

WORKSPACE = Path(os.environ.get("SYNTELLA_WORKSPACE", os.path.expanduser("~/.openclaw/workspace")))
DB_PATH = WORKSPACE / "tasks.db"


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
        CREATE TABLE IF NOT EXISTS reports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            agent_id TEXT,
            routine_id INTEGER,
            routine_run_id INTEGER,
            report_type TEXT NOT NULL DEFAULT 'general',
            summary TEXT,
            body TEXT,
            status TEXT NOT NULL DEFAULT 'published',
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.commit()


def normalize_report(row):
    if row is None:
        return None
    item = dict(row)
    return {
        "id": item.get("id"),
        "title": item.get("title"),
        "agent_id": item.get("agent_id") or "",
        "routine_id": item.get("routine_id"),
        "routine_run_id": item.get("routine_run_id"),
        "report_type": item.get("report_type") or "general",
        "summary": item.get("summary") or "",
        "body": item.get("body") or "",
        "status": item.get("status") or "published",
        "created_at": item.get("created_at"),
        "routine_name": item.get("routine_name") or "",
    }


def list_reports(payload, mine=False):
    limit = payload.get("limit") or 20
    try:
        limit = max(1, min(int(limit), 100))
    except Exception:
        limit = 20
    agent_id = (payload.get("agent_id") or payload.get("__agent_id") or "").strip()
    conn = get_conn()
    try:
        ensure_schema(conn)
        query = """
            SELECT rep.id, rep.title, rep.agent_id, rep.routine_id, rep.routine_run_id,
                   rep.report_type, rep.summary, rep.body, rep.status, rep.created_at,
                   rut.name AS routine_name
            FROM reports rep
            LEFT JOIN routines rut ON rut.id = rep.routine_id
        """
        params = []
        scope = "all"
        if mine:
            query += " WHERE rep.agent_id = ?"
            params.append(agent_id)
            scope = f"agent={agent_id}"
        query += " ORDER BY rep.created_at DESC, rep.id DESC LIMIT ?"
        params.append(limit)
        rows = conn.execute(query, tuple(params)).fetchall()
        return {"ok": True, "scope": scope, "reports": [normalize_report(row) for row in rows]}
    finally:
        conn.close()


def get_report(payload):
    report_id = payload.get("report_id")
    if not report_id:
        return {"ok": False, "error": "report_id is required for get"}
    conn = get_conn()
    try:
        ensure_schema(conn)
        row = conn.execute(
            """
            SELECT rep.id, rep.title, rep.agent_id, rep.routine_id, rep.routine_run_id,
                   rep.report_type, rep.summary, rep.body, rep.status, rep.created_at,
                   rut.name AS routine_name
            FROM reports rep
            LEFT JOIN routines rut ON rut.id = rep.routine_id
            WHERE rep.id = ?
            """,
            (int(report_id),),
        ).fetchone()
        if row is None:
            return {"ok": False, "error": f"Report {report_id} not found"}
        return {"ok": True, "report": normalize_report(row)}
    finally:
        conn.close()


def create_report(payload):
    title = (payload.get("title") or "").strip()
    summary = (payload.get("summary") or "").strip()
    body = (payload.get("body") or "").strip()
    if not title:
        return {"ok": False, "error": "title is required for create"}
    if not summary and not body:
        return {"ok": False, "error": "summary or body is required for create"}
    agent_id = (payload.get("agent_id") or payload.get("__agent_id") or "").strip()
    report_type = (payload.get("report_type") or "general").strip() or "general"
    status = (payload.get("status") or "published").strip() or "published"
    routine_id = payload.get("routine_id")
    routine_run_id = payload.get("routine_run_id")
    conn = get_conn()
    try:
        ensure_schema(conn)
        cursor = conn.execute(
            """
            INSERT INTO reports (title, agent_id, routine_id, routine_run_id, report_type, summary, body, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                title,
                agent_id,
                routine_id,
                routine_run_id,
                report_type,
                summary,
                body,
                status,
                utc_now_iso(),
            ),
        )
        conn.commit()
        return get_report({"report_id": cursor.lastrowid})
    finally:
        conn.close()


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError:
        print(json.dumps({"ok": False, "error": "invalid JSON input"}))
        return

    action = (payload.get("action") or "").strip()
    if action == "list_recent":
        result = list_reports(payload, mine=False)
    elif action == "list_mine":
        result = list_reports(payload, mine=True)
    elif action == "get":
        result = get_report(payload)
    elif action == "create":
        result = create_report(payload)
    else:
        result = {"ok": False, "error": f"unsupported action: {action}"}

    print(json.dumps(result))


if __name__ == "__main__":
    main()
