FROM ubuntu:26.04

ARG RUNNER_VERSION="2.337.0"

ARG DEBIAN_FRONTEND=noninteractive

ENV DOTNET_INSTALL_DIR=/home/docker/.dotnet \
    RUNNER_TOOL_CACHE=/home/docker/_tool \
    AGENT_TOOLSDIRECTORY=/home/docker/_tool

RUN apt update -y && apt upgrade -y && useradd -m docker

RUN mkdir -p /home/docker/.dotnet /home/docker/_tool \
	&& chown -R docker:docker /home/docker

RUN apt-get update && apt-get install -y sudo \
	&& echo "docker ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/docker \
	&& chmod 0440 /etc/sudoers.d/docker

RUN apt install -y --no-install-recommends git curl jq build-essential libssl-dev libffi-dev python3 python3-venv python3-dev python3-pip

# add Docker:
RUN apt-get update && apt-get install -y ca-certificates curl \
	&& install -m 0755 -d /etc/apt/keyrings \
	&& curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
	&& echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \ 
	> /etc/apt/sources.list.d/docker.list \
	&& apt-get update \
	&& apt-get install -y docker-ce-cli docker-buildx-plugin docker-compose-plugin \
	&& rm -rf /var/lib/apt/lists/*

RUN cd /home/docker && mkdir actions-runner && cd actions-runner \
	&& curl -O -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
	&& tar xzf ./actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

RUN chown -R docker ~docker && /home/docker/actions-runner/bin/installdependencies.sh

COPY start.sh start.sh

RUN chmod +x start.sh

USER docker

ENTRYPOINT ["./start.sh"]
