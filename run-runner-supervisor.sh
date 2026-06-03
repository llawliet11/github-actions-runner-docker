#!/bin/bash
# Ephemeral GitHub runner supervisor (robust orchestration).
#
# Why: `--ephemeral` + `restart: unless-stopped` + state-in-container-layer is
# the root of the crash-loop. This supervisor instead runs ONE fresh container
# per job via `docker compose run --rm`: every iteration gets a clean writable
# layer from the image, so a stale .runner file or an interrupted self-update
# can never accumulate across jobs. The compose `restart:` policy is irrelevant
# here (it is ignored by `run`); this loop owns the lifecycle.
#
# Usage:
#   ./run-runner-supervisor.sh [ENV_FILE] [PROJECT_NAME]
#   ./run-runner-supervisor.sh .env.cisgenics
#   ./run-runner-supervisor.sh .env.llab_dashboard
#
# Run it under a process manager (systemd / tmux / nohup) since it stays in the
# foreground. Ctrl-C / SIGTERM stops it after the current job (the container's
# own trap deregisters the runner from GitHub on the way out).
#
# Concurrency: this gives ONE runner = ONE job at a time. For N parallel
# runners, launch N supervisors (distinct PROJECT_NAME each).
set -euo pipefail

ENV_FILE="${1:-.env}"
if [ ! -f "${ENV_FILE}" ]; then
    echo "ERROR: env file '${ENV_FILE}' not found" >&2
    exit 1
fi

# compose project names must be lowercase alnum/dash; derive a sane default.
default_project="runner-$(basename "${ENV_FILE}" | sed 's/^\.//; s/[^A-Za-z0-9]/-/g' | tr 'A-Z' 'a-z')"
PROJECT_NAME="${2:-${default_project}}"

COMPOSE=(docker compose --env-file "${ENV_FILE}" -p "${PROJECT_NAME}")

echo "Supervisor starting: env-file=${ENV_FILE} project=${PROJECT_NAME}"
echo "Building image (cached if up to date)..."
"${COMPOSE[@]}" build

stop=0
trap 'echo "Supervisor: stop requested, finishing current job then exiting"; stop=1' INT TERM

while [ "${stop}" -eq 0 ]; do
    echo "$(date -u +%FT%TZ) launching fresh ephemeral runner container"
    rc=0
    "${COMPOSE[@]}" run --rm github-runner || rc=$?
    echo "$(date -u +%FT%TZ) runner exited (rc=${rc}); relaunching"
    # Brief backoff so a fast-failing config doesn't hot-loop the host.
    [ "${stop}" -eq 0 ] && sleep 2
done

echo "Supervisor stopped."
