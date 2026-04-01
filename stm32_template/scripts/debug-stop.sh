#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

PID_FILE=".jlink-gdb.pid"
GDB_PORT="2331"

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
fi

pkill -f "JLinkGDBServerCLExe.*-port ${GDB_PORT}" 2>/dev/null || true
