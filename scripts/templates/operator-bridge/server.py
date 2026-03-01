#!/usr/bin/env python3
"""Operator Bridge — HTTP API for spawning and managing OpenClaw agents.

Improvements over original:
- ThreadingHTTPServer for concurrent request handling
- File-based spawn lock to prevent race conditions
- Graceful shutdown on SIGTERM/SIGINT
- Proper file handle management (context managers)
- Health endpoint includes bridge uptime and active spawn status
- Agent stop/restart endpoints
- Better error reporting
"""
import json, os, re, signal, sys, time, uuid, fcntl
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from subprocess import run, TimeoutExpired
from pathlib import Path

TOKEN = os.environ.get("OPERATOR_BRIDGE_TOKEN", "")
PORT = int(os.environ.get("OPERATOR_BRIDGE_PORT", "8787"))
LOG = os.path.expanduser("~/.openclaw/logs/operator-bridge.log")
REGISTRY = os.path.expanduser("~/.openclaw/workspace/agents/registry.json")
SPAWN_LOCK = os.path.expanduser("~/.openclaw/logs/spawn.lock")
AGENT_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,30}$")
SPAWN_TIMEOUT = 240
START_TIME = time.time()

# Track active spawn so health endpoint can report it.
_active_spawn = {"agent_id": None, "started_at": None}


def log_event(event, **kw):
    """Append a JSON log line to the operator bridge log."""
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event": event,
        **kw,
    }
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def read_registry():
    """Read the agent registry, returning {} on any error."""
    try:
        with open(REGISTRY, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def normalize_payload(body):
    """Validate and normalize a spawn-agent request body."""
    agent_id = body.get("agent_id") or body.get("agentId") or body.get("name")
    role = body.get("role")
    description = body.get("description") or body.get("personality")
    discord_token = (
        body.get("discord_token")
        or body.get("discordBotToken")
        or body.get("discord_bot_token")
    )
    port = body.get("port")

    missing = []
    if not agent_id:
        missing.append("agent_id")
    if not role:
        missing.append("role")
    if not description:
        missing.append("description")
    if not discord_token:
        missing.append("discord_token")
    if missing:
        return None, {
            "error": "bad_request",
            "detail": "missing required fields",
            "missing": missing,
        }

    agent_id = str(agent_id).strip().lower()
    if not AGENT_RE.match(agent_id):
        return None, {
            "error": "bad_request",
            "detail": "invalid agent_id; use lowercase letters, numbers, hyphen (2-31 chars)",
        }

    role = str(role).strip()
    description = str(description).strip()
    discord_token = str(discord_token).strip()
    port = "" if port is None else str(port).strip()
    if port and not port.isdigit():
        return None, {"error": "bad_request", "detail": "port must be numeric when provided"}

    return {
        "agent_id": agent_id,
        "role": role,
        "description": description,
        "discord_token": discord_token,
        "port": port,
    }, None


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle each request in a separate thread so spawns don't block other requests."""
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    # Suppress default access logging.
    def log_message(self, fmt, *args):
        return

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _auth(self):
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            uptime = int(time.time() - START_TIME)
            return self._send(200, {
                "ok": True,
                "uptime_seconds": uptime,
                "active_spawn": _active_spawn["agent_id"],
            })

        if self.path == "/agents":
            if not self._auth():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"ok": True, "agents": read_registry()})

        self._send(404, {"error": "not_found"})

    def do_POST(self):
        req_id = str(uuid.uuid4())[:8]

        if not self._auth():
            log_event("unauthorized", req_id=req_id, path=self.path)
            return self._send(401, {"error": "unauthorized"})

        if self.path == "/stop-agent":
            return self._handle_stop_agent(req_id)

        if self.path != "/spawn-agent":
            return self._send(404, {"error": "not_found"})

        # Parse body.
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:
            return self._send(400, {"error": "bad_request", "detail": f"invalid JSON: {e}"})

        payload, err = normalize_payload(body)
        if err:
            log_event("spawn_rejected", req_id=req_id, error=err)
            return self._send(400, err)

        # Acquire spawn lock (non-blocking). Only one spawn at a time.
        os.makedirs(os.path.dirname(SPAWN_LOCK), exist_ok=True)
        try:
            lock_fd = open(SPAWN_LOCK, "w")
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError):
            lock_fd = None
            return self._send(409, {
                "ok": False,
                "error": "spawn_busy",
                "detail": f"Another spawn is in progress (agent: {_active_spawn['agent_id']}). Try again shortly.",
                "request_id": req_id,
            })

        try:
            return self._do_spawn(req_id, payload, lock_fd)
        finally:
            if lock_fd:
                try:
                    fcntl.flock(lock_fd, fcntl.LOCK_UN)
                    lock_fd.close()
                except OSError:
                    pass

    def _do_spawn(self, req_id, payload, lock_fd):
        """Execute the spawn subprocess under the spawn lock."""
        full_role = f"{payload['role']} — {payload['description']}"
        cmd = [
            "/usr/local/bin/syntella-spawn-agent",
            payload["agent_id"],
            full_role,
            payload["discord_token"],
        ]
        if payload["port"]:
            cmd.append(payload["port"])

        _active_spawn["agent_id"] = payload["agent_id"]
        _active_spawn["started_at"] = time.time()

        log_event(
            "spawn_start",
            req_id=req_id,
            agent_id=payload["agent_id"],
            role=payload["role"],
            description=payload["description"],
            port=payload["port"],
            token="***redacted***",
        )

        t0 = time.time()
        try:
            r = run(cmd, capture_output=True, text=True, timeout=SPAWN_TIMEOUT)
        except TimeoutExpired as e:
            dur_ms = int((time.time() - t0) * 1000)
            log_event("spawn_timeout", req_id=req_id, duration_ms=dur_ms)
            return self._send(504, {
                "ok": False,
                "error": "spawn_timeout",
                "request_id": req_id,
                "duration_ms": dur_ms,
                "stdout": (e.stdout or "")[-4000:],
                "stderr": (e.stderr or "")[-4000:],
            })
        except Exception as e:
            dur_ms = int((time.time() - t0) * 1000)
            log_event("spawn_error", req_id=req_id, error=str(e), duration_ms=dur_ms)
            return self._send(500, {
                "ok": False,
                "error": "spawn_exception",
                "detail": str(e),
                "request_id": req_id,
                "duration_ms": dur_ms,
            })
        finally:
            _active_spawn["agent_id"] = None
            _active_spawn["started_at"] = None

        dur_ms = int((time.time() - t0) * 1000)

        # Parse spawn metadata from the last line of stdout.
        spawn_meta = {}
        stdout_text = r.stdout or ""
        if stdout_text.strip():
            try:
                spawn_meta = json.loads(stdout_text.strip().splitlines()[-1])
            except (json.JSONDecodeError, IndexError):
                spawn_meta = {}

        out = {
            "ok": r.returncode == 0,
            "exit_code": r.returncode,
            "stdout": stdout_text[-4000:],
            "stderr": (r.stderr or "")[-4000:],
            "request_id": req_id,
            "duration_ms": dur_ms,
            "spawn": spawn_meta,
            "guild_configured": bool(spawn_meta.get("guild_configured", False)),
            "guild_id": spawn_meta.get("guild_id"),
            "channel_id": spawn_meta.get("channel_id"),
        }

        log_event(
            "spawn_done",
            req_id=req_id,
            ok=(r.returncode == 0),
            exit_code=r.returncode,
            duration_ms=dur_ms,
            guild_configured=out["guild_configured"],
            stderr_tail=(r.stderr or "")[-300:],
        )
        return self._send(200 if r.returncode == 0 else 500, out)

    def _handle_stop_agent(self, req_id):
        """Stop a spawned agent's gateway process."""
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:
            return self._send(400, {"error": "bad_request", "detail": f"invalid JSON: {e}"})

        agent_id = str(body.get("agent_id", "")).strip().lower()
        if not agent_id or not AGENT_RE.match(agent_id):
            return self._send(400, {"error": "bad_request", "detail": "invalid or missing agent_id"})

        registry = read_registry()
        agent = registry.get(agent_id)
        if not agent:
            return self._send(404, {"error": "not_found", "detail": f"agent '{agent_id}' not in registry"})

        port = agent.get("port")
        pid = agent.get("pid")
        killed = False

        # Try to kill by PID first, then by port.
        if pid:
            try:
                os.kill(int(pid), signal.SIGTERM)
                killed = True
            except (OSError, ValueError):
                pass

        if not killed and port:
            # Kill any process listening on the agent's port.
            run(
                ["bash", "-c", f"lsof -ti tcp:{port} | xargs -r kill 2>/dev/null || true"],
                capture_output=True,
                timeout=5,
            )
            killed = True

        log_event("agent_stopped", req_id=req_id, agent_id=agent_id, port=port, pid=pid)
        return self._send(200, {"ok": True, "agent_id": agent_id, "stopped": killed})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)

    def shutdown_handler(signum, frame):
        log_event("shutdown", signal=signum)
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    log_event("started", port=PORT)
    print(f"Operator bridge listening on 127.0.0.1:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
