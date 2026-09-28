#!/bin/bash

REPOSITORY=$REPO
ACCESS_TOKEN=$TOKEN

# Job containers are started by the host's docker daemon (socket handthrough), which
# resolves bind-mount sources on the host. The runner (including externals/ and _work/)
# therefore has to live in a directory that exists under the same path on the host and
# in this container. RUNNER_DATA_DIR is mounted 1:1, each replica gets its own subdirectory.
if [ -z "${RUNNER_DATA_DIR}" ]; then
    echo "RUNNER_DATA_DIR is not set" >&2
    exit 1
fi

INSTANCE_DIR="${RUNNER_DATA_DIR}/${HOSTNAME}"

sudo rm -rf "${INSTANCE_DIR}"
sudo mkdir -p "${INSTANCE_DIR}"
sudo chown docker:docker "${RUNNER_DATA_DIR}" "${INSTANCE_DIR}"
cp -a /home/docker/actions-runner/. "${INSTANCE_DIR}/"

# The tool cache is mounted into job containers as well (/__t)
export RUNNER_TOOL_CACHE="${INSTANCE_DIR}/_tool"
export AGENT_TOOLSDIRECTORY="${RUNNER_TOOL_CACHE}"

REG_TOKEN=$(curl -X POST -H "Authorization: token ${ACCESS_TOKEN}" -H "Accept: application/vnd.github+json" https://api.github.com/repos/${REPOSITORY}/actions/runners/registration-token | jq .token --raw-output)

cd "${INSTANCE_DIR}"

./config.sh --url https://github.com/${REPOSITORY} --token ${REG_TOKEN}

cleanup() {
    echo "Removing runner..."
    ./config.sh remove --unattended --token ${REG_TOKEN}
    # Job containers may have left root-owned files behind
    sudo rm -rf "${INSTANCE_DIR}"
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh & wait $!
