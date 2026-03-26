#!/usr/bin/env bash

# Shared helpers for stage scripts.

init_script() {
  local script_path="$1"
  SCRIPT_NAME="$(basename "$script_path")"
  SCRIPT_BASENAME="${SCRIPT_NAME%.*}"
  SCRIPT_DIR="$(cd -- "$(dirname -- "$script_path")" && pwd)"

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  LOG_DIR="${SCRIPT_DIR}/logs"
  LOG_FILE="${LOG_DIR}/${SCRIPT_BASENAME}-${ts}.log"
  SCRIPT_START_EPOCH="$(date +%s)"

  mkdir -p "${LOG_DIR}"
  touch "${LOG_FILE}"

  # Preserve original stdout for concise operator-facing messages.
  exec 3>&1
  # Send command-level stdout/stderr to log file.
  exec >>"${LOG_FILE}" 2>&1

  {
    echo "============================================================"
    echo "Script: ${SCRIPT_NAME}"
    echo "Started: $(date -Iseconds)"
    echo "Log: ${LOG_FILE}"
    echo "Command tracing: enabled"
    echo "============================================================"
  } >>"${LOG_FILE}"

  # Always-on verbose tracing to the log file only.
  # stderr is already redirected to LOG_FILE, so trace lines stay out of operator console (fd 3).
  export BASH_XTRACEFD=2
  export PS4='+ [$(date +%H:%M:%S)] [${SCRIPT_NAME}:${LINENO}] '
  set -x

  export SCRIPT_NAME SCRIPT_BASENAME SCRIPT_DIR LOG_DIR LOG_FILE SCRIPT_START_EPOCH
}

_log_write() {
  local level="$1"
  local message="$2"
  local ts
  ts="$(date +%H:%M:%S)"
  local line="[${ts}] [${level}] ${message}"

  printf "\n%s\n" "${line}" >&3
  printf "\n%s\n" "${line}"
}

log() {
  _log_write "INFO" "$*"
}

warn() {
  _log_write "WARN" "$*"
}

error() {
  _log_write "ERROR" "$*"
}

fail() {
  error "$*"
  printf "See log: %s\n" "${LOG_FILE}" >&3
  exit 1
}

trap_err() {
  local line="$1"
  local cmd="$2"
  local code="$3"

  error "Command failed at line ${line} with exit code ${code}: ${cmd}"
  printf "See log: %s\n" "${LOG_FILE}" >&3
  exit "${code}"
}

register_error_trap() {
  trap 'trap_err "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
}

summary() {
  local next_step="${1:-}"
  local end
  end="$(date +%s)"
  local elapsed=$((end - SCRIPT_START_EPOCH))

  log "Stage complete in ${elapsed}s"
  if [[ -n "${next_step}" ]]; then
    log "Next step: ${next_step}"
  fi
  log "Detailed log: ${LOG_FILE}"
}
