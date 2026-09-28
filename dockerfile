# Self-hosted GitHub Actions runner that brings its own docker daemon.
# See README.md for usage and deploy/ for a compose setup.

# --- Stage 1: download the GitHub Actions runner ------------------------------
FROM ubuntu:26.04 AS runner-download

ARG RUNNER_VERSION="2.337.0"

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
	&& mkdir /actions-runner \
	&& curl -fsSL https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
	| tar xz -C /actions-runner

# --- Stage 2: source of the dind helper script --------------------------------
FROM docker:29-dind AS dind

# --- Final image ----------------------------------------------------------------
FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

# Keep tool installs from setup-* actions inside the runner user's home
ENV DOTNET_INSTALL_DIR=/home/docker/.dotnet \
    RUNNER_TOOL_CACHE=/home/docker/_tool \
    AGENT_TOOLSDIRECTORY=/home/docker/_tool

# Base tooling commonly expected by workflows (git, jq, python, build toolchain)
RUN apt-get update && apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends sudo ca-certificates git curl jq gnupg procps \
	   build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip \
	&& apt-get clean && rm -rf /var/lib/apt/lists/*

# Docker engine, CLI, buildx and compose from Docker's official apt repository
RUN install -m 0755 -d /etc/apt/keyrings \
	&& curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
	&& echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
	   > /etc/apt/sources.list.d/docker.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
	&& apt-get clean && rm -rf /var/lib/apt/lists/*

# Prepares cgroups and mounts for running dockerd inside a (privileged) container
COPY --from=dind /usr/local/bin/dind /usr/local/bin/dind

# The runner itself, owned by the (not yet created) runner user 1001
COPY --from=runner-download --chown=1001:1001 /actions-runner /home/docker/actions-runner

# Native libraries the runner needs (libicu, libssl, ...)
RUN /home/docker/actions-runner/bin/installdependencies.sh \
	&& apt-get clean && rm -rf /var/lib/apt/lists/*

# Unprivileged "docker" user that runs the jobs; it may use the daemon and sudo
RUN groupadd -g 1001 runner \
	&& useradd -m -u 1001 -g runner -G docker docker \
	&& mkdir -p /home/docker/.dotnet /home/docker/_tool \
	&& chown docker:runner /home/docker /home/docker/.dotnet /home/docker/_tool \
	&& echo "docker ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/docker \
	# PAM account validation fails for every user on some hosts (privileged container), breaking sudo
	&& echo "Defaults !pam_acct_mgmt" >> /etc/sudoers.d/docker \
	&& chmod 0440 /etc/sudoers.d/docker \
	&& visudo -c -q

# Build cache GC and log size limits for the runner's docker daemon
COPY daemon.json /etc/docker/daemon.json

# Storage cleanup: job hooks and the idle deep clean started by start.sh (see README.md)
COPY scripts/ /usr/local/bin/
ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/usr/local/bin/job-started.sh \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/usr/local/bin/job-completed.sh \
    # Days the runner keeps its own _diag logs (default 30)
    RUNNER_LOGRETENTION=7 \
    WORKER_LOGRETENTION=7

COPY start.sh /start.sh
RUN chmod +x /start.sh /usr/local/bin/job-started.sh /usr/local/bin/job-completed.sh /usr/local/bin/idle-cleanup.sh

# start.sh launches dockerd as root and then drops to the docker user
ENTRYPOINT ["/start.sh"]
