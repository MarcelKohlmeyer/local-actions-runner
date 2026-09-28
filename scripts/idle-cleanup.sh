#!/bin/bash
# Idle deep clean, started as root in the background by start.sh. Every CLEANUP_INTERVAL
# seconds it checks whether the runner is idle and the disk under /var/lib/docker is
# fuller than CLEANUP_THRESHOLD percent, and if so frees space. See README.md.
#
# Usage: idle-cleanup.sh [--once]   (--once runs a single iteration, for testing)

# Globs without matches expand to nothing (e.g. an empty tool cache)
shopt -s nullglob

INTERVAL=${CLEANUP_INTERVAL:-300}
THRESHOLD=${CLEANUP_THRESHOLD:-70}
# Checkouts in _work that nothing touched for this many hours may be removed
CHECKOUT_HOURS=${CLEANUP_CHECKOUT_HOURS:-24}
# Keep runner _diag logs for this many days
DIAG_DAYS=7
# Keep this many most recently installed versions per tool in the tool cache
TOOL_VERSIONS=3
# Truncate dockerd's log once it grows beyond this size (bytes)
DOCKERD_LOG_MAX=$((10 * 1024 * 1024))

# Outside /tmp (cleared after every job) and not in a sticky directory like /run/lock,
# where fs.protected_regular can refuse flock's O_CREAT open for other users
LOCK=/run/runner-cleanup.lock
RUNNER=/home/docker/actions-runner
TOOLS=${RUNNER_TOOL_CACHE:-/home/docker/_tool}
DOCKERD_LOG=/var/log/dockerd.log

log() { echo "idle-cleanup: $*"; }

# A job is running while there is a Runner.Worker process
busy() { pgrep -f '(^|/)Runner\.Worker( |$)' > /dev/null; }

# Usage in percent. This is the host's filesystem, shared by all runners on the host.
usage() { df --output=pcent /var/lib/docker | tail -n 1 | tr -dc '0-9'; }

cap_dockerd_log() {
    # dockerd appends (>>), so it keeps writing at the new end after truncation
    if [ "$(stat -c %s "$DOCKERD_LOG" 2> /dev/null || echo 0)" -gt "$DOCKERD_LOG_MAX" ]; then
        truncate -s 0 "$DOCKERD_LOG" && log "truncated $DOCKERD_LOG"
    fi
}

# Removes the tool versions beyond the newest TOOL_VERSIONS of every tool
trim_tools() {
    local tool
    for tool in "$TOOLS"/*/; do
        find "$tool" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn \
            | tail -n +$((TOOL_VERSIONS + 1)) | cut -d ' ' -f 2- \
            | while read -r version; do
                rm -rf "$version" && log "removed tool $version"
            done
    done
}

# Removes _work/<repo> checkouts that nothing touched for CHECKOUT_HOURS. Directories
# starting with "_" (_actions, _temp, _PipelineMapping, ...) belong to the runner.
remove_checkouts() {
    local dir
    for dir in "$RUNNER"/_work/[!_]*/; do
        if busy; then
            log "job started, keeping checkouts"
            return
        fi
        # Depth 3 reaches <repo>/<repo>/.git/*, which every git fetch/checkout updates
        if [ -z "$(find "$dir" -maxdepth 3 -mmin -$((CHECKOUT_HOURS * 60)) -print -quit)" ]; then
            rm -rf "$dir" && log "removed checkout $dir"
        fi
    done
}

deep_clean() {
    # Hold the lock while cleaning, job-started.sh waits for it
    flock -w 60 9 || return
    busy && return

    local pcent
    pcent=$(usage)
    [ "$pcent" -gt "$THRESHOLD" ] || return
    log "disk at ${pcent}% (threshold ${THRESHOLD}%), cleaning"

    docker container prune -f > /dev/null
    log "images: $(docker image prune -af | tail -n 1)"
    log "build cache: $(docker builder prune -af | tail -n 1 | tr -s '\t' ' ')"
    find "$RUNNER/_diag" -type f -mtime +"$DIAG_DAYS" -print -delete 2> /dev/null | sed 's/^/idle-cleanup: removed log /'
    trim_tools

    pcent=$(usage)
    if [ "$pcent" -gt "$THRESHOLD" ]; then
        log "disk still at ${pcent}%, removing checkouts untouched for ${CHECKOUT_HOURS}h"
        remove_checkouts
    fi
    log "done, disk at $(usage)%"
}

touch "$LOCK" && chmod 0644 "$LOCK"

if [ "$1" = "--once" ]; then
    cap_dockerd_log
    deep_clean 9< "$LOCK"
    exit 0
fi

# Random start offset, so the runners on a host don't all clean at the same moment
sleep $((RANDOM % INTERVAL))
while true; do
    cap_dockerd_log
    deep_clean 9< "$LOCK"
    sleep "$INTERVAL"
done
