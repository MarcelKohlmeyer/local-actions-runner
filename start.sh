#!/bin/bash

REPOSITORY=$REPO
ACCESS_TOKEN=$TOKEN

# Each runner gets its own docker daemon, so parallel jobs (e.g. sharded tests) on
# different runners don't share ports, containers or networks
sudo dind dockerd > ~/dockerd.log 2>&1 &
until docker info > /dev/null 2>&1; do
    if ! sudo kill -0 $! 2> /dev/null; then
        echo "dockerd failed to start:" >&2
        cat ~/dockerd.log >&2
        exit 1
    fi
    sleep 1
done

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
