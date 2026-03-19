#!/usr/bin/env python3
"""Local dev server for the Syntella frontend and local workspace APIs."""

import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from zoneinfo import ZoneInfo
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("SYNTELLA_DEV_PORT", "3000"))
WORKSPACE = Path(os.environ.get("SYNTELLA_WORKSPACE", os.path.expanduser("~/.openclaw/workspace")))
OPENCLAW_STATE_DIR = Path(
    os.environ.get("OPENCLAW_STATE_DIR", os.path.expanduser("~/.openclaw"))
)
OPENCLAW_CONFIG = OPENCLAW_STATE_DIR / "openclaw.json"
OPENCLAW_CRON_JOBS = OPENCLAW_STATE_DIR / "cron" / "jobs.json"
OPERATOR_BRIDGE_ENV = Path("/etc/openclaw/operator-bridge.env")
OPERATOR_BRIDGE_URL = os.environ.get("SYNTELLA_OPERATOR_BRIDGE_URL", "http://127.0.0.1:8787")
DB_PATH = WORKSPACE / "tasks.db"
REGISTRY = WORKSPACE / "agents" / "registry.json"
FRONTEND_ROOT = Path(__file__).resolve().parent / "templates" / "frontend"
OPENCLAW_GATEWAY_PORT = int(os.environ.get("OPENCLAW_GATEWAY_PORT", "18789"))
OPENCLAW_GATEWAY_LOG = OPENCLAW_STATE_DIR / "logs" / "gateway.log"
USAGE_SYNC_MAX_EVENTS = int(os.environ.get("SYNTELLA_USAGE_SYNC_MAX_EVENTS", "20000"))
TERMINAL_RUN_STATUSES = {"review", "done", "cancelled", "failed"}
INTERNAL_MODEL_IDS = {"delivery-mirror", "gateway-injected"}
VALID_TASK_STATUSES = {"backlog", "todo", "in_progress", "review", "done"}
CORE_TOOL_DEFS = [
    {
        "tool": "tasks",
        "plugin": "syntella-tasks",
        "label": "Tasks",
        "extension_dir": "syntella-tasks",
        "system": None,
        "core": True,
    },
    {
        "tool": "reports",
        "plugin": "syntella-reports",
        "label": "Reports",
        "extension_dir": "syntella-reports",
        "system": None,
        "core": True,
    },
]
INTEGRATION_TOOL_DEFS = {
    "ghost": {
        "tool": "ghost",
        "plugin": "syntella-ghost",
        "label": "Ghost CMS",
        "extension_dir": "syntella-ghost",
    },
    "google_search_console": {
        "tool": "search_console",
        "plugin": "syntella-search-console",
        "label": "Google Search Console",
        "extension_dir": "syntella-search-console",
    },
    "google_analytics": {
        "tool": "analytics",
        "plugin": "syntella-analytics",
        "label": "Google Analytics",
        "extension_dir": "syntella-analytics",
    },
}

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


def normalize_task_status(status):
    value = str(status or "backlog").strip().lower() or "backlog"
    return value if value in VALID_TASK_STATUSES else "backlog"


def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def ensure_column(cursor, table_name, column_name, definition):
    columns = {
        row[1]
        for row in cursor.execute(f"PRAGMA table_info({table_name})").fetchall()
    }
    if column_name not in columns:
        cursor.execute(f"ALTER TABLE {table_name} ADD COLUMN {column_name} {definition}")


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
        CREATE TABLE IF NOT EXISTS model_overrides (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider TEXT NOT NULL,
            model_id TEXT NOT NULL,
            display_name TEXT,
            enabled INTEGER,
            input_cost REAL,
            output_cost REAL,
            cache_read_cost REAL,
            cache_write_cost REAL,
            context_window INTEGER,
            max_tokens INTEGER,
            reasoning INTEGER,
            input_modalities TEXT,
            notes TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(provider, model_id)
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS routines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            schedule_type TEXT NOT NULL DEFAULT 'daily',
            schedule_value TEXT NOT NULL DEFAULT '',
            schedule_time TEXT,
            schedule_day INTEGER,
            schedule_interval_hours INTEGER,
            schedule_date TEXT,
            schedule_summary TEXT NOT NULL DEFAULT '',
            cron_expression TEXT,
            cron_job_id TEXT,
            timezone TEXT NOT NULL DEFAULT 'UTC',
            prompt TEXT NOT NULL DEFAULT '',
            output_mode TEXT NOT NULL DEFAULT 'report_if_needed',
            report_channel_id TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            last_run_at TEXT,
            next_run_at TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    ensure_column(cursor, "routines", "schedule_time", "TEXT")
    ensure_column(cursor, "routines", "schedule_day", "INTEGER")
    ensure_column(cursor, "routines", "schedule_interval_hours", "INTEGER")
    ensure_column(cursor, "routines", "schedule_date", "TEXT")
    ensure_column(cursor, "routines", "cron_expression", "TEXT")
    ensure_column(cursor, "routines", "cron_job_id", "TEXT")
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS routine_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            routine_id INTEGER NOT NULL,
            status TEXT NOT NULL DEFAULT 'completed',
            started_at TEXT NOT NULL,
            ended_at TEXT,
            output_summary TEXT,
            task_id INTEGER,
            estimated_cost REAL DEFAULT 0,
            estimated_tokens INTEGER DEFAULT 0,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (routine_id) REFERENCES routines(id)
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS reports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            agent_id TEXT,
            routine_id INTEGER,
            routine_run_id INTEGER,
            report_type TEXT NOT NULL DEFAULT 'routine',
            summary TEXT NOT NULL DEFAULT '',
            body TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'published',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (routine_id) REFERENCES routines(id),
            FOREIGN KEY (routine_run_id) REFERENCES routine_runs(id)
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS integrations (
            system TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 0,
            allowed_specialties TEXT NOT NULL DEFAULT '[]',
            config_json TEXT NOT NULL DEFAULT '{}',
            secrets_json TEXT NOT NULL DEFAULT '{}',
            notes TEXT NOT NULL DEFAULT '',
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
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
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_model_overrides_provider_model
        ON model_overrides (provider, model_id)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_routines_agent_enabled
        ON routines (agent_id, enabled)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_routine_runs_routine_started
        ON routine_runs (routine_id, started_at DESC)
        """
    )
    cursor.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_reports_created_at
        ON reports (created_at DESC)
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


def write_registry(data):
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    with REGISTRY.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def read_openclaw_config():
    try:
        with OPENCLAW_CONFIG.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_openclaw_config(data):
    OPENCLAW_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    with OPENCLAW_CONFIG.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def gateway_is_listening():
    try:
        with socket.create_connection(("127.0.0.1", OPENCLAW_GATEWAY_PORT), timeout=1):
            return True
    except OSError:
        return False


def read_operator_bridge_token():
    token = os.environ.get("OPERATOR_BRIDGE_TOKEN", "").strip()
    if token:
        return token
    try:
        for line in OPERATOR_BRIDGE_ENV.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.strip() == "OPERATOR_BRIDGE_TOKEN":
                return value.strip().strip('"').strip("'")
    except OSError:
        return ""
    return ""


def bridge_request(path, method="GET", payload=None, timeout=30):
    token = read_operator_bridge_token()
    if not token:
        raise RuntimeError("Operator bridge token is not configured")
    url = f"{OPERATOR_BRIDGE_URL.rstrip('/')}{path}"
    data = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = Request(url, data=data, headers=headers, method=method)
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8")
            return response.status, json.loads(body) if body else {}
    except HTTPError as exc:
        body = exc.read().decode("utf-8")
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            payload = {"error": "bridge_error", "detail": body}
        return exc.code, payload
    except URLError as exc:
        raise RuntimeError(f"Could not reach operator bridge: {exc.reason}") from exc


def is_internal_model(model_id):
    return (model_id or "").strip() in INTERNAL_MODEL_IDS


def discover_openclaw_agents():
    registry = read_registry()
    discovered = {}
    agent_sources = {}
    integrations = list_integrations()
    config = read_openclaw_config()
    runtime_tools = {}
    agents_cfg = config.get("agents")
    entries = agents_cfg.get("list") if isinstance(agents_cfg, dict) else None
    if isinstance(entries, list):
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            agent_id = (entry.get("id") or "").strip()
            tools_cfg = entry.get("tools")
            allow = tools_cfg.get("allow") if isinstance(tools_cfg, dict) else None
            if agent_id and isinstance(allow, list):
                runtime_tools[agent_id] = [str(item).strip() for item in allow if str(item).strip()]
    agents_root = OPENCLAW_STATE_DIR / "agents"

    if agents_root.exists():
        for agent_dir in sorted(path for path in agents_root.iterdir() if path.is_dir()):
            agent_sources[agent_dir.name] = {
                "agent_id": agent_dir.name,
                "session_dir": agent_dir / "sessions",
                "registry_meta": registry.get(agent_dir.name, {}) if isinstance(registry, dict) else {},
            }

    if isinstance(registry, dict):
        for agent_id, registry_meta in registry.items():
            if not isinstance(registry_meta, dict):
                registry_meta = {}
            if agent_id in agent_sources:
                agent_sources[agent_id]["registry_meta"] = registry_meta
                continue
            child_home = Path(str(registry_meta.get("home") or "")).expanduser()
            child_session_dir = child_home / "agents" / "main" / "sessions"
            agent_sources[agent_id] = {
                "agent_id": agent_id,
                "session_dir": child_session_dir,
                "registry_meta": registry_meta,
            }

    for agent_id in sorted(agent_sources):
        source = agent_sources[agent_id]
        session_dir = source["session_dir"]
        registry_meta = source["registry_meta"]
        session_files = sorted(session_dir.glob("*.jsonl")) if session_dir.exists() else []
        latest_ts = None
        event_count = 0
        if session_files:
            latest_file = max(session_files, key=lambda path: path.stat().st_mtime)
            latest_ts = datetime.fromtimestamp(latest_file.stat().st_mtime, tz=timezone.utc).isoformat()
            event_count = len(session_files)
        pid = registry_meta.get("pid")
        is_running = False
        if isinstance(pid, int) and pid > 0:
            try:
                os.kill(pid, 0)
                is_running = True
            except OSError:
                is_running = False
        discovered[agent_id] = {
            "id": agent_id,
            "role": registry_meta.get("role") or ("Main Orchestrator" if agent_id == "main" else "OpenClaw Agent"),
            "description": registry_meta.get("description") or registry_meta.get("personality") or ("Primary root agent for the local OpenClaw profile." if agent_id == "main" else f"Discovered from local OpenClaw state for `{agent_id}`."),
            "pid": pid,
            "port": registry_meta.get("port"),
            "channel_id": registry_meta.get("channel_id"),
            "monthly_budget": parse_optional_number(registry_meta.get("monthly_budget"), float),
            "specialty": registry_meta.get("specialty"),
            "tools": registry_meta.get("tools") if isinstance(registry_meta.get("tools"), list) else runtime_tools.get(agent_id) or derive_default_agent_tools(registry_meta.get("specialty"), integrations),
            "available_tools": available_tool_descriptors(integrations),
            "status": "Running" if is_running or latest_ts else "Discovered",
            "latest_activity": latest_ts,
            "session_count": event_count,
        }
    return discovered


def update_agent_metadata(agent_id, body):
    agent_key = (agent_id or "").strip()
    if not agent_key:
        raise ValueError("Agent ID is required.")

    registry = read_registry()
    discovered = discover_openclaw_agents()
    discovered_agent = discovered.get(agent_key)
    current = registry.get(agent_key)
    if not isinstance(current, dict) and not discovered_agent:
        raise ValueError("Agent not found.")

    updated = dict(current) if isinstance(current, dict) else {}
    if discovered_agent:
        updated.setdefault("role", discovered_agent.get("role"))
        updated.setdefault("description", discovered_agent.get("description"))
        updated.setdefault("pid", discovered_agent.get("pid"))
        updated.setdefault("port", discovered_agent.get("port"))
        updated.setdefault("channel_id", discovered_agent.get("channel_id"))
        updated.setdefault("specialty", discovered_agent.get("specialty"))
    if "role" in body:
        updated["role"] = (body.get("role") or "").strip()
    if "description" in body:
        updated["description"] = (body.get("description") or "").strip()
    if "channel_id" in body:
        channel_id = (body.get("channel_id") or "").strip()
        if channel_id and not channel_id.isdigit():
            raise ValueError("channel_id must be numeric")
        updated["channel_id"] = channel_id or None
    if "monthly_budget" in body:
        monthly_budget = parse_optional_number(body.get("monthly_budget"), float)
        if monthly_budget is not None and monthly_budget < 0:
            raise ValueError("monthly_budget must be zero or greater")
        updated["monthly_budget"] = monthly_budget
    if "specialty" in body:
        specialty = (body.get("specialty") or "").strip().lower() or None
        if specialty not in {None, "seo"}:
            raise ValueError("specialty must be empty or seo")
        updated["specialty"] = specialty
    runtime_changed = False
    if "tools" in body:
        requested_tools = body.get("tools")
        if not isinstance(requested_tools, list):
            raise ValueError("tools must be a list")
        allowed_tools = available_tool_names()
        normalized_tools = [item["tool"] for item in CORE_TOOL_DEFS]
        for item in requested_tools:
            tool_name = str(item or "").strip()
            if not tool_name:
                continue
            if tool_name not in allowed_tools:
                raise ValueError(f"Unknown tool: {tool_name}")
            normalized_tools.append(tool_name)
        updated["tools"] = list(dict.fromkeys(normalized_tools))
        runtime_changed = True
    if "specialty" in body:
        runtime_changed = True

    registry[agent_key] = updated
    write_registry(registry)
    if runtime_changed:
        sync_agent_runtime_tools(agent_key, updated)
    return discover_openclaw_agents().get(agent_key), runtime_changed


def parse_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def parse_optional_number(value, cast_type=float):
    if value in (None, ""):
        return None
    try:
        return cast_type(value)
    except (TypeError, ValueError):
        return None


def parse_schedule_time(value, default="09:00"):
    raw = (value or default).strip()
    match = re.fullmatch(r"(\d{1,2}):(\d{2})", raw)
    if not match:
        raise ValueError("Enter a valid schedule time in HH:MM format.")
    hour = int(match.group(1))
    minute = int(match.group(2))
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        raise ValueError("Enter a valid schedule time in HH:MM format.")
    return f"{hour:02d}:{minute:02d}", hour, minute


def compile_routine_schedule(body):
    schedule_type = (body.get("schedule_type") or "daily").strip() or "daily"
    timezone_name = (body.get("timezone") or "UTC").strip() or "UTC"
    schedule_day = parse_optional_number(body.get("schedule_day"), int)
    schedule_interval_hours = parse_optional_number(body.get("schedule_interval_hours"), int)
    schedule_date = (body.get("schedule_date") or "").strip()
    custom_cron = (body.get("cron_expression") or "").strip()
    schedule_time, hour, minute = parse_schedule_time(body.get("schedule_time"))

    if schedule_type == "daily":
        return {
            "schedule_type": schedule_type,
            "schedule_time": schedule_time,
            "schedule_day": None,
            "schedule_interval_hours": None,
            "schedule_date": None,
            "schedule_value": schedule_time,
            "schedule_summary": f"Runs daily at {schedule_time} {timezone_name}",
            "cron_expression": f"{minute} {hour} * * *",
        }
    if schedule_type == "weekdays":
        return {
            "schedule_type": schedule_type,
            "schedule_time": schedule_time,
            "schedule_day": None,
            "schedule_interval_hours": None,
            "schedule_date": None,
            "schedule_value": schedule_time,
            "schedule_summary": f"Runs weekdays at {schedule_time} {timezone_name}",
            "cron_expression": f"{minute} {hour} * * 1-5",
        }
    if schedule_type == "weekly":
        if schedule_day is None or schedule_day not in {0, 1, 2, 3, 4, 5, 6}:
            raise ValueError("Weekly routines need a valid weekday.")
        day_name = {
            0: "Sunday",
            1: "Monday",
            2: "Tuesday",
            3: "Wednesday",
            4: "Thursday",
            5: "Friday",
            6: "Saturday",
        }[schedule_day]
        return {
            "schedule_type": schedule_type,
            "schedule_time": schedule_time,
            "schedule_day": schedule_day,
            "schedule_interval_hours": None,
            "schedule_date": None,
            "schedule_value": f"{schedule_day}@{schedule_time}",
            "schedule_summary": f"Runs every {day_name} at {schedule_time} {timezone_name}",
            "cron_expression": f"{minute} {hour} * * {schedule_day}",
        }
    if schedule_type == "hourly":
        if schedule_interval_hours is None or schedule_interval_hours < 1 or schedule_interval_hours > 24:
            raise ValueError("Hourly routines must run every 1 to 24 hours.")
        return {
            "schedule_type": schedule_type,
            "schedule_time": None,
            "schedule_day": None,
            "schedule_interval_hours": schedule_interval_hours,
            "schedule_date": None,
            "schedule_value": str(schedule_interval_hours),
            "schedule_summary": f"Runs every {schedule_interval_hours} hour{'s' if schedule_interval_hours != 1 else ''}",
            "cron_expression": f"0 */{schedule_interval_hours} * * *",
        }
    if schedule_type == "date":
        if not schedule_date:
            raise ValueError("Date routines need a run date.")
        try:
            scheduled_at = datetime.fromisoformat(f"{schedule_date}T{schedule_time}").replace(
                tzinfo=ZoneInfo(timezone_name)
            )
        except Exception as exc:
            raise ValueError("Date routines need a valid date and time.") from exc
        return {
            "schedule_type": schedule_type,
            "schedule_time": schedule_time,
            "schedule_day": None,
            "schedule_interval_hours": None,
            "schedule_date": schedule_date,
            "schedule_value": f"{schedule_date}@{schedule_time}",
            "schedule_summary": f"Runs once on {schedule_date} at {schedule_time} {timezone_name}",
            "cron_expression": scheduled_at.astimezone(timezone.utc).isoformat(),
        }
    if schedule_type == "custom":
        if not custom_cron:
            raise ValueError("Custom routines need a cron expression.")
        return {
            "schedule_type": schedule_type,
            "schedule_time": None,
            "schedule_day": None,
            "schedule_interval_hours": None,
            "schedule_date": None,
            "schedule_value": custom_cron,
            "schedule_summary": f"Custom cron ({custom_cron}) in {timezone_name}",
            "cron_expression": custom_cron,
        }
    raise ValueError("Unsupported schedule type.")


def run_openclaw_command(args):
    result = subprocess.run(
        ["openclaw", *args],
        capture_output=True,
        text=True,
        timeout=20,
        env=os.environ.copy(),
    )
    if result.returncode != 0:
        stderr = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(stderr or "OpenClaw cron command failed")
    return (result.stdout or "").strip()


def restart_openclaw_gateway(reason="runtime config update"):
    env = os.environ.copy()
    env["PATH"] = f"{Path.home() / '.npm-global' / 'bin'}:{env.get('PATH', '')}"
    OPENCLAW_GATEWAY_LOG.parent.mkdir(parents=True, exist_ok=True)

    details = {
        "ok": False,
        "reason": reason,
        "port": OPENCLAW_GATEWAY_PORT,
        "log_file": str(OPENCLAW_GATEWAY_LOG),
    }

    try:
        stop_result = subprocess.run(
            ["openclaw", "gateway", "stop"],
            capture_output=True,
            text=True,
            timeout=20,
            env=env,
        )
        details["stop_output"] = (stop_result.stdout or stop_result.stderr or "").strip()
    except Exception as exc:
        details["stop_output"] = str(exc)

    try:
        pkill_result = subprocess.run(
            ["pkill", "-f", "openclaw gateway"],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
        )
        details["pkill_output"] = (pkill_result.stdout or pkill_result.stderr or "").strip()
    except Exception as exc:
        details["pkill_output"] = str(exc)

    time.sleep(1)

    for lock_path in list(OPENCLAW_STATE_DIR.rglob("gateway.*.lock")):
        try:
            lock_path.unlink()
        except OSError:
            pass

    try:
        for lock_path in Path("/tmp").rglob("gateway.*.lock"):
            try:
                lock_path.unlink()
            except OSError:
                pass
    except OSError:
        pass

    try:
        log_handle = OPENCLAW_GATEWAY_LOG.open("a", encoding="utf-8")
        process = subprocess.Popen(
            [
                "bash",
                "-lc",
                f'exec openclaw gateway --port {OPENCLAW_GATEWAY_PORT}',
            ],
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        log_handle.close()
    except Exception as exc:
        details["error"] = f"Failed to start gateway: {exc}"
        return details

    details["pid"] = process.pid

    deadline = time.time() + 30
    while time.time() < deadline:
        if gateway_is_listening():
            details["ok"] = True
            return details
        if process.poll() is not None:
            break
        time.sleep(1)

    details["exit_code"] = process.poll()
    details["error"] = "Gateway did not become ready within 30 seconds."
    return details


def read_openclaw_cron_jobs():
    if not OPENCLAW_CRON_JOBS.exists():
        return []
    try:
        payload = json.loads(OPENCLAW_CRON_JOBS.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        jobs = payload.get("jobs")
        if isinstance(jobs, list):
            return [item for item in jobs if isinstance(item, dict)]
    return []


def routine_cron_job_name(routine_id, routine_name):
    return f"Syntella Routine #{routine_id}: {routine_name}"


def build_routine_cron_message(routine):
    lines = [
        f"Run the routine \"{routine['name']}\".",
        f"Assigned agent: {routine['agent_id']}.",
        routine.get("prompt") or "No explicit routine prompt was configured.",
        "Use the reports tool for durable output.",
    ]
    output_mode = routine.get("output_mode") or "report_if_needed"
    if output_mode == "report_only":
        lines.append("Create a durable report. Do not create a task unless explicitly instructed.")
    elif output_mode == "report_if_needed":
        lines.append("Create a durable report if there is something meaningful to report.")
    elif output_mode == "report_and_task_if_needed":
        lines.append("Create a durable report and create a task if follow-up work is needed.")
    report_channel_id = routine.get("report_channel_id")
    if report_channel_id:
        lines.append(f"If you send a short Discord summary, use report channel {report_channel_id}.")
    return "\n".join(line for line in lines if line)


def sync_routine_cron_job(routine):
    if not routine:
        return routine
    routine_id = int(routine["id"])
    job_name = routine_cron_job_name(routine_id, routine["name"])
    cron_expression = routine.get("cron_expression") or ""
    timezone_name = routine.get("timezone") or "UTC"
    agent_id = routine.get("agent_id") or ""
    message = build_routine_cron_message(routine)
    existing_job_id = (routine.get("cron_job_id") or "").strip()

    if not cron_expression:
        raise RuntimeError("Routine is missing a compiled cron expression.")

    if existing_job_id:
        args = [
            "cron", "edit", existing_job_id,
            "--name", job_name,
            "--tz", timezone_name,
            "--session", "isolated",
            "--agent", agent_id,
            "--message", message,
        ]
        if routine.get("schedule_type") == "date":
            args.extend(["--at", cron_expression, "--delete-after-run"])
        else:
            args.extend(["--cron", cron_expression])
        run_openclaw_command(args)
    else:
        args = [
            "cron", "add",
            "--name", job_name,
            "--tz", timezone_name,
            "--session", "isolated",
            "--agent", agent_id,
            "--message", message,
        ]
        if routine.get("schedule_type") == "date":
            args.extend(["--at", cron_expression, "--delete-after-run"])
        else:
            args.extend(["--cron", cron_expression])
        run_openclaw_command(args)

    jobs = read_openclaw_cron_jobs()
    matched = next(
        (
            job for job in jobs
            if str(job.get("id") or "") == existing_job_id
            or job.get("name") == job_name
        ),
        None,
    )
    cron_job_id = str((matched or {}).get("id") or existing_job_id or "")
    next_run_at = (matched or {}).get("nextRunAt") or (matched or {}).get("next_run_at")

    if cron_job_id:
        if routine.get("enabled"):
            try:
                run_openclaw_command(["cron", "enable", cron_job_id])
            except RuntimeError:
                pass
        else:
            try:
                run_openclaw_command(["cron", "disable", cron_job_id])
            except RuntimeError:
                pass

    run_query(
        """
        UPDATE routines
        SET cron_job_id = ?, next_run_at = ?, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
        """,
        (cron_job_id or None, next_run_at, routine_id),
        commit=True,
    )
    return fetch_routine_detail(routine_id)


def normalize_modalities(value):
    if isinstance(value, list):
        return [str(item).strip() for item in value if str(item).strip()]
    if isinstance(value, str):
        return [item.strip() for item in value.split(",") if item.strip()]
    return []


def load_openclaw_model_catalog():
    catalog = {}
    payload = read_openclaw_config()
    models = payload.get("models") if isinstance(payload, dict) else None
    providers = models.get("providers") if isinstance(models, dict) else None
    if not isinstance(providers, dict):
        return catalog

    for provider_name, provider_meta in providers.items():
        provider_models = provider_meta.get("models") or []
        if not isinstance(provider_models, list):
            continue
        for model in provider_models:
            if not isinstance(model, dict):
                continue
            model_id = (model.get("id") or "").strip()
            if not model_id:
                continue
            cost = model.get("cost") or {}
            modalities = model.get("input") or []
            catalog[(provider_name, model_id)] = {
                "provider": provider_name,
                "model_id": model_id,
                "display_name": model.get("name") or model_id,
                "enabled": True,
                "provider_base_url": provider_meta.get("baseUrl") or "",
                "provider_api_adapter": provider_meta.get("api") or "",
                "provider_has_api_key": bool(provider_meta.get("apiKey")),
                "reasoning": bool(model.get("reasoning")),
                "input_modalities": [str(item) for item in modalities if item],
                "context_window": int(model.get("contextWindow") or 0) or None,
                "max_tokens": int(model.get("maxTokens") or 0) or None,
                "cost_input": float(cost.get("input") or 0),
                "cost_output": float(cost.get("output") or 0),
                "cost_cache_read": float(cost.get("cacheRead") or 0),
                "cost_cache_write": float(cost.get("cacheWrite") or 0),
                "source": "openclaw",
                "sources": [str(OPENCLAW_CONFIG)],
                "observed": False,
            }
    return catalog


def load_model_overrides():
    rows = run_query(
        """
        SELECT
            provider,
            model_id,
            display_name,
            enabled,
            input_cost,
            output_cost,
            cache_read_cost,
            cache_write_cost,
            context_window,
            max_tokens,
            reasoning,
            input_modalities,
            notes,
            updated_at
        FROM model_overrides
        ORDER BY provider, model_id
        """,
        fetchall=True,
    ) or []
    overrides = {}
    for row in rows:
        key = (row["provider"], row["model_id"])
        overrides[key] = {
            "provider": row["provider"],
            "model_id": row["model_id"],
            "display_name": row.get("display_name"),
            "enabled": None if row.get("enabled") is None else bool(row.get("enabled")),
            "cost_input": row.get("input_cost"),
            "cost_output": row.get("output_cost"),
            "cost_cache_read": row.get("cache_read_cost"),
            "cost_cache_write": row.get("cache_write_cost"),
            "context_window": row.get("context_window"),
            "max_tokens": row.get("max_tokens"),
            "reasoning": None if row.get("reasoning") is None else bool(row.get("reasoning")),
            "input_modalities": json.loads(row["input_modalities"]) if row.get("input_modalities") else None,
            "notes": row.get("notes") or "",
            "updated_at": row.get("updated_at"),
        }
    return overrides


def apply_model_to_openclaw_config(body):
    provider = (body.get("provider") or "").strip()
    model_id = (body.get("model_id") or "").strip()
    if not provider or not model_id:
        raise ValueError("provider and model_id are required")

    config = read_openclaw_config()
    models_cfg = config.setdefault("models", {})
    providers = models_cfg.setdefault("providers", {})
    provider_cfg = providers.setdefault(provider, {})
    provider_models = provider_cfg.setdefault("models", [])
    if not isinstance(provider_models, list):
        provider_models = []
        provider_cfg["models"] = provider_models

    base_url = (body.get("provider_base_url") or "").strip()
    api_adapter = (body.get("provider_api_adapter") or "").strip()
    api_key = body.get("provider_api_key")
    if base_url:
        provider_cfg["baseUrl"] = base_url
    if api_adapter:
        provider_cfg["api"] = api_adapter
    if isinstance(api_key, str) and api_key.strip():
        provider_cfg["apiKey"] = api_key.strip()

    input_modalities = normalize_modalities(body.get("input_modalities"))
    model_entry = {
        "id": model_id,
        "name": (body.get("display_name") or "").strip() or model_id,
        "reasoning": parse_bool(body.get("reasoning")),
        "input": input_modalities,
        "cost": {
            "input": float(body.get("cost_input") or 0),
            "output": float(body.get("cost_output") or 0),
            "cacheRead": float(body.get("cost_cache_read") or 0),
            "cacheWrite": float(body.get("cost_cache_write") or 0),
        },
        "contextWindow": parse_optional_number(body.get("context_window"), int),
        "maxTokens": parse_optional_number(body.get("max_tokens"), int),
    }
    model_entry = {key: value for key, value in model_entry.items() if value not in (None, []) or key in {"input", "cost"}}

    replaced = False
    for index, existing in enumerate(provider_models):
        if isinstance(existing, dict) and (existing.get("id") or "").strip() == model_id:
            provider_models[index] = model_entry
            replaced = True
            break
    if not replaced:
        provider_models.append(model_entry)

    write_openclaw_config(config)

def observed_model_usage():
    placeholders = ",".join("?" for _ in INTERNAL_MODEL_IDS)
    rows = run_query(
        f"""
        SELECT
            provider,
            model,
            COUNT(*) AS event_count,
            COALESCE(SUM(input_tokens), 0) AS input_tokens,
            COALESCE(SUM(output_tokens), 0) AS output_tokens,
            COALESCE(SUM(cache_read_tokens), 0) AS cache_read_tokens,
            COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
            COALESCE(SUM(cost_input), 0) AS cost_input,
            COALESCE(SUM(cost_output), 0) AS cost_output,
            COALESCE(SUM(cost_cache_read), 0) AS cost_cache_read,
            COALESCE(SUM(cost_cache_write), 0) AS cost_cache_write,
            COALESCE(SUM(total_tokens), 0) AS total_tokens,
            COALESCE(SUM(total_cost), 0) AS total_cost,
            MAX(ts) AS last_seen
        FROM usage_events
        WHERE model IS NOT NULL
          AND TRIM(model) != ''
          AND model NOT IN ({placeholders})
        GROUP BY provider, model
        ORDER BY total_cost DESC, total_tokens DESC
        """,
        tuple(sorted(INTERNAL_MODEL_IDS)),
        fetchall=True,
    ) or []
    usage = {}
    for row in rows:
        input_tokens = int(row.get("input_tokens") or 0)
        output_tokens = int(row.get("output_tokens") or 0)
        cache_read_tokens = int(row.get("cache_read_tokens") or 0)
        cache_write_tokens = int(row.get("cache_write_tokens") or 0)
        cost_input = float(row.get("cost_input") or 0)
        cost_output = float(row.get("cost_output") or 0)
        cost_cache_read = float(row.get("cost_cache_read") or 0)
        cost_cache_write = float(row.get("cost_cache_write") or 0)
        usage[(row.get("provider") or "", row["model"])] = {
            "provider": row.get("provider") or "",
            "model_id": row["model"],
            "event_count": int(row.get("event_count") or 0),
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cache_read_tokens": cache_read_tokens,
            "cache_write_tokens": cache_write_tokens,
            "cost_input": cost_input,
            "cost_output": cost_output,
            "cost_cache_read": cost_cache_read,
            "cost_cache_write": cost_cache_write,
            "derived_cost_input": (cost_input / input_tokens * 1_000_000) if input_tokens and cost_input > 0 else 0.0,
            "derived_cost_output": (cost_output / output_tokens * 1_000_000) if output_tokens and cost_output > 0 else 0.0,
            "derived_cost_cache_read": (cost_cache_read / cache_read_tokens * 1_000_000) if cache_read_tokens and cost_cache_read > 0 else 0.0,
            "derived_cost_cache_write": (cost_cache_write / cache_write_tokens * 1_000_000) if cache_write_tokens and cost_cache_write > 0 else 0.0,
            "total_tokens": int(row.get("total_tokens") or 0),
            "total_cost": float(row.get("total_cost") or 0),
            "last_seen": row.get("last_seen"),
        }
    return usage


def list_models():
    catalog = load_openclaw_model_catalog()
    overrides = load_model_overrides()
    usage = observed_model_usage()
    keys = set(catalog) | set(overrides) | set(usage)
    models = []

    for provider, model_id in sorted(keys):
        if is_internal_model(model_id):
            continue
        base = catalog.get((provider, model_id), {
            "provider": provider,
            "model_id": model_id,
            "display_name": model_id,
            "enabled": True,
            "provider_base_url": "",
            "provider_api_adapter": "",
            "provider_has_api_key": False,
            "reasoning": False,
            "input_modalities": [],
            "context_window": None,
            "max_tokens": None,
            "cost_input": 0.0,
            "cost_output": 0.0,
            "cost_cache_read": 0.0,
            "cost_cache_write": 0.0,
            "source": "observed",
            "sources": [],
            "observed": True,
        })
        override = overrides.get((provider, model_id), {})
        seen = usage.get((provider, model_id), {})
        catalog_has_pricing = any(
            float(base.get(field) or 0) > 0
            for field in ("cost_input", "cost_output", "cost_cache_read", "cost_cache_write")
        )
        observed_has_pricing = any(
            float(seen.get(field) or 0) > 0
            for field in ("derived_cost_input", "derived_cost_output", "derived_cost_cache_read", "derived_cost_cache_write")
        )
        base_cost_input = base.get("cost_input") if catalog_has_pricing else float(seen.get("derived_cost_input") or 0)
        base_cost_output = base.get("cost_output") if catalog_has_pricing else float(seen.get("derived_cost_output") or 0)
        base_cost_cache_read = base.get("cost_cache_read") if catalog_has_pricing else float(seen.get("derived_cost_cache_read") or 0)
        base_cost_cache_write = base.get("cost_cache_write") if catalog_has_pricing else float(seen.get("derived_cost_cache_write") or 0)
        effective = {
            "provider": provider,
            "model_id": model_id,
            "display_name": override.get("display_name") or base.get("display_name") or model_id,
            "enabled": base.get("enabled", True) if override.get("enabled") is None else bool(override.get("enabled")),
            "provider_base_url": base.get("provider_base_url") or "",
            "provider_api_adapter": base.get("provider_api_adapter") or "",
            "provider_has_api_key": bool(base.get("provider_has_api_key")),
            "reasoning": base.get("reasoning") if override.get("reasoning") is None else bool(override.get("reasoning")),
            "input_modalities": override.get("input_modalities") or base.get("input_modalities") or [],
            "context_window": override.get("context_window") or base.get("context_window"),
            "max_tokens": override.get("max_tokens") or base.get("max_tokens"),
            "cost_input": base_cost_input if override.get("cost_input") is None else float(override.get("cost_input")),
            "cost_output": base_cost_output if override.get("cost_output") is None else float(override.get("cost_output")),
            "cost_cache_read": base_cost_cache_read if override.get("cost_cache_read") is None else float(override.get("cost_cache_read")),
            "cost_cache_write": base_cost_cache_write if override.get("cost_cache_write") is None else float(override.get("cost_cache_write")),
            "source": "custom" if not catalog.get((provider, model_id)) else base.get("source", "openclaw"),
            "sources": base.get("sources", []),
            "observed": bool(seen),
            "usage_event_count": int(seen.get("event_count") or 0),
            "observed_tokens": int(seen.get("total_tokens") or 0),
            "observed_cost": float(seen.get("total_cost") or 0),
            "observed_cost_input": float(seen.get("cost_input") or 0),
            "observed_cost_output": float(seen.get("cost_output") or 0),
            "observed_cost_cache_read": float(seen.get("cost_cache_read") or 0),
            "observed_cost_cache_write": float(seen.get("cost_cache_write") or 0),
            "observed_input_tokens": int(seen.get("input_tokens") or 0),
            "observed_output_tokens": int(seen.get("output_tokens") or 0),
            "observed_cache_read_tokens": int(seen.get("cache_read_tokens") or 0),
            "observed_cache_write_tokens": int(seen.get("cache_write_tokens") or 0),
            "last_seen": seen.get("last_seen"),
            "has_override": bool(override),
            "notes": override.get("notes") or "",
            "pricing_source": "override" if any(
                override.get(field) is not None
                for field in ("cost_input", "cost_output", "cost_cache_read", "cost_cache_write")
            ) else ("openclaw" if catalog_has_pricing else "observed" if observed_has_pricing else ("openclaw" if catalog.get((provider, model_id)) else "observed")),
        }
        effective["pricing_complete"] = any(
            float(effective.get(field) or 0) > 0
            for field in ("cost_input", "cost_output", "cost_cache_read", "cost_cache_write")
        )
        models.append(effective)

    return models


def upsert_model_override(body):
    provider = (body.get("provider") or "").strip()
    model_id = (body.get("model_id") or "").strip()
    if not provider or not model_id:
        raise ValueError("provider and model_id are required")

    display_name = (body.get("display_name") or "").strip() or None
    enabled = body.get("enabled")
    notes = (body.get("notes") or "").strip()
    input_modalities = normalize_modalities(body.get("input_modalities"))

    run_query(
        """
        INSERT INTO model_overrides (
            provider,
            model_id,
            display_name,
            enabled,
            input_cost,
            output_cost,
            cache_read_cost,
            cache_write_cost,
            context_window,
            max_tokens,
            reasoning,
            input_modalities,
            notes,
            updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(provider, model_id) DO UPDATE SET
            display_name = excluded.display_name,
            enabled = excluded.enabled,
            input_cost = excluded.input_cost,
            output_cost = excluded.output_cost,
            cache_read_cost = excluded.cache_read_cost,
            cache_write_cost = excluded.cache_write_cost,
            context_window = excluded.context_window,
            max_tokens = excluded.max_tokens,
            reasoning = excluded.reasoning,
            input_modalities = excluded.input_modalities,
            notes = excluded.notes,
            updated_at = CURRENT_TIMESTAMP
        """,
        (
            provider,
            model_id,
            display_name,
            None if enabled is None else int(parse_bool(enabled)),
            parse_optional_number(body.get("cost_input")),
            parse_optional_number(body.get("cost_output")),
            parse_optional_number(body.get("cost_cache_read")),
            parse_optional_number(body.get("cost_cache_write")),
            parse_optional_number(body.get("context_window"), int),
            parse_optional_number(body.get("max_tokens"), int),
            None if body.get("reasoning") is None else int(parse_bool(body.get("reasoning"))),
            json.dumps(input_modalities or []),
            notes,
        ),
        commit=True,
    )


def delete_model_override(provider, model_id):
    run_query(
        "DELETE FROM model_overrides WHERE provider = ? AND model_id = ?",
        (provider, model_id),
        commit=True,
    )


INTEGRATION_DEFAULTS = {
    "ghost": {
        "display_name": "Ghost CMS",
        "description": "Create and update drafts for the Asima and Wonderful blogs.",
        "config_fields": [
            {"key": "asima_admin_url", "label": "Asima Admin API URL", "type": "text", "placeholder": "https://asima.co.uk/ghost/api/admin"},
            {"key": "wonderful_admin_url", "label": "Wonderful Admin API URL", "type": "text", "placeholder": "https://wonderful.co.uk/ghost/api/admin"},
        ],
        "secret_fields": [
            {"key": "asima_admin_key", "label": "Asima Admin API Key", "type": "password"},
            {"key": "wonderful_admin_key", "label": "Wonderful Admin API Key", "type": "password"},
        ],
    },
    "google_search_console": {
        "display_name": "Google Search Console",
        "description": "Read search query and indexing signals for both sites.",
        "config_fields": [
            {"key": "asima_property", "label": "Asima Property", "type": "text", "placeholder": "sc-domain:asima.co.uk"},
            {"key": "wonderful_property", "label": "Wonderful Property", "type": "text", "placeholder": "sc-domain:wonderful.co.uk"},
        ],
        "secret_fields": [
            {"key": "service_account_json", "label": "Service Account JSON", "type": "textarea"},
        ],
    },
    "google_analytics": {
        "display_name": "Google Analytics",
        "description": "Read landing-page, engagement, and conversion signals for both sites.",
        "config_fields": [
            {"key": "asima_property_id", "label": "Asima Property ID", "type": "text", "placeholder": "123456789"},
            {"key": "wonderful_property_id", "label": "Wonderful Property ID", "type": "text", "placeholder": "987654321"},
        ],
        "secret_fields": [
            {"key": "service_account_json", "label": "Service Account JSON", "type": "textarea"},
        ],
    },
}


def load_integrations():
    rows = run_query(
        """
        SELECT system, display_name, enabled, allowed_specialties, config_json, secrets_json, notes, updated_at
        FROM integrations
        ORDER BY display_name ASC
        """,
        fetchall=True,
    ) or []
    by_system = {}
    for row in rows:
        try:
            config = json.loads(row.get("config_json") or "{}")
        except json.JSONDecodeError:
            config = {}
        try:
            secrets = json.loads(row.get("secrets_json") or "{}")
        except json.JSONDecodeError:
            secrets = {}
        try:
            allowed_specialties = json.loads(row.get("allowed_specialties") or "[]")
        except json.JSONDecodeError:
            allowed_specialties = []
        by_system[row["system"]] = {
            "system": row["system"],
            "display_name": row["display_name"],
            "enabled": bool(row.get("enabled")),
            "allowed_specialties": allowed_specialties if isinstance(allowed_specialties, list) else [],
            "config": config if isinstance(config, dict) else {},
            "secrets": secrets if isinstance(secrets, dict) else {},
            "notes": row.get("notes") or "",
            "updated_at": row.get("updated_at"),
        }
    return by_system


def list_integrations(include_secrets=False):
    stored = load_integrations()
    integrations = []
    for system, defaults in INTEGRATION_DEFAULTS.items():
        current = stored.get(system, {})
        config = current.get("config", {})
        secrets = current.get("secrets", {})
        integration = {
            "system": system,
            "display_name": current.get("display_name") or defaults["display_name"],
            "description": defaults["description"],
            "enabled": bool(current.get("enabled")),
            "allowed_specialties": current.get("allowed_specialties") or [],
            "config": config,
            "config_fields": defaults["config_fields"],
            "secret_fields": [
                {**field, "configured": bool((secrets.get(field["key"]) or "").strip())}
                for field in defaults["secret_fields"]
            ],
            "notes": current.get("notes") or "",
            "configured": any(bool(str(value).strip()) for value in config.values()) or any(bool((secrets.get(field["key"]) or "").strip()) for field in defaults["secret_fields"]),
            "updated_at": current.get("updated_at"),
        }
        if include_secrets:
            integration["secrets"] = secrets
        integrations.append(integration)
    return integrations


def available_tool_descriptors(integrations=None):
    integration_index = {
        item["system"]: item
        for item in (integrations if integrations is not None else list_integrations())
    }
    descriptors = [dict(item) for item in CORE_TOOL_DEFS]
    for system, meta in INTEGRATION_TOOL_DEFS.items():
        integration = integration_index.get(system, {})
        descriptors.append({
            **meta,
            "system": system,
            "core": False,
            "enabled": bool(integration.get("enabled")),
            "allowed_specialties": integration.get("allowed_specialties") or [],
            "configured": bool(integration.get("configured")),
        })
    return descriptors


def available_tool_names(integrations=None):
    return {item["tool"] for item in available_tool_descriptors(integrations)}


def derive_default_agent_tools(specialty=None, integrations=None):
    normalized_specialty = (specialty or "").strip().lower()
    tool_names = [item["tool"] for item in CORE_TOOL_DEFS]
    for item in available_tool_descriptors(integrations):
        if item.get("core"):
            continue
        if not item.get("enabled"):
            continue
        allowed_specialties = item.get("allowed_specialties") or []
        if allowed_specialties and normalized_specialty not in allowed_specialties:
            continue
        tool_names.append(item["tool"])
    return list(dict.fromkeys(tool_names))


def build_integration_plugin_config(system, integration):
    config = dict(integration.get("config") or {})
    secrets = dict(integration.get("secrets") or {})
    if system == "ghost":
        return {
            "asimaAdminUrl": config.get("asima_admin_url", ""),
            "asimaAdminKey": secrets.get("asima_admin_key", ""),
            "wonderfulAdminUrl": config.get("wonderful_admin_url", ""),
            "wonderfulAdminKey": secrets.get("wonderful_admin_key", ""),
        }
    if system == "google_search_console":
        return {
            "asimaProperty": config.get("asima_property", ""),
            "wonderfulProperty": config.get("wonderful_property", ""),
            "serviceAccountJson": secrets.get("service_account_json", ""),
        }
    if system == "google_analytics":
        return {
            "asimaPropertyId": config.get("asima_property_id", ""),
            "wonderfulPropertyId": config.get("wonderful_property_id", ""),
            "serviceAccountJson": secrets.get("service_account_json", ""),
        }
    return {}


def sync_integrations_to_openclaw_config(integrations=None):
    integration_list = integrations if integrations is not None else list_integrations(include_secrets=True)
    config = read_openclaw_config()
    tools_cfg = config.setdefault("tools", {})
    tool_allow = tools_cfg.get("allow")
    if not isinstance(tool_allow, list):
        tool_allow = []

    plugins = config.setdefault("plugins", {})
    load = plugins.get("load")
    if not isinstance(load, dict):
        load = {}
    paths = load.get("paths")
    if not isinstance(paths, list):
        paths = []

    plugin_allow = plugins.get("allow")
    if not isinstance(plugin_allow, list):
        plugin_allow = []
    entries = plugins.get("entries")
    if not isinstance(entries, dict):
        entries = {}

    descriptors = available_tool_descriptors(integration_list)
    by_system = {item["system"]: item for item in integration_list}
    template_root = OPENCLAW_STATE_DIR / "workspace" / "templates" / "extensions"

    for item in descriptors:
        extension_path = str(template_root / item["extension_dir"])
        if extension_path not in paths:
            paths.append(extension_path)
        if item["plugin"] not in plugin_allow:
            plugin_allow.append(item["plugin"])
        if item["tool"] not in tool_allow:
            tool_allow.append(item["tool"])

        entry = entries.get(item["plugin"])
        if not isinstance(entry, dict):
            entry = {}
        if item.get("core"):
            entry["enabled"] = True
        else:
            integration = by_system.get(item["system"], {})
            entry["enabled"] = bool(integration.get("enabled"))
            entry["config"] = build_integration_plugin_config(item["system"], integration)
        entries[item["plugin"]] = entry

    load["paths"] = paths
    plugins["load"] = load
    plugins["allow"] = plugin_allow
    plugins["entries"] = entries
    tools_cfg["allow"] = tool_allow
    config["tools"] = tools_cfg
    config["plugins"] = plugins
    write_openclaw_config(config)


def sync_agent_runtime_tools(agent_id, agent_meta, integrations=None):
    config = read_openclaw_config()
    agents_cfg = config.get("agents")
    entries = agents_cfg.get("list") if isinstance(agents_cfg, dict) else None
    if not isinstance(entries, list):
        return False

    target_entry = None
    for entry in entries:
        if isinstance(entry, dict) and entry.get("id") == agent_id:
            target_entry = entry
            break
    if target_entry is None:
        return False

    tools_cfg = target_entry.get("tools")
    if not isinstance(tools_cfg, dict):
        tools_cfg = {}

    explicit_tools = agent_meta.get("tools")
    if isinstance(explicit_tools, list) and explicit_tools:
        tool_names = [str(item).strip() for item in explicit_tools if str(item).strip()]
    else:
        tool_names = derive_default_agent_tools(agent_meta.get("specialty"), integrations)

    tools_cfg["allow"] = list(dict.fromkeys(tool_names))
    target_entry["tools"] = tools_cfg
    write_openclaw_config(config)
    return True


def sync_all_agent_runtime_tools(integrations=None):
    integration_list = integrations if integrations is not None else list_integrations(include_secrets=True)
    config = read_openclaw_config()
    agents_cfg = config.get("agents")
    entries = agents_cfg.get("list") if isinstance(agents_cfg, dict) else None
    if not isinstance(entries, list):
        return
    registry = read_registry()
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        agent_id = (entry.get("id") or "").strip()
        if not agent_id:
            continue
        agent_meta = registry.get(agent_id) if isinstance(registry.get(agent_id), dict) else {}
        sync_agent_runtime_tools(agent_id, agent_meta or {}, integration_list)


def upsert_integration(body):
    system = (body.get("system") or "").strip()
    if system not in INTEGRATION_DEFAULTS:
        raise ValueError("Unknown integration system.")
    defaults = INTEGRATION_DEFAULTS[system]
    existing = load_integrations().get(system, {})
    current_config = dict(existing.get("config") or {})
    current_secrets = dict(existing.get("secrets") or {})

    config = {}
    for field in defaults["config_fields"]:
        value = body.get(field["key"])
        if value is None:
            value = current_config.get(field["key"], "")
        config[field["key"]] = str(value or "").strip()

    for field in defaults["secret_fields"]:
        secret_value = body.get(field["key"])
        if secret_value is None:
            secret_value = current_secrets.get(field["key"], "")
        if isinstance(secret_value, str) and secret_value.strip():
            current_secrets[field["key"]] = secret_value
        elif field["key"] not in current_secrets:
            current_secrets[field["key"]] = ""

    allowed_specialties = body.get("allowed_specialties")
    if not isinstance(allowed_specialties, list):
        allowed_specialties = existing.get("allowed_specialties") or []
    normalized_specialties = []
    for item in allowed_specialties:
        specialty = str(item or "").strip().lower()
        if not specialty:
            continue
        if specialty not in {"seo"}:
            raise ValueError("allowed_specialties may only contain seo")
        normalized_specialties.append(specialty)

    run_query(
        """
        INSERT INTO integrations (
            system, display_name, enabled, allowed_specialties, config_json, secrets_json, notes, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(system) DO UPDATE SET
            display_name = excluded.display_name,
            enabled = excluded.enabled,
            allowed_specialties = excluded.allowed_specialties,
            config_json = excluded.config_json,
            secrets_json = excluded.secrets_json,
            notes = excluded.notes,
            updated_at = CURRENT_TIMESTAMP
        """,
        (
            system,
            defaults["display_name"],
            int(parse_bool(body.get("enabled"))),
            json.dumps(normalized_specialties),
            json.dumps(config),
            json.dumps(current_secrets),
            (body.get("notes") or "").strip(),
        ),
        commit=True,
    )
    return next((item for item in list_integrations() if item["system"] == system), None)


def clear_integration(system):
    if system not in INTEGRATION_DEFAULTS:
        raise ValueError("Unknown integration system.")
    run_query("DELETE FROM integrations WHERE system = ?", (system,), commit=True)


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
    start = params.get("start", [None])[0]
    end = params.get("end", [None])[0]

    clauses.append(f"model NOT IN ({','.join('?' for _ in INTERNAL_MODEL_IDS)})")
    args.extend(sorted(INTERNAL_MODEL_IDS))

    if agent and agent != "all":
        clauses.append("agent_id = ?")
        args.append(agent)
    if model and model != "all":
        clauses.append("model = ?")
        args.append(model)
    if start:
        clauses.append("ts >= ?")
        args.append(start)
    if end:
        clauses.append("ts < ?")
        args.append(end)
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


def model_pricing_index():
    return {
        (row["provider"], row["model_id"]): row
        for row in list_models()
    }


def effective_event_cost(row, pricing_index):
    raw_total = float(row.get("total_cost") or 0)
    if raw_total > 0:
        return raw_total

    provider = row.get("provider") or ""
    model = row.get("model") or ""
    pricing = pricing_index.get((provider, model))
    if not pricing:
        return 0.0

    return round(
        (int(row.get("input_tokens") or 0) * float(pricing.get("cost_input") or 0) / 1_000_000)
        + (int(row.get("output_tokens") or 0) * float(pricing.get("cost_output") or 0) / 1_000_000)
        + (int(row.get("cache_read_tokens") or 0) * float(pricing.get("cost_cache_read") or 0) / 1_000_000)
        + (int(row.get("cache_write_tokens") or 0) * float(pricing.get("cost_cache_write") or 0) / 1_000_000),
        8,
    )


def usage_event_rows(params, limit=None):
    where, args = build_usage_filters(params)
    query = f"""
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
    """
    if limit is not None:
        query += "\nLIMIT ?"
        args = args + [limit]
    return run_query(query, tuple(args), fetchall=True) or []


def usage_summary(params):
    rows = usage_event_rows(params)
    pricing_index = model_pricing_index()
    totals = {
        "event_count": len(rows),
        "input_tokens": sum(int(row.get("input_tokens") or 0) for row in rows),
        "output_tokens": sum(int(row.get("output_tokens") or 0) for row in rows),
        "cache_read_tokens": sum(int(row.get("cache_read_tokens") or 0) for row in rows),
        "cache_write_tokens": sum(int(row.get("cache_write_tokens") or 0) for row in rows),
        "total_tokens": sum(int(row.get("total_tokens") or 0) for row in rows),
        "total_cost": round(sum(effective_event_cost(row, pricing_index) for row in rows), 8),
        "first_ts": min((row.get("ts") for row in rows), default=None),
        "last_ts": max((row.get("ts") for row in rows), default=None),
    }
    by_agent_map = {}
    by_model_map = {}
    for row in rows:
        effective_cost = effective_event_cost(row, pricing_index)
        agent_key = row.get("agent_id") or ""
        agent_bucket = by_agent_map.setdefault(agent_key, {
            "agent": agent_key,
            "event_count": 0,
            "total_tokens": 0,
            "total_cost": 0.0,
        })
        agent_bucket["event_count"] += 1
        agent_bucket["total_tokens"] += int(row.get("total_tokens") or 0)
        agent_bucket["total_cost"] = round(agent_bucket["total_cost"] + effective_cost, 8)

        model_key = (row.get("provider") or "", row.get("model") or "")
        model_bucket = by_model_map.setdefault(model_key, {
            "model": row.get("model") or "",
            "provider": row.get("provider") or "",
            "event_count": 0,
            "total_tokens": 0,
            "total_cost": 0.0,
        })
        model_bucket["event_count"] += 1
        model_bucket["total_tokens"] += int(row.get("total_tokens") or 0)
        model_bucket["total_cost"] = round(model_bucket["total_cost"] + effective_cost, 8)

    by_agent = sorted(by_agent_map.values(), key=lambda row: (row["total_cost"], row["total_tokens"]), reverse=True)
    by_model = sorted(by_model_map.values(), key=lambda row: (row["total_cost"], row["total_tokens"]), reverse=True)
    return {
        "totals": totals,
        "by_agent": by_agent,
        "by_model": by_model,
        "filters": {
            "agent": params.get("agent", ["all"])[0],
            "model": params.get("model", ["all"])[0],
            "days": params.get("days", ["30"])[0],
            "start": params.get("start", [None])[0],
            "end": params.get("end", [None])[0],
        },
    }


def usage_events(params):
    limit = params.get("limit", ["50"])[0]
    try:
        limit_value = max(1, min(int(limit), 500))
    except ValueError:
        limit_value = 50
    rows = usage_event_rows(params, limit=limit_value)
    pricing_index = model_pricing_index()
    for row in rows:
        row["total_cost"] = effective_event_cost(row, pricing_index)
    return rows


def task_run_costs(conn, run_rows):
    costs = {}
    cursor = conn.cursor()
    pricing_index = model_pricing_index()
    for row in run_rows:
        end_time = row["ended_at"] or utc_now_iso()
        usage_rows = [
            dict(item)
            for item in cursor.execute(
            """
            SELECT
                input_tokens,
                output_tokens,
                cache_read_tokens,
                cache_write_tokens,
                total_tokens,
                total_cost,
                provider,
                model
            FROM usage_events
            WHERE agent_id = ?
              AND ts >= ?
              AND ts <= ?
            """,
            (row["agent_id"], row["started_at"], end_time),
        ).fetchall()
        ]
        costs[row["id"]] = {
            "estimated_cost": round(sum(effective_event_cost(item, pricing_index) for item in usage_rows), 8),
            "estimated_tokens": sum(int(item["total_tokens"] or 0) for item in usage_rows),
            "usage_event_count": len(usage_rows),
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
    result["status"] = normalize_task_status(result.get("status"))
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
        task["status"] = normalize_task_status(task.get("status"))
        runs = enrich_runs(conn, task_run_rows(conn, task["id"]))
        rollup = task_rollup_from_runs(runs)
        task["estimated_cost"] = rollup["estimated_cost"]
        task["estimated_tokens"] = rollup["estimated_tokens"]
        task["run_count"] = rollup["run_count"]
        task["open_run"] = rollup["open_run"]
        task["latest_run"] = rollup["latest_run"]
    conn.close()
    return tasks


def normalize_routine(row):
    if not row:
        return None
    item = dict(row)
    item["enabled"] = bool(item.get("enabled"))
    item["schedule_day"] = parse_optional_number(item.get("schedule_day"), int)
    item["schedule_interval_hours"] = parse_optional_number(item.get("schedule_interval_hours"), int)
    item["run_count"] = int(item.get("run_count") or 0)
    item["report_count"] = int(item.get("report_count") or 0)
    item["latest_run_status"] = item.get("latest_run_status") or ""
    item["latest_run_summary"] = item.get("latest_run_summary") or ""
    return item


def fetch_routines():
    rows = run_query(
        """
        SELECT
            r.*,
            COALESCE(run_stats.run_count, 0) AS run_count,
            run_stats.latest_run_status,
            run_stats.latest_run_summary,
            COALESCE(report_stats.report_count, 0) AS report_count
        FROM routines r
        LEFT JOIN (
            SELECT
                rr.routine_id,
                COUNT(*) AS run_count,
                (
                    SELECT status
                    FROM routine_runs latest
                    WHERE latest.routine_id = rr.routine_id
                    ORDER BY latest.started_at DESC, latest.id DESC
                    LIMIT 1
                ) AS latest_run_status,
                (
                    SELECT output_summary
                    FROM routine_runs latest
                    WHERE latest.routine_id = rr.routine_id
                    ORDER BY latest.started_at DESC, latest.id DESC
                    LIMIT 1
                ) AS latest_run_summary
            FROM routine_runs rr
            GROUP BY rr.routine_id
        ) run_stats ON run_stats.routine_id = r.id
        LEFT JOIN (
            SELECT routine_id, COUNT(*) AS report_count
            FROM reports
            WHERE routine_id IS NOT NULL
            GROUP BY routine_id
        ) report_stats ON report_stats.routine_id = r.id
        ORDER BY r.enabled DESC, r.updated_at DESC, r.id DESC
        """,
        fetchall=True,
    ) or []
    return [normalize_routine(row) for row in rows]


def fetch_routine_detail(routine_id):
    routine = run_query(
        """
        SELECT
            r.*,
            COALESCE(report_stats.report_count, 0) AS report_count
        FROM routines r
        LEFT JOIN (
            SELECT routine_id, COUNT(*) AS report_count
            FROM reports
            WHERE routine_id IS NOT NULL
            GROUP BY routine_id
        ) report_stats ON report_stats.routine_id = r.id
        WHERE r.id = ?
        """,
        (routine_id,),
        fetchone=True,
    )
    if not routine:
        return None
    routine = normalize_routine(routine)
    routine["runs"] = run_query(
        """
        SELECT id, routine_id, status, started_at, ended_at, output_summary, task_id, estimated_cost, estimated_tokens
        FROM routine_runs
        WHERE routine_id = ?
        ORDER BY started_at DESC, id DESC
        LIMIT 20
        """,
        (routine_id,),
        fetchall=True,
    ) or []
    routine["reports"] = run_query(
        """
        SELECT id, title, report_type, summary, status, created_at
        FROM reports
        WHERE routine_id = ?
        ORDER BY created_at DESC, id DESC
        LIMIT 20
        """,
        (routine_id,),
        fetchall=True,
    ) or []
    return routine


def upsert_routine(body, routine_id=None):
    name = (body.get("name") or "").strip()
    agent_id = (body.get("agent_id") or "").strip()
    if not name or not agent_id:
        raise ValueError("name and agent_id are required")
    timezone_name = (body.get("timezone") or "UTC").strip() or "UTC"
    compiled_schedule = compile_routine_schedule(body)
    prompt = (body.get("prompt") or "").strip()
    output_mode = (body.get("output_mode") or "report_if_needed").strip()
    report_channel_id = (body.get("report_channel_id") or "").strip() or None
    enabled = int(parse_bool(body.get("enabled", True)))
    if routine_id is None:
        routine_id = run_query(
            """
            INSERT INTO routines (
                name, agent_id, schedule_type, schedule_value, schedule_time, schedule_day,
                schedule_interval_hours, schedule_date, schedule_summary, cron_expression,
                timezone, prompt, output_mode, report_channel_id, enabled
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                name,
                agent_id,
                compiled_schedule["schedule_type"],
                compiled_schedule["schedule_value"],
                compiled_schedule["schedule_time"],
                compiled_schedule["schedule_day"],
                compiled_schedule["schedule_interval_hours"],
                compiled_schedule["schedule_date"],
                compiled_schedule["schedule_summary"],
                compiled_schedule["cron_expression"],
                timezone_name,
                prompt,
                output_mode,
                report_channel_id,
                enabled,
            ),
            commit=True,
        )
    else:
        run_query(
            """
            UPDATE routines
            SET
                name = ?,
                agent_id = ?,
                schedule_type = ?,
                schedule_value = ?,
                schedule_time = ?,
                schedule_day = ?,
                schedule_interval_hours = ?,
                schedule_date = ?,
                schedule_summary = ?,
                cron_expression = ?,
                timezone = ?,
                prompt = ?,
                output_mode = ?,
                report_channel_id = ?,
                enabled = ?,
                updated_at = CURRENT_TIMESTAMP
            WHERE id = ?
            """,
            (
                name,
                agent_id,
                compiled_schedule["schedule_type"],
                compiled_schedule["schedule_value"],
                compiled_schedule["schedule_time"],
                compiled_schedule["schedule_day"],
                compiled_schedule["schedule_interval_hours"],
                compiled_schedule["schedule_date"],
                compiled_schedule["schedule_summary"],
                compiled_schedule["cron_expression"],
                timezone_name,
                prompt,
                output_mode,
                report_channel_id,
                enabled,
                routine_id,
            ),
            commit=True,
        )
    return sync_routine_cron_job(fetch_routine_detail(int(routine_id)))


def run_routine_now(routine_id):
    routine = fetch_routine_detail(routine_id)
    if not routine:
        return None
    if not routine.get("cron_job_id"):
        routine = sync_routine_cron_job(routine)
    cron_job_id = (routine.get("cron_job_id") or "").strip()
    if not cron_job_id:
        raise RuntimeError("Routine is missing an OpenClaw cron job id.")
    started_at = utc_now_iso()
    summary = f"Manual cron run requested for {routine['name']}."
    run_openclaw_command(["cron", "run", cron_job_id])
    run_query(
        """
        INSERT INTO routine_runs (routine_id, status, started_at, output_summary)
        VALUES (?, ?, ?, ?)
        """,
        (routine_id, "queued", started_at, summary),
        commit=True,
    )
    run_query(
        """
        UPDATE routines
        SET last_run_at = ?, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
        """,
        (started_at, routine_id),
        commit=True,
    )
    return fetch_routine_detail(routine_id)


def fetch_reports(limit=50):
    rows = run_query(
        """
        SELECT
            rep.id,
            rep.title,
            rep.agent_id,
            rep.routine_id,
            rep.routine_run_id,
            rep.report_type,
            rep.summary,
            rep.body,
            rep.status,
            rep.created_at,
            rut.name AS routine_name
        FROM reports rep
        LEFT JOIN routines rut ON rut.id = rep.routine_id
        ORDER BY rep.created_at DESC, rep.id DESC
        LIMIT ?
        """,
        (limit,),
        fetchall=True,
    ) or []
    return rows


def fetch_report_detail(report_id):
    return run_query(
        """
        SELECT
            rep.id,
            rep.title,
            rep.agent_id,
            rep.routine_id,
            rep.routine_run_id,
            rep.report_type,
            rep.summary,
            rep.body,
            rep.status,
            rep.created_at,
            rut.name AS routine_name
        FROM reports rep
        LEFT JOIN routines rut ON rut.id = rep.routine_id
        WHERE rep.id = ?
        """,
        (report_id,),
        fetchone=True,
    )


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
    status = normalize_task_status(status)
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
            agents = discover_openclaw_agents()
            return self._send_json(200, {
                "ok": True,
                "service": "syntella-local-dev",
                "uptime_seconds": None,
                "agents_total": len(agents),
            })

        if path in ("/api/agents", "/api/departments"):
            return self._send_json(200, {"ok": True, "agents": discover_openclaw_agents()})

        if path == "/api/models":
            sync = sync_usage_events()
            return self._send_json(200, {"ok": True, "sync": sync, "models": list_models()})

        if path == "/api/integrations":
            return self._send_json(200, {"ok": True, "integrations": list_integrations()})

        if path == "/api/routines":
            return self._send_json(200, {"ok": True, "routines": fetch_routines()})

        if path.startswith("/api/routines/"):
            parts = [part for part in path.split("/") if part]
            if len(parts) == 3 and parts[1] == "routines" and parts[2].isdigit():
                routine = fetch_routine_detail(int(parts[2]))
                if not routine:
                    return self._send_json(404, {"error": "not_found"})
                return self._send_json(200, {"ok": True, "routine": routine})

        if path == "/api/reports":
            limit = params.get("limit", ["50"])[0]
            try:
                limit_value = max(1, min(int(limit), 100))
            except ValueError:
                limit_value = 50
            return self._send_json(200, {"ok": True, "reports": fetch_reports(limit_value)})

        if path.startswith("/api/reports/"):
            report_id = path.rsplit("/", 1)[-1]
            if not report_id.isdigit():
                return self._send_json(400, {"error": "Invalid report ID"})
            report = fetch_report_detail(int(report_id))
            if not report:
                return self._send_json(404, {"error": "not_found"})
            return self._send_json(200, {"ok": True, "report": report})

        if path == "/api/operator-bridge/health":
            try:
                status, payload = bridge_request("/health", method="GET")
                return self._send_json(status, payload)
            except Exception as exc:
                return self._send_json(502, {"ok": False, "error": str(exc)})

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

        if path == "/api/models/overrides":
            body = self._parse_body()
            try:
                apply_model_to_openclaw_config(body)
                upsert_model_override(body)
                runtime = restart_openclaw_gateway("model override update")
                return self._send_json(200, {"ok": True, "models": list_models(), "runtime": runtime})
            except ValueError as exc:
                return self._send_json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})

        if path == "/api/runtime/reload":
            try:
                runtime = restart_openclaw_gateway("manual runtime reload")
                status = 200 if runtime.get("ok") else 500
                return self._send_json(status, {"ok": bool(runtime.get("ok")), "runtime": runtime})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})

        if path == "/api/integrations":
            body = self._parse_body()
            try:
                integration = upsert_integration(body)
                integrations = list_integrations()
                full_integrations = list_integrations(include_secrets=True)
                sync_integrations_to_openclaw_config(full_integrations)
                sync_all_agent_runtime_tools(full_integrations)
                runtime = restart_openclaw_gateway("integration update")
                return self._send_json(200, {"ok": True, "integration": integration, "integrations": integrations, "runtime": runtime})
            except ValueError as exc:
                return self._send_json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})

        if path == "/api/spawn-agent":
            body = self._parse_body()
            try:
                status, payload = bridge_request("/spawn-agent", method="POST", payload=body, timeout=300)
                return self._send_json(status, payload)
            except Exception as exc:
                return self._send_json(502, {"ok": False, "error": str(exc)})

        if path == "/api/routines":
            body = self._parse_body()
            try:
                return self._send_json(201, {"ok": True, "routine": upsert_routine(body)})
            except ValueError as exc:
                return self._send_json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})

        if path.startswith("/api/routines/") and path.endswith("/run"):
            parts = [part for part in path.split("/") if part]
            if len(parts) == 4 and parts[1] == "routines" and parts[2].isdigit():
                try:
                    routine = run_routine_now(int(parts[2]))
                    if not routine:
                        return self._send_json(404, {"error": "not_found"})
                    return self._send_json(200, {"ok": True, "routine": routine})
                except Exception as exc:
                    return self._send_json(500, {"ok": False, "error": str(exc)})

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
        if path.startswith("/api/routines/"):
            routine_id = path.rsplit("/", 1)[-1]
            if not routine_id.isdigit():
                return self._send_json(400, {"error": "Invalid routine ID"})
            body = self._parse_body()
            try:
                routine = upsert_routine(body, int(routine_id))
                if not routine:
                    return self._send_json(404, {"error": "not_found"})
                return self._send_json(200, {"ok": True, "routine": routine})
            except ValueError as exc:
                return self._send_json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})
        if path.startswith("/api/agents/"):
            agent_id = path.rsplit("/", 1)[-1]
            body = self._parse_body()
            try:
                agent, runtime_changed = update_agent_metadata(agent_id, body)
                runtime = restart_openclaw_gateway("agent runtime update") if runtime_changed else None
                return self._send_json(200, {"ok": True, "agent": agent, "runtime": runtime})
            except ValueError as exc:
                message = str(exc)
                status = 404 if message == "Agent not found." else 400
                return self._send_json(status, {"ok": False, "error": message})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})
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
        if path == "/api/models/overrides":
            body = self._parse_body()
            provider = (body.get("provider") or "").strip()
            model_id = (body.get("model_id") or "").strip()
            if not provider or not model_id:
                return self._send_json(400, {"ok": False, "error": "provider and model_id are required"})
            try:
                delete_model_override(provider, model_id)
                runtime = restart_openclaw_gateway("model override delete")
                return self._send_json(200, {"ok": True, "models": list_models(), "runtime": runtime})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})

        if path == "/api/integrations":
            body = self._parse_body()
            system = (body.get("system") or "").strip()
            if not system:
                return self._send_json(400, {"ok": False, "error": "system is required"})
            try:
                clear_integration(system)
                integrations = list_integrations()
                full_integrations = list_integrations(include_secrets=True)
                sync_integrations_to_openclaw_config(full_integrations)
                sync_all_agent_runtime_tools(full_integrations)
                runtime = restart_openclaw_gateway("integration delete")
                return self._send_json(200, {"ok": True, "integrations": integrations, "runtime": runtime})
            except ValueError as exc:
                return self._send_json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:
                return self._send_json(500, {"ok": False, "error": str(exc)})
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
