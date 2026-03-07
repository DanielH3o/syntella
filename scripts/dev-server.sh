#!/bin/bash
set -euo pipefail

# Local dev server for the Syntella frontend backed by the local OpenClaw workspace.
# Uses real registry/tasks data when present instead of seeding preview data.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${SYNTELLA_WORKSPACE:-$HOME/.openclaw/workspace}"
PORT="${SYNTELLA_DEV_PORT:-3000}"

mkdir -p "$WORKSPACE/agents" "$WORKSPACE/logs"

if [ ! -f "$WORKSPACE/agents/registry.json" ]; then
  echo "No registry found at $WORKSPACE/agents/registry.json"
  echo "The UI will start, but Departments will be empty until local agents register."
fi

echo "Starting Syntella local dev server on :$PORT..."
echo "Workspace: $WORKSPACE"
exec python3 "$ROOT_DIR/scripts/local-dev-server.py"
