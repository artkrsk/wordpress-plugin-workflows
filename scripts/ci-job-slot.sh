#!/usr/bin/env bash
# Hold one of CI_JOB_SLOTS host-wide job slots for as long as this job's Runner.Worker lives.
#
# Wired once in /etc/actions-runner/common.env as ACTIONS_RUNNER_HOOK_JOB_STARTED, so every
# runner service on the box goes through it. The box runs one repo-scoped runner service per
# repo (a personal account cannot share runners), GitHub's `concurrency:` only serializes jobs
# within one repository, and ci.slice caps the runners' MEMORY but not their NUMBER: a push to
# every repo at once starts a job per runner, they thrash inside the slice's 4 GB, load climbs
# past 100 and GitHub drops them as "runner lost communication". This is the missing cap on
# the number of jobs.
#
# How it works: the hook runs inside the job (its output appears under "Set up runner"), so it
# can hold the job until a slot is free. Each slot is a file under /run/lock/ci-job-slot; a
# detached holder takes `flock` on it and keeps it while the job's Runner.Worker pid exists,
# then exits. The lock lives exactly as long as the worker: a cancelled job, a killed runner or
# a reboot (tmpfs) frees the slot with no release hook, pid file or marker. GitHub's
# `timeout-minutes` keeps counting while a job waits here, so the heavy jobs in the reusable
# workflows carry timeouts with room for it.
#
# Tuning (common.env; runners read it at service start, so restart them after a change):
#   CI_JOB_SLOTS      concurrent jobs allowed on the host (default 3)
#   CI_JOB_SLOT_WAIT  seconds to wait for a slot before failing the job (default 5400)
# Watching: `ls /run/lock/ci-job-slot`, `pgrep -fa ci-job-slot`, `journalctl -t ci-job-slot`.
# Hand test: CI_JOB_SLOT_WORKER_PID=<pid of a `sleep 600 &`> ./ci-job-slot.sh
set -euo pipefail

SLOTS="${CI_JOB_SLOTS:-3}"
WAIT_SECONDS="${CI_JOB_SLOT_WAIT:-5400}"
LOCKDIR=/run/lock/ci-job-slot

log() {
  echo "ci-job-slot: $1"
  logger -t ci-job-slot "$1" || true
}

# The job's Runner.Worker is an ancestor of this hook. /proc/PID/stat is "pid (comm) state
# ppid ..."; comm can contain spaces and parens, so cut past the last ") " before reading fields.
worker="${CI_JOB_SLOT_WORKER_PID:-}"
if [ -z "$worker" ]; then
  p=$$
  while [ "$p" -gt 1 ]; do
    read -r stat 2>/dev/null <"/proc/$p/stat" || break
    comm=${stat#*(}
    comm=${comm%)*}
    if [ "$comm" = "Runner.Worker" ]; then
      worker=$p
      break
    fi
    rest=${stat##*") "}
    read -ra fields <<<"$rest"
    p=${fields[1]}
  done
fi
if [ -z "$worker" ]; then
  log "no Runner.Worker ancestor - not inside a job, not gating"
  exit 0
fi

mkdir -p "$LOCKDIR"

# Take one slot if it is free. The holder runs in its own session (setsid) so it outlives this
# hook and the step's process group. It prints "ok" only after flock succeeded, then closes its
# stdout and idles until the worker pid is gone. If no "ok" arrives in time the holder is killed,
# so a slow box can never leave a slot held by a holder this hook gave up on.
try_slot() {
  local slot="$LOCKDIR/$1" reply="" holder
  read -r -t 30 reply < <(
    # shellcheck disable=SC2016  # $1/$2 are the holder's own positional args, on purpose
    setsid bash -c '
      exec 9>"$1"
      flock -n -x 9 || exit 3
      echo ok
      exec >/dev/null 2>&1
      while [ -d "/proc/$2" ]; do sleep 5; done
    ' _ "$slot" "$worker"
  ) || true
  holder=$!
  if [ "$reply" = ok ]; then
    return 0
  fi
  kill "$holder" 2>/dev/null || true
  return 1
}

deadline=$((SECONDS + WAIT_SECONDS))
announced=0
while :; do
  for i in $(seq 1 "$SLOTS"); do
    if try_slot "$i"; then
      log "holding slot $i/$SLOTS for worker $worker"
      exit 0
    fi
  done
  if [ "$announced" = 0 ]; then
    log "all $SLOTS host slots busy - waiting (up to ${WAIT_SECONDS}s)"
    announced=1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    log "no host slot after ${WAIT_SECONDS}s - failing the job instead of overloading the host"
    exit 1
  fi
  sleep 5
done
