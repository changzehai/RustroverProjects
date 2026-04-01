#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="thumbv7em-none-eabihf"
GDB_BIN="/Applications/ArmGNUToolchain/15.2.rel1/arm-none-eabi/bin/arm-none-eabi-gdb"
JLINK_GDB_SERVER="/Applications/SEGGER/JLink/JLinkGDBServerCLExe"
DEVICE="STM32F407ZE"
INTERFACE="SWD"
SPEED="4000"
GDB_PORT="2331"
SWO_PORT="2332"
TELNET_PORT="2333"
PID_FILE=".jlink-gdb.pid"
SERVER_LOG=".jlink-gdb.log"
LOAD_LOG=".jlink-load.log"
SYMBOL_LINK="target/${TARGET}/debug/__rustrover_current.elf"

/bin/zsh scripts/debug-stop.sh

/bin/zsh scripts/sync-project-name.sh

cargo build --target "${TARGET}"

BIN_NAME="$(
  sed -nE '/^\[\[bin\]\]$/,/^\[/ s/^name = "([^"]+)"/\1/p' Cargo.toml | head -n 1
)"

if [[ -z "${BIN_NAME}" ]]; then
  BIN_NAME="$(
    sed -nE '/^\[package\]$/,/^\[/ s/^name = "([^"]+)"/\1/p' Cargo.toml | head -n 1
  )"
fi

if [[ -z "${BIN_NAME}" ]]; then
  echo "Failed to determine binary name from Cargo.toml" >&2
  exit 1
fi

BINARY="target/${TARGET}/debug/${BIN_NAME}"

if [[ ! -f "${BINARY}" ]]; then
  echo "Missing ELF file: ${BINARY}" >&2
  exit 1
fi

ln -sfn "${BIN_NAME}" "${SYMBOL_LINK}"

if [[ ! -x "${GDB_BIN}" ]]; then
  echo "Missing GDB binary: ${GDB_BIN}" >&2
  exit 1
fi

nohup "${JLINK_GDB_SERVER}" \
  -device "${DEVICE}" \
  -if "${INTERFACE}" \
  -speed "${SPEED}" \
  -port "${GDB_PORT}" \
  -swoport "${SWO_PORT}" \
  -telnetport "${TELNET_PORT}" \
  -noir >"${SERVER_LOG}" 2>&1 &
server_pid=$!
echo "${server_pid}" > "${PID_FILE}"

for _ in {1..50}; do
  if grep -q "Listening on TCP/IP port ${GDB_PORT}" "${SERVER_LOG}" 2>/dev/null; then
    break
  fi
  if ! kill -0 "${server_pid}" 2>/dev/null; then
    echo "J-Link GDB server exited unexpectedly. See ${SERVER_LOG}:" >&2
    cat "${SERVER_LOG}" >&2 || true
    exit 1
  fi
  sleep 0.2
done

if ! grep -q "Listening on TCP/IP port ${GDB_PORT}" "${SERVER_LOG}" 2>/dev/null; then
  echo "Timed out waiting for J-Link GDB server to start. See ${SERVER_LOG}:" >&2
  cat "${SERVER_LOG}" >&2 || true
  exit 1
fi

if ! "${GDB_BIN}" \
  -q \
  -nx \
  -batch \
  "${BINARY}" \
  -ex "target extended-remote localhost:${GDB_PORT}" \
  -ex "monitor reset" \
  -ex "monitor halt" \
  -ex "load" \
  -ex "monitor reset" \
  -ex "monitor halt" \
  -ex "disconnect" >"${LOAD_LOG}" 2>&1; then
  echo "ELF load failed. See ${LOAD_LOG}:" >&2
  cat "${LOAD_LOG}" >&2 || true
  exit 1
fi
