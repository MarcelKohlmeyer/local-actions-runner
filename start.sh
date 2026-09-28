#!/bin/bash

REPOSITORY=$REPO
ACCESS_TOKEN=$TOKEN

# Job containers are started by the dind daemon, which resolves bind-mount sources in its
# own filesystem. The runner (including externals/ and _work/) therefore has to live in a
# directory shared with dind under the same path. Each replica gets its own subdirectory.
if [ -z "${RUNNER_DATA_DIR}" ]; then
    echo "RUNNER_DATA_DIR is not set" >&2
    exit 1
fi

# Replicas share dind's network namespace and with it its hostname, so it can't be used
# to tell them apart
RUNNER_NAME="runner-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
INSTANCE_DIR="${RUNNER_DATA_DIR}/${RUNNER_NAME}"

sudo mkdir -p "${INSTANCE_DIR}"
sudo chown docker:docker "${RUNNER_DATA_DIR}" "${INSTANCE_DIR}"
cp -a /home/docker/actions-runner/. "${INSTANCE_DIR}/"

# The tool cache is mounted into job containers as well (/__t)
export RUNNER_TOOL_CACHE="${INSTANCE_DIR}/_tool"
export AGENT_TOOLSDIRECTORY="${RUNNER_TOOL_CACHE}"

REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${REPOSITORY}/actions/runners/registration-token | jq .token --raw-output)

cd "${INSTANCE_DIR}"

./config.sh --url https://github.com/${REPOSITORY} --token ${REG_TOKEN} --name ${RUNNER_NAME}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
    # Job containers may have left root-owned files behind
    sudo rm -rf "${INSTANCE_DIR}"
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh & wait $!
