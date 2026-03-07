#!/usr/bin/env python3
"""Syntella Admin API — Local database and dashboard backend.

Serves as the backend for the SaaS-style dashboard, exposing REST endpoints
for Kanban tasks and interacting with the Agent Registry.
"""
import sqlite3
import json
import os
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("SYNTELLA_API_PORT", "8788"))
WORKSPACE = os.path.expanduser("~/.openclaw/workspace")
DB_PATH = os.path.join(WORKSPACE, "tasks.db")
REGISTRY = os.path.join(WORKSPACE, "agents", "registry.json")

def init_db():
    """Initialize the SQLite tasks database."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute("""
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
    """)
    
    # Insert a dummy task if empty
    cursor.execute("SELECT COUNT(*) FROM tasks")
    if cursor.fetchone()[0] == 0:
        cursor.execute("""
            INSERT INTO tasks (title, description, assignee, status, priority) 
            VALUES ('Set up deployment', 'Migrate the local SQLite database to the droplet.', 'syntella', 'todo', 'high')
        """)
    
    conn.commit()
    conn.close()
    print(f"Database initialized at {DB_PATH}")

def run_query(query, args=(), fetchall=False, commit=False):
    """Helper to run SQLite queries safely."""
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    cursor.execute(query, args)
    
    result = None
    if fetchall:
        result = [dict(row) for row in cursor.fetchall()]
    elif cursor.description:
        row = cursor.fetchone()
        if row:
            result = dict(row)
            
    if commit:
        conn.commit()
        result = cursor.lastrowid
        
    conn.close()
    return result

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

class APIHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Disable default logging
        return

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        # Explicit CORS for local dev
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def parse_body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if n > 0:
                return json.loads(self.rfile.read(n))
            return {}
        except Exception:
            return {}

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            return self.send_json(200, {"ok": True, "service": "syntella-api"})

        if self.path == "/api/departments":
            try:
                with open(REGISTRY, "r") as f:
                    data = json.load(f)
                return self.send_json(200, {"ok": True, "agents": data})
            except Exception:
                return self.send_json(200, {"ok": True, "agents": {}})

        if self.path == "/api/tasks":
            try:
                tasks = run_query("SELECT * FROM tasks ORDER BY priority DESC, created_at DESC", fetchall=True)
                return self.send_json(200, {"ok": True, "tasks": tasks})
            except Exception as e:
                return self.send_json(500, {"ok": False, "error": str(e)})

        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path == "/api/tasks":
            body = self.parse_body()
            if not body.get("title"):
                return self.send_json(400, {"error": "Title is required"})
                
            try:
                task_id = run_query(
                    """INSERT INTO tasks (title, description, assignee, status, priority) 
                       VALUES (?, ?, ?, ?, ?)""",
                    (body.get("title"), body.get("description", ""), 
                     body.get("assignee", ""), body.get("status", "backlog"), 
                     body.get("priority", "medium")),
                    commit=True
                )
                
                new_task = run_query("SELECT * FROM tasks WHERE id = ?", (task_id,))
                return self.send_json(201, {"ok": True, "task": new_task})
            except Exception as e:
                return self.send_json(500, {"ok": False, "error": str(e)})

        self.send_json(404, {"error": "not_found"})

    def do_PUT(self):
        if self.path.startswith("/api/tasks/"):
            task_id = self.path.split("/")[-1]
            if not task_id.isdigit():
                return self.send_json(400, {"error": "Invalid task ID"})
                
            body = self.parse_body()
            if not body:
                return self.send_json(400, {"error": "Empty payload"})
                
            updates = []
            args = []
            
            for field in ["title", "description", "assignee", "status", "priority"]:
                if field in body:
                    updates.append(f"{field} = ?")
                    args.append(body[field])
                    
            if not updates:
                return self.send_json(400, {"error": "No valid fields to update"})
                
            updates.append("updated_at = CURRENT_TIMESTAMP")
            args.append(task_id)
            
            try:
                run_query(f"UPDATE tasks SET {', '.join(updates)} WHERE id = ?", tuple(args), commit=True)
                updated_task = run_query("SELECT * FROM tasks WHERE id = ?", (task_id,))
                return self.send_json(200, {"ok": True, "task": updated_task})
            except Exception as e:
                return self.send_json(500, {"ok": False, "error": str(e)})
                
        self.send_json(404, {"error": "not_found"})

    def do_DELETE(self):
        if self.path.startswith("/api/tasks/"):
            task_id = self.path.split("/")[-1]
            if not task_id.isdigit():
                return self.send_json(400, {"error": "Invalid task ID"})
                
            try:
                run_query("DELETE FROM tasks WHERE id = ?", (task_id,), commit=True)
                return self.send_json(200, {"ok": True})
            except Exception as e:
                return self.send_json(500, {"ok": False, "error": str(e)})
                
        self.send_json(404, {"error": "not_found"})

def main():
    init_db()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), APIHandler)
    
    def shutdown_handler(signum, frame):
        print("\nShutting down API server...", flush=True)
        server.shutdown()
        sys.exit(0)
        
    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)
    
    print(f"Syntella API listening on 0.0.0.0:{PORT}", flush=True)
    server.serve_forever()

if __name__ == "__main__":
    main()
