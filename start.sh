#!/bin/bash

REPOSITORY=$REPO
ACCESS_TOKEN=$TOKEN

# Each runner gets its own docker daemon, so parallel jobs (e.g. sharded tests) on
# different runners don't share ports, containers or networks. The container starts as
# root to launch dockerd, then re-executes this script as the docker user.
if [ "$(id -u)" = "0" ]; then
    # /run survives container restarts, a stale pid file keeps dockerd from starting
    rm -rf /run/docker.pid /run/docker /run/containerd

    dind dockerd > /var/log/dockerd.log 2>&1 &
    until docker info > /dev/null 2>&1; do
        if ! kill -0 $! 2> /dev/null; then
            echo "dockerd failed to start:" >&2
            cat /var/log/dockerd.log >&2
            exit 1
        fi
        sleep 1
    done

    # setpriv doesn't go through PAM (unlike sudo/su)
    export HOME=/home/docker USER=docker
    exec setpriv --reuid=docker --regid=runner --init-groups "$0" "$@"
fi

REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${REPOSITORY}/actions/runners/registration-token | jq .token --raw-output)

cd /home/docker/actions-runner

./config.sh --url https://github.com/${REPOSITORY} --token ${REG_TOKEN}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh & wait $!
