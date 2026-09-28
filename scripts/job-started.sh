#!/bin/bash
# Job started hook (ACTIONS_RUNNER_HOOK_JOB_STARTED), runs as the docker user before
# every job. Waits while idle-cleanup.sh holds the cleanup lock, so a job never starts
# in the middle of a prune. It must never fail the job, so it always exits 0.

# The runner starts hooks with "bash -e -o pipefail", keep going on errors instead
set +e +o pipefail

# Created by idle-cleanup.sh (root, mode 0644). flock opens it read-only, which is enough.
LOCK=/run/runner-cleanup.lock
# Don't block a job forever if the cleanup hangs
TIMEOUT=1800

if [ -e "$LOCK" ] && ! flock -n -s "$LOCK" true; then
    echo "Waiting for the idle cleanup to finish..."
    flock -w "$TIMEOUT" -s "$LOCK" true || echo "Cleanup still running after ${TIMEOUT}s, starting anyway"
fi

exit 0
