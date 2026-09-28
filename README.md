# local-actions-runner

Docker image for self-hosted GitHub Actions runners, based on Ubuntu 26.04.

Each runner container starts its **own docker daemon** (docker-in-docker), so jobs can
use `docker`, `docker compose`, container jobs or Testcontainers without sharing ports,
containers or networks with jobs on other runners.

The image also ships git, jq, gnupg, Python 3 and a C/C++ build toolchain. The job user
`docker` has passwordless `sudo` for anything else.

## Usage

The image is published to `ghcr.io/marcelkohlmeyer/local-actions-runner:latest` on every
push to `main`.

```sh
cd deploy
cp example.env .env   # fill in REPO, TOKEN and REPLICA_COUNT
docker compose up -d
```

| Variable        | Description                                                   |
|-----------------|---------------------------------------------------------------|
| `REPO`          | Repository to register the runners for (`owner/repo`)          |
| `TOKEN`         | Personal access token that can create runner registration tokens for `REPO` |
| `REPLICA_COUNT` | Number of runners to start                                    |

Runners register on start and deregister when the container is stopped.

Notes:

- The container must run `privileged` so it can start dockerd.
- `/var/lib/docker` has to be a volume, as dockerd can't use overlay2 on top of the
  container's overlay filesystem.

## Building

```sh
docker build . -t local-actions-runner
```

The runner version is set via the `RUNNER_VERSION` build argument.

## License

[MIT](LICENSE)
