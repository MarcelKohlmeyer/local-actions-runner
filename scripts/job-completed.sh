#!/bin/bash
# Job completed hook (ACTIONS_RUNNER_HOOK_JOB_COMPLETED), runs as the docker user after
# every job. Removes what the job left behind in this runner's own docker daemon and in
# /tmp. It must never fail the job, so errors are ignored and it always exits 0.
# idle-cleanup.sh also runs it (as root) when a crashed job never got here.

# The runner starts hooks with "bash -e -o pipefail", keep going on errors instead
set +e +o pipefail

# Seconds per command, so a wedged dockerd or a hung mount can't hang the job
T=120

echo "Removing leftover containers, volumes and networks"
timeout $T docker ps -aq | xargs -r timeout $T docker rm -f > /dev/null
# -a also removes named volumes, not only anonymous ones
timeout $T docker volume prune -af
timeout $T docker network prune -f

echo "Clearing /tmp"
# sudo: jobs may leave root-owned files behind. -xdev: leave mounts under /tmp alone.
# The runner's .NET diagnostic endpoints stay.
timeout $T sudo -n find /tmp -xdev -mindepth 1 \
    ! -name 'dotnet-diagnostic-*' ! -name 'clr-debug-pipe-*' -delete 2> /dev/null

exit 0
