#!/bin/bash
# Entrypoint: starts a private docker daemon, then registers this container as a
# self-hosted runner for $REPO and removes the registration again on shutdown.
#
# Required environment:
#   REPO   owner/repo the runner is registered for
#   TOKEN  PAT allowed to create runner registration tokens for REPO

REPOSITORY=$REPO
ACCESS_TOKEN=$TOKEN

# Each runner gets its own docker daemon, so parallel jobs (e.g. sharded tests) on
# different runners don't share ports, containers or networks. The container starts as
# root to launch dockerd, then re-executes this script as the docker user.
if [ "$(id -u)" = "0" ]; then
    # /run survives container restarts, a stale pid file keeps dockerd from starting
    rm -rf /run/docker.pid /run/docker /run/containerd

    # Append, so idle-cleanup.sh can truncate the log without leaving a sparse file
    : > /var/log/dockerd.log
    dind dockerd >> /var/log/dockerd.log 2>&1 &
    until docker info > /dev/null 2>&1; do
        if ! kill -0 $! 2> /dev/null; then
            echo "dockerd failed to start:" >&2
            cat /var/log/dockerd.log >&2
            exit 1
        fi
        sleep 1
    done

    # Frees disk space while the runner is idle, keeps running as root (see README.md)
    idle-cleanup.sh &

    # setpriv doesn't go through PAM (unlike sudo/su)
    export HOME=/home/docker USER=docker
    exec setpriv --reuid=docker --regid=runner --init-groups "$0" "$@"
fi

# Exchange the PAT for a short-lived runner registration token
REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${REPOSITORY}/actions/runners/registration-token | jq .token --raw-output)

cd /home/docker/actions-runner

./config.sh --url https://github.com/${REPOSITORY} --token ${REG_TOKEN}

# Deregister on shutdown so stopped containers don't pile up as offline runners
cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Run in the background and wait, so bash can handle the signals above immediately
./run.sh & wait $!
