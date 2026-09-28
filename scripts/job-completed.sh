#!/bin/bash
# Job completed hook (ACTIONS_RUNNER_HOOK_JOB_COMPLETED), runs as the docker user after
# every job. Removes what the job left behind in this runner's own docker daemon and in
# /tmp. It must never fail the job, so errors are ignored and it always exits 0.

# The runner starts hooks with "bash -e -o pipefail", keep going on errors instead
set +e +o pipefail

echo "Removing leftover containers, volumes and networks"
docker ps -aq | xargs -r docker rm -f > /dev/null
# -a also removes named volumes, not only anonymous ones
docker volume prune -af
docker network prune -f

echo "Clearing /tmp"
# Jobs may leave root-owned files behind (sudo, containers with bind mounts)
sudo -n find /tmp -mindepth 1 -delete

exit 0
