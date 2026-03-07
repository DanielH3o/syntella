#!/usr/bin/env python3
"""Local dev server for the Syntella frontend and local workspace APIs."""

import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("SYNTELLA_DEV_PORT", "3000"))
WORKSPACE = Path(os.environ.get("SYNTELLA_WORKSPACE", os.path.expanduser("~/.openclaw/workspace")))
OPENCLAW_STATE_DIR = Path(
    os.environ.get("OPENCLAW_STATE_DIR", os.path.expanduser("~/.openclaw"))
)
DB_PATH = WORKSPACE / "tasks.db"
REGISTRY = WORKSPACE / "agents" / "registry.json"
FRONTEND_ROOT = Path(__file__).resolve().parent / "templates" / "frontend"
USAGE_SYNC_MAX_EVENTS = int(os.environ.get("SYNTELLA_USAGE_SYNC_MAX_EVENTS", "20000"))
TERMINAL_RUN_STATUSES = {"review", "done", "cancelled", "failed"}

CONTENT_TYPES = {
    ".css": "text/css; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".svg": "image/svg+xml",
}


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat()


def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = get_conn()
    cursor = conn.cursor()
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            description TEXT,
            assignee TEXT,
            status TEXT DEFAULT 'backlog',
            priority TEXT DEFAULT 'medium',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS usage_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_key TEXT NOT NULL UNIQUE,
            agent_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            message_id TEXT,
            ts TEXT NOT NULL,
            provider TEXT,
            model TEXT,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            total_tokens INTEGER DEFAULT 0,
            cost_input REAL DEFAULT 0,
            cost_output REAL DEFAULT 0,
            cost_cache_read REAL DEFAULT 0,
            cost_cache_write REAL DEFAULT 0,
            total_cost REAL DEFAULT 0,
            source_file TEXT NOT NULL,
            task_id INTEGER,
            run_id TEXT,
            raw_json TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS task_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id INTEGER NOT NULL,
            agent_id TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'started',
            started_at TEXT NOT NULL,
            ended_at TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (task_id) REFERENCES tasks(id)
        )
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_usage_events_agent_ts
        ON usage_events (agent_id, ts)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_usage_events_model_ts
        ON usage_events (model, ts)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_task_runs_task_started
        ON task_runs (task_id, started_at DESC)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_task_runs_agent_started
        ON task_runs (agent_id, started_at DESC)
        """
    )
    conn.commit()
    conn.close()


def run_query(query, args=(), fetchall=False, fetchone=False, commit=False):
    conn = get_conn()
    cursor = conn.cursor()
    cursor.execute(query, args)
    result = None
    if fetchall:
        result = [dict(row) for row in cursor.fetchall()]
    elif fetchone or cursor.description:
        row = cursor.fetchone()
        if row:
            result = dict(row)
    if commit:
        conn.commit()
        result = cursor.lastrowid
    conn.close()
    return result


def read_registry():
    try:
        with REGISTRY.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def discover_openclaw_agents():
    registry = read_registry()
    agents_root = OPENCLAW_STATE_DIR / "agents"
    discovered = {}
    if not agents_root.exists():
        return discovered

    for agent_dir in sorted(path for path in agents_root.iterdir() if path.is_dir()):
        agent_id = agent_dir.name
        session_files = sorted((agent_dir / "sessions").glob("*.jsonl")) if (agent_dir / "sessions").exists() else []
        latest_ts = None
        event_count = 0
        if session_files:
            latest_file = max(session_files, key=lambda path: path.stat().st_mtime)
            latest_ts = datetime.fromtimestamp(latest_file.stat().st_mtime, tz=timezone.utc).isoformat()
            event_count = len(session_files)
        registry_meta = registry.get(agent_id, {}) if isinstance(registry, dict) else {}
        discovered[agent_id] = {
            "id": agent_id,
            "role": registry_meta.get("role") or ("Main Orchestrator" if agent_id == "main" else "OpenClaw Agent"),
            "description": registry_meta.get("description") or ("Primary root agent for the local OpenClaw profile." if agent_id == "main" else f"Discovered from local OpenClaw state for `{agent_id}`."),
            "pid": registry_meta.get("pid"),
            "port": registry_meta.get("port"),
            "status": "Running" if latest_ts else "Discovered",
            "latest_activity": latest_ts,
            "session_count": event_count,
        }
    return discovered


def normalize_usage_record(agent_id, source_file, line_no, payload):
    message = payload.get("message") or {}
    usage = message.get("usage")
    if not usage:
        return None
    session_id = source_file.stem
    message_id = payload.get("id") or message.get("id") or f"{session_id}:{line_no}"
    event_key = f"{source_file}:{line_no}:{message_id}"
    cost = usage.get("cost") or {}
    return {
        "event_key": event_key,
        "agent_id": agent_id,
        "session_id": session_id,
        "message_id": message_id,
        "ts": payload.get("timestamp") or utc_now_iso(),
        "provider": message.get("provider", ""),
        "model": message.get("model", ""),
        "input_tokens": int(usage.get("input") or 0),
        "output_tokens": int(usage.get("output") or 0),
        "cache_read_tokens": int(usage.get("cacheRead") or 0),
        "cache_write_tokens": int(usage.get("cacheWrite") or 0),
        "total_tokens": int(usage.get("totalTokens") or 0),
        "cost_input": float(cost.get("input") or 0),
        "cost_output": float(cost.get("output") or 0),
        "cost_cache_read": float(cost.get("cacheRead") or 0),
        "cost_cache_write": float(cost.get("cacheWrite") or 0),
        "total_cost": float(cost.get("total") or 0),
        "source_file": str(source_file),
        "raw_json": json.dumps(payload, ensure_ascii=False),
    }


def sync_usage_events():
    agents_root = OPENCLAW_STATE_DIR / "agents"
    if not agents_root.exists():
        return {"inserted": 0, "scanned_files": 0, "scanned_events": 0}

    conn = get_conn()
    cursor = conn.cursor()
    inserted = 0
    scanned_files = 0
    scanned_events = 0

    session_files = sorted(agents_root.glob("*/sessions/*.jsonl"))
    if USAGE_SYNC_MAX_EVENTS > 0:
        session_files = session_files[-USAGE_SYNC_MAX_EVENTS:]

    for session_file in session_files:
        scanned_files += 1
        try:
            agent_id = session_file.parts[-3]
            with session_file.open("r", encoding="utf-8") as handle:
                for line_no, line in enumerate(handle, start=1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        payload = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    record = normalize_usage_record(agent_id, session_file, line_no, payload)
                    if not record:
                        continue
                    scanned_events += 1
                    cursor.execute(
                        """
                        INSERT OR IGNORE INTO usage_events (
                            event_key, agent_id, session_id, message_id, ts, provider, model,
                            input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                            total_tokens, cost_input, cost_output, cost_cache_read, cost_cache_write,
                            total_cost, source_file, raw_json
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            record["event_key"],
                            record["agent_id"],
                            record["session_id"],
                            record["message_id"],
                            record["ts"],
                            record["provider"],
                            record["model"],
                            record["input_tokens"],
                            record["output_tokens"],
                            record["cache_read_tokens"],
                            record["cache_write_tokens"],
                            record["total_tokens"],
                            record["cost_input"],
                            record["cost_output"],
                            record["cost_cache_read"],
                            record["cost_cache_write"],
                            record["total_cost"],
                            record["source_file"],
                            record["raw_json"],
                        ),
                    )
                    if cursor.rowcount:
                        inserted += 1
        except OSError:
            continue

    conn.commit()
    conn.close()
    return {"inserted": inserted, "scanned_files": scanned_files, "scanned_events": scanned_events}


def build_usage_filters(params):
    clauses = []
    args = []
    agent = params.get("agent", ["all"])[0]
    model = params.get("model", ["all"])[0]
    days = params.get("days", [None])[0]

    if agent and agent != "all":
        clauses.append("agent_id = ?")
        args.append(agent)
    if model and model != "all":
        clauses.append("model = ?")
        args.append(model)
    if days:
        try:
            range_days = max(1, int(days))
            cutoff = (datetime.now(timezone.utc) - timedelta(days=range_days)).isoformat()
            clauses.append("ts >= ?")
            args.append(cutoff)
        except ValueError:
            pass

    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    return where, args


def usage_summary(params):
    where, args = build_usage_filters(params)
    totals = run_query(
        f"""
        SELECT
            COUNT(*) AS event_count,
            COALESCE(SUM(input_tokens), 0) AS input_tokens,
            COALESCE(SUM(output_tokens), 0) AS output_tokens,
            COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
            COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
            COALESCE(SUM(total_tokens), 0) AS total_tokens,
            COALESCE(SUM(total_cost), 0) AS total_cost,
            MIN(ts) AS first_ts,
            MAX(ts) AS last_ts
        FROM usage_events
        {where}
        """,
        tuple(args),
        fetchone=True,
    ) or {}
    by_agent = run_query(
        f"""
        SELECT
            agent_id AS agent,
            COUNT(*) AS event_count,
            COALESCE(SUM(total_tokens), 0) AS total_tokens,
            COALESCE(SUM(total_cost), 0) AS total_cost
        FROM usage_events
        {where}
        GROUP BY agent_id
        ORDER BY total_cost DESC, total_tokens DESC
        """,
        tuple(args),
        fetchall=True,
    ) or []
    by_model = run_query(
        f"""
        SELECT
            model,
            provider,
            COUNT(*) AS event_count,
            COALESCE(SUM(total_tokens), 0) AS total_tokens,
            COALESCE(SUM(total_cost), 0) AS total_cost
        FROM usage_events
        {where}
        GROUP BY provider, model
        ORDER BY total_cost DESC, total_tokens DESC
        """,
        tuple(args),
        fetchall=True,
    ) or []
    return {
        "totals": totals,
        "by_agent": by_agent,
        "by_model": by_model,
        "filters": {
            "agent": params.get("agent", ["all"])[0],
            "model": params.get("model", ["all"])[0],
            "days": params.get("days", ["30"])[0],
        },
    }


def usage_events(params):
    where, args = build_usage_filters(params)
    limit = params.get("limit", ["50"])[0]
    try:
        limit_value = max(1, min(int(limit), 500))
    except ValueError:
        limit_value = 50
    return run_query(
        f"""
        SELECT
            agent_id,
            session_id,
            message_id,
            ts,
            provider,
            model,
            input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            total_tokens,
            total_cost,
            task_id,
            run_id
        FROM usage_events
        {where}
        ORDER BY ts DESC
        LIMIT ?
        """,
        tuple(args + [limit_value]),
        fetchall=True,
    ) or []


def task_run_costs(conn, run_rows):
    costs = {}
    cursor = conn.cursor()
    for row in run_rows:
        end_time = row["ended_at"] or utc_now_iso()
        usage = cursor.execute(
            """
            SELECT
                COALESCE(SUM(total_cost), 0) AS total_cost,
                COALESCE(SUM(total_tokens), 0) AS total_tokens,
                COUNT(*) AS event_count
            FROM usage_events
            WHERE agent_id = ?
              AND ts >= ?
              AND ts <= ?
            """,
            (row["agent_id"], row["started_at"], end_time),
        ).fetchone()
        costs[row["id"]] = {
            "estimated_cost": float(usage["total_cost"] or 0),
            "estimated_tokens": int(usage["total_tokens"] or 0),
            "usage_event_count": int(usage["event_count"] or 0),
        }
    return costs


def task_run_rows(conn, task_id):
    return [
        dict(row)
        for row in conn.execute(
            """
            SELECT id, task_id, agent_id, status, started_at, ended_at, created_at, updated_at
            FROM task_runs
            WHERE task_id = ?
            ORDER BY started_at DESC, id DESC
            """,
            (task_id,),
        ).fetchall()
    ]


def enrich_runs(conn, runs):
    costs = task_run_costs(conn, runs)
    enriched = []
    for run in runs:
        merged = {**run, **costs.get(run["id"], {})}
        enriched.append(merged)
    return enriched


def task_rollup_from_runs(runs):
    if not runs:
        return {
            "estimated_cost": 0.0,
            "estimated_tokens": 0,
            "run_count": 0,
            "open_run": None,
            "latest_run": None,
        }
    open_run = next((run for run in runs if not run.get("ended_at")), None)
    latest_run = runs[0]
    return {
        "estimated_cost": round(sum(run.get("estimated_cost", 0) for run in runs), 8),
        "estimated_tokens": sum(run.get("estimated_tokens", 0) for run in runs),
        "run_count": len(runs),
        "open_run": open_run,
        "latest_run": latest_run,
    }


def costs_by_task(limit=20):
    tasks = fetch_tasks()
    rows = [
        {
            "task_id": task["id"],
            "title": task["title"],
            "assignee": task.get("assignee") or "",
            "status": task.get("status") or "",
            "estimated_cost": task.get("estimated_cost") or 0,
            "estimated_tokens": task.get("estimated_tokens") or 0,
            "run_count": task.get("run_count") or 0,
        }
        for task in tasks
        if (task.get("estimated_cost") or 0) > 0 or (task.get("run_count") or 0) > 0
    ]
    rows.sort(key=lambda row: (row["estimated_cost"], row["estimated_tokens"]), reverse=True)
    return rows[:limit]


def fetch_task_detail(task_id):
    conn = get_conn()
    task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if not task:
        conn.close()
        return None
    runs = enrich_runs(conn, task_run_rows(conn, task_id))
    rollup = task_rollup_from_runs(runs)
    result = dict(task)
    result["estimated_cost"] = rollup["estimated_cost"]
    result["estimated_tokens"] = rollup["estimated_tokens"]
    result["run_count"] = rollup["run_count"]
    result["open_run"] = rollup["open_run"]
    result["latest_run"] = rollup["latest_run"]
    result["runs"] = runs
    conn.close()
    return result


def fetch_tasks():
    conn = get_conn()
    tasks = [dict(row) for row in conn.execute(
        "SELECT * FROM tasks ORDER BY priority DESC, created_at DESC"
    ).fetchall()]
    for task in tasks:
        runs = enrich_runs(conn, task_run_rows(conn, task["id"]))
        rollup = task_rollup_from_runs(runs)
        task["estimated_cost"] = rollup["estimated_cost"]
        task["estimated_tokens"] = rollup["estimated_tokens"]
        task["run_count"] = rollup["run_count"]
        task["open_run"] = rollup["open_run"]
        task["latest_run"] = rollup["latest_run"]
    conn.close()
    return tasks


def backfill_active_task_runs():
    conn = get_conn()
    rows = conn.execute(
        """
        SELECT id, assignee, status, updated_at
        FROM tasks
        WHERE status = 'in_progress'
        """
    ).fetchall()
    conn.close()
    for row in rows:
        ensure_task_run_state(row["id"], row["assignee"], row["status"])


def ensure_task_run_state(task_id, assignee, status):
    assignee = (assignee or "").strip()
    if not assignee:
        return
    conn = get_conn()
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
            conn.close()
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
        conn.close()
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
    conn.close()


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _send_bytes(self, code, body, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self._send_bytes(code, body, "application/json; charset=utf-8")

    def _parse_body(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if size <= 0:
                return {}
            return json.loads(self.rfile.read(size))
        except Exception:
            return {}

    def _serve_file(self, relative_path):
        relative_path = relative_path.lstrip("/")
        file_path = (FRONTEND_ROOT / relative_path).resolve()
        if FRONTEND_ROOT not in file_path.parents and file_path != FRONTEND_ROOT:
            self._send_json(404, {"error": "not_found"})
            return
        if not file_path.exists() or not file_path.is_file():
            self._send_json(404, {"error": "not_found"})
            return
        content_type = CONTENT_TYPES.get(file_path.suffix, "application/octet-stream")
        self._send_bytes(200, file_path.read_bytes(), content_type)

    def _handle_static(self, path):
        route_map = {"/": "index.html", "/admin": "admin.html"}
        target = route_map.get(path, path.lstrip("/"))
        self._serve_file(target)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/health":
            return self._send_json(200, {"ok": True, "service": "syntella-local-dev"})

        if path == "/api/health":
            registry = read_registry()
            return self._send_json(200, {
                "ok": True,
                "service": "syntella-local-dev",
                "uptime_seconds": None,
                "agents_total": len(registry),
            })

        if path in ("/api/agents", "/api/departments"):
            return self._send_json(200, {"ok": True, "agents": discover_openclaw_agents()})

        if path == "/api/tasks":
            try:
                return self._send_json(200, {"ok": True, "tasks": fetch_tasks()})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})

        if path.startswith("/api/tasks/"):
            task_id = path.rsplit("/", 1)[-1]
            if not task_id.isdigit():
                return self._send_json(400, {"error": "Invalid task ID"})
            task = fetch_task_detail(int(task_id))
            if not task:
                return self._send_json(404, {"error": "not_found"})
            return self._send_json(200, {"ok": True, "task": task})

        if path == "/api/usage":
            sync = sync_usage_events()
            return self._send_json(200, {"ok": True, "sync": sync, "events": usage_events(params)})

        if path == "/api/usage/summary":
            sync = sync_usage_events()
            return self._send_json(200, {"ok": True, "sync": sync, **usage_summary(params)})

        if path == "/api/costs/by-task":
            limit = params.get("limit", ["20"])[0]
            try:
                limit_value = max(1, min(int(limit), 100))
            except ValueError:
                limit_value = 20
            return self._send_json(200, {"ok": True, "tasks": costs_by_task(limit_value)})

        self._handle_static(path)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/usage/sync":
            return self._send_json(200, {"ok": True, **sync_usage_events()})

        if path != "/api/tasks":
            return self._send_json(404, {"error": "not_found"})

        body = self._parse_body()
        if not body.get("title"):
            return self._send_json(400, {"error": "Title is required"})

        try:
            task_id = run_query(
                """
                INSERT INTO tasks (title, description, assignee, status, priority)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    body.get("title"),
                    body.get("description", ""),
                    body.get("assignee", ""),
                    body.get("status", "backlog"),
                    body.get("priority", "medium"),
                ),
                commit=True,
            )
            ensure_task_run_state(task_id, body.get("assignee", ""), body.get("status", "backlog"))
            return self._send_json(201, {"ok": True, "task": fetch_task_detail(task_id)})
        except Exception as exc:
            return self._send_json(500, {"ok": False, "error": str(exc)})

    def do_PUT(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/tasks/"):
            return self._send_json(404, {"error": "not_found"})

        task_id = path.rsplit("/", 1)[-1]
        if not task_id.isdigit():
            return self._send_json(400, {"error": "Invalid task ID"})
        task_id_int = int(task_id)
        body = self._parse_body()

        updates = []
        args = []
        for field in ["title", "description", "assignee", "status", "priority"]:
            if field in body:
                updates.append(f"{field} = ?")
                args.append(body[field])
        if not updates:
            return self._send_json(400, {"error": "No valid fields to update"})

        updates.append("updated_at = CURRENT_TIMESTAMP")
        args.append(task_id_int)

        try:
            run_query(
                f"UPDATE tasks SET {', '.join(updates)} WHERE id = ?",
                tuple(args),
                commit=True,
            )
            updated = fetch_task_detail(task_id_int)
            ensure_task_run_state(task_id_int, updated.get("assignee", ""), updated.get("status", "backlog"))
            updated = fetch_task_detail(task_id_int)
            return self._send_json(200, {"ok": True, "task": updated})
        except Exception as exc:
            return self._send_json(500, {"ok": False, "error": str(exc)})

    def do_DELETE(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/tasks/"):
            return self._send_json(404, {"error": "not_found"})
        task_id = path.rsplit("/", 1)[-1]
        if not task_id.isdigit():
            return self._send_json(400, {"error": "Invalid task ID"})
        try:
            run_query("DELETE FROM task_runs WHERE task_id = ?", (int(task_id),), commit=True)
            run_query("DELETE FROM tasks WHERE id = ?", (int(task_id),), commit=True)
            return self._send_json(200, {"ok": True})
        except Exception as exc:
            return self._send_json(500, {"ok": False, "error": str(exc)})


def main():
    init_db()
    sync_usage_events()
    backfill_active_task_runs()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Syntella local dev server listening on http://127.0.0.1:{PORT}", flush=True)
    print(f"Using workspace: {WORKSPACE}", flush=True)
    print(f"Reading OpenClaw state from: {OPENCLAW_STATE_DIR}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down local dev server...", flush=True)
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
