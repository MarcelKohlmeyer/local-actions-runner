#!/bin/bash
# Idle deep clean, started as root in the background by start.sh. Every CLEANUP_INTERVAL
# seconds it checks whether the runner is idle, removes what an interrupted job left
# behind, and frees space when the disk under /var/lib/docker is fuller than
# CLEANUP_THRESHOLD percent. It only logs what it removed. See README.md.
#
# Usage: idle-cleanup.sh [--once]   (--once runs a single iteration, for testing)

# Globs without matches expand to nothing (e.g. an empty tool cache)
shopt -s nullglob

log() { echo "idle-cleanup: $*"; }

# Prints the setting $1, or the default $2 when it isn't a whole number from $3 to $4
setting() {
    local value=${!1:-$2}
    if [[ $value =~ ^[0-9]{1,6}$ ]] && ((10#$value >= $3 && 10#$value <= $4)); then
        echo $((10#$value))
    else
        log "invalid $1='$value', using $2" >&2
        echo "$2"
    fi
}

INTERVAL=$(setting CLEANUP_INTERVAL 300 1 999999)
THRESHOLD=$(setting CLEANUP_THRESHOLD 70 0 100)
# Checkouts in _work that nothing touched for this many hours may be removed
CHECKOUT_HOURS=$(setting CLEANUP_CHECKOUT_HOURS 24 0 999999)
# Backstop for _diag files the runner's own log retention (ENV in the dockerfile) misses
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
# Checkouts are renamed into here before deletion. Same filesystem as _work (the
# container's writable layer), but outside it, so the runner never sees it.
TRASH=/home/docker/.cleanup-trash

# A job is running while there is a Runner.Worker process. pgrep exits 1 for "no match",
# anything else (0 or an error) counts as busy, so an error never starts a clean.
busy() {
    pgrep -f '(^|/)Runner\.Worker( |$)' > /dev/null
    [ $? -ne 1 ]
}

# Usage in percent. This is the host's filesystem, shared by all runners on the host.
usage() { df --output=pcent /var/lib/docker | tail -n 1 | tr -dc '0-9'; }

cap_dockerd_log() {
    # dockerd appends (>>), so it keeps writing at the new end after truncation
    if [ "$(stat -c %s "$DOCKERD_LOG" 2> /dev/null || echo 0)" -gt "$DOCKERD_LOG_MAX" ]; then
        truncate -s 0 "$DOCKERD_LOG" && log "truncated $DOCKERD_LOG"
    fi
}

# A job whose worker crashed never ran job-completed.sh, so do that now
remove_leftovers() {
    if [ -n "$(docker ps -aq)$(docker volume ls -q)$(docker network ls -q --filter type=custom)" ]; then
        log "removing leftovers of an interrupted job"
        job-completed.sh 2>&1 | sed '/^$/d; s/^/idle-cleanup: /'
    fi
}

# Runs "docker $1 prune -af" and logs the reclaimed space, unless it was nothing
prune() {
    local total
    total=$(docker "$1" prune -af 2> /dev/null | tail -n 1 | tr -s '\t' ' ')
    case $total in
        '' | *' 0B') ;;
        *) log "disk above ${THRESHOLD}%, docker $1 prune: $total" ;;
    esac
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
    mkdir -p "$TRASH"
    for dir in "$RUNNER"/_work/[!_]*/; do
        dir=${dir%/}
        # Depth 3 reaches <repo>/<repo>/.git/*, which every git fetch/checkout updates
        [ -z "$(find "$dir" -maxdepth 3 -mmin -$((CHECKOUT_HOURS * 60)) -print -quit)" ] || continue
        # Stop once a job starts. The rename is atomic, so a job starting right after it
        # finds no directory and creates a fresh one instead of a half-deleted one.
        busy && return
        mv --no-copy -T "$dir" "$TRASH/${dir##*/}" || continue
        rm -rf "${TRASH:?}/${dir##*/}"
        log "disk at $(usage)%, removed checkout $dir"
    done
}

deep_clean() {
    # Hold the lock while cleaning, job-started.sh waits for it
    flock -w 60 9 || return
    busy && return

    remove_leftovers
    # Finish deletions a killed earlier run left behind
    rm -rf "$TRASH"

    [ "$(usage)" -gt "$THRESHOLD" ] || return
    prune image
    prune builder
    find "$RUNNER/_diag" -type f -mtime +"$DIAG_DAYS" -print -delete 2> /dev/null | sed 's/^/idle-cleanup: removed log /'
    trim_tools

    [ "$(usage)" -gt "$THRESHOLD" ] && remove_checkouts
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
