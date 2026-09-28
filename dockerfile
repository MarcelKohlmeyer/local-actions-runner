FROM ubuntu:26.04 AS runner-download

ARG RUNNER_VERSION="2.337.0"

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
	&& mkdir /actions-runner \
	&& curl -fsSL https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
	| tar xz -C /actions-runner

FROM docker:29-dind AS dind

FROM ubuntu:26.04

ARG DEBIAN_FRONTEND=noninteractive

ENV DOTNET_INSTALL_DIR=/home/docker/.dotnet \
    RUNNER_TOOL_CACHE=/home/docker/_tool \
    AGENT_TOOLSDIRECTORY=/home/docker/_tool

COPY --from=runner-download --chown=1001:1001 /actions-runner /home/docker/actions-runner
# Prepares cgroups and mounts for running dockerd inside a (privileged) container
COPY --from=dind /usr/local/bin/dind /usr/local/bin/dind

RUN apt-get update && apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends sudo ca-certificates git curl jq \
	   build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip \
	&& install -m 0755 -d /etc/apt/keyrings \
	&& curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
	&& echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
	   > /etc/apt/sources.list.d/docker.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
	&& /home/docker/actions-runner/bin/installdependencies.sh \
	&& groupadd -g 1001 runner \
	&& useradd -m -u 1001 -g runner -G docker docker \
	&& mkdir -p /home/docker/.dotnet /home/docker/_tool \
	&& chown docker:runner /home/docker /home/docker/.dotnet /home/docker/_tool \
	&& echo "docker ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/docker \
	# PAM account validation fails for every user on some hosts (privileged container), breaking sudo
	&& echo "Defaults !pam_acct_mgmt" >> /etc/sudoers.d/docker \
	&& chmod 0440 /etc/sudoers.d/docker \
	&& visudo -c -q \
	&& apt-get clean && rm -rf /var/lib/apt/lists/*

COPY start.sh start.sh

RUN chmod +x start.sh

# start.sh launches dockerd as root and then drops to the docker user
ENTRYPOINT ["./start.sh"]
