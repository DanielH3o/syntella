#!/usr/bin/env python3
import json, os, re, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from subprocess import run, TimeoutExpired

TOKEN=os.environ.get("OPERATOR_BRIDGE_TOKEN","")
PORT=int(os.environ.get("OPERATOR_BRIDGE_PORT","8787"))
LOG=os.path.expanduser("~/.openclaw/logs/operator-bridge.log")
AGENT_RE=re.compile(r"^[a-z0-9][a-z0-9-]{1,30}$")


def log(event, **kw):
  os.makedirs(os.path.dirname(LOG), exist_ok=True)
  rec={"ts":time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),"event":event,**kw}
  with open(LOG,"a",encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False)+"\n")


def normalize_payload(body):
  agent_id = body.get("agent_id") or body.get("agentId") or body.get("name")
  role = body.get("role")
  description = body.get("description") or body.get("personality")
  discord_token = body.get("discord_token") or body.get("discordBotToken") or body.get("discord_bot_token")
  port = body.get("port")

  missing=[]
  if not agent_id: missing.append("agent_id")
  if not role: missing.append("role")
  if not description: missing.append("description")
  if not discord_token: missing.append("discord_token")
  if missing:
    return None, {"error":"bad_request","detail":"missing required fields","missing":missing}

  agent_id=str(agent_id).strip().lower()
  if not AGENT_RE.match(agent_id):
    return None, {"error":"bad_request","detail":"invalid agent_id; use lowercase letters, numbers, hyphen (2-31 chars)"}

  role=str(role).strip()
  description=str(description).strip()
  discord_token=str(discord_token).strip()
  port="" if port is None else str(port).strip()
  if port and not port.isdigit():
    return None, {"error":"bad_request","detail":"port must be numeric when provided"}

  return {"agent_id":agent_id,"role":role,"description":description,"discord_token":discord_token,"port":port}, None


class H(BaseHTTPRequestHandler):
  def log_message(self, fmt, *args):
    return

  def _send(self, code, obj):
    b=json.dumps(obj).encode()
    self.send_response(code)
    self.send_header('Content-Type','application/json')
    self.send_header('Content-Length',str(len(b)))
    self.end_headers(); self.wfile.write(b)

  def _auth(self):
    return self.headers.get('Authorization','')==f'Bearer {TOKEN}'

  def do_GET(self):
    if self.path=="/health":
      return self._send(200,{"ok":True})

    if self.path=="/agents":
      if not self._auth():
        return self._send(401,{"error":"unauthorized"})
      reg=os.path.expanduser('~/.openclaw/workspace/agents/registry.json')
      data={}
      if os.path.exists(reg):
        try:
          data=json.load(open(reg, 'r', encoding='utf-8'))
        except Exception:
          data={}
      return self._send(200,{"ok":True,"agents":data})

    self._send(404,{"error":"not_found"})

  def do_POST(self):
    req_id=str(uuid.uuid4())[:8]
    if not self._auth():
      log("unauthorized", req_id=req_id, path=self.path)
      return self._send(401,{"error":"unauthorized"})
    if self.path!="/spawn-agent":
      return self._send(404,{"error":"not_found"})

    try:
      n=int(self.headers.get('Content-Length','0'))
      body=json.loads(self.rfile.read(n) or b"{}")
    except Exception as e:
      return self._send(400,{"error":"bad_request","detail":f"invalid JSON: {e}"})

    payload, err = normalize_payload(body)
    if err:
      log("spawn_rejected", req_id=req_id, error=err)
      return self._send(400, err)

    full_role = f"{payload['role']} — {payload['description']}"
    cmd=["/usr/local/bin/kiwi-spawn-agent", payload["agent_id"], full_role, payload["discord_token"]]
    if payload["port"]:
      cmd.append(payload["port"])

    log("spawn_start", req_id=req_id, agent_id=payload["agent_id"], role=payload["role"], description=payload["description"], port=payload["port"], token="***redacted***")
    t0=time.time()
    try:
      r=run(cmd, capture_output=True, text=True, timeout=240)
    except TimeoutExpired as e:
      dur_ms=int((time.time()-t0)*1000)
      log("spawn_timeout", req_id=req_id, duration_ms=dur_ms)
      return self._send(504, {
        "ok": False,
        "error": "spawn_timeout",
        "request_id": req_id,
        "duration_ms": dur_ms,
        "stdout": (e.stdout or "")[-4000:],
        "stderr": (e.stderr or "")[-4000:],
      })
    dur_ms=int((time.time()-t0)*1000)

    spawn_meta={}
    try:
      spawn_meta=json.loads((r.stdout or '').strip().splitlines()[-1]) if (r.stdout or '').strip() else {}
    except Exception:
      spawn_meta={}

    out={
      "ok": r.returncode==0,
      "exit_code": r.returncode,
      "stdout": r.stdout[-4000:],
      "stderr": r.stderr[-4000:],
      "request_id": req_id,
      "duration_ms": dur_ms,
      "spawn": spawn_meta,
      "guild_configured": bool(spawn_meta.get("guild_configured", False)),
      "guild_id": spawn_meta.get("guild_id"),
      "channel_id": spawn_meta.get("channel_id"),
    }
    log("spawn_done", req_id=req_id, ok=(r.returncode==0), exit_code=r.returncode, duration_ms=dur_ms, guild_configured=out["guild_configured"], stderr_tail=r.stderr[-300:])
    return self._send(200 if r.returncode==0 else 500, out)

if __name__=="__main__":
  HTTPServer(("127.0.0.1", PORT), H).serve_forever()
