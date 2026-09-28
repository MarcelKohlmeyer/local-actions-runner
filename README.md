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
| `CLEANUP_THRESHOLD` | Disk usage in percent above which the idle deep clean runs (default `70`) |
| `CLEANUP_INTERVAL` | Seconds between idle deep clean checks (default `300`)     |
| `CLEANUP_CHECKOUT_HOURS` | Age in hours after which an untouched checkout may be removed (default `24`) |

Runners register on start and deregister when the container is stopped.

Notes:

- The container must run `privileged` so it can start dockerd.
- `/var/lib/docker` has to be a volume, as dockerd can't use overlay2 on top of the
  container's overlay filesystem.
- `docker compose down` without `-v` leaves the anonymous `/var/lib/docker` volumes of
  all runners behind on the host, and `up` creates new ones. Use `docker compose down -v`,
  or remove orphaned volumes later with `docker volume prune` on the host.

## Storage cleanup

Runners are reused for many jobs, so the image cleans up after itself:

- **After every job** (`ACTIONS_RUNNER_HOOK_JOB_COMPLETED`, `scripts/job-completed.sh`):
  removes all containers in the runner's docker daemon, prunes unused volumes (named ones
  too) and networks, and clears `/tmp`. Errors are ignored, it never fails the job.
- **Idle deep clean** (`scripts/idle-cleanup.sh`, started as root by `start.sh`): every
  `CLEANUP_INTERVAL` seconds it takes a lock, checks that no job is running (no
  `Runner.Worker` process) and that the disk holding `/var/lib/docker` is above
  `CLEANUP_THRESHOLD` percent. If so it
  1. prunes all unused images and the whole build cache,
  2. deletes runner `_diag` logs older than 7 days,
  3. keeps only the 3 most recently installed versions of each tool in `~/_tool`,
  4. if the disk is still above the threshold, removes `_work/<repo>` checkouts that
     nothing touched for `CLEANUP_CHECKOUT_HOURS`. Runner directories such as
     `_work/_actions` and `_work/_temp` are never touched.

  It logs what it removed to the container log.
- **Before every job** (`ACTIONS_RUNNER_HOOK_JOB_STARTED`, `scripts/job-started.sh`):
  waits while the deep clean holds its lock (`/run/runner-cleanup.lock`, at most 30
  minutes), so a job never starts in the middle of a prune.
- **Build cache and logs**: `/etc/docker/daemon.json` enables BuildKit garbage collection
  with a 10GB cap and limits the logs of job containers (json-file, 3 x 10MB).
  `/var/log/dockerd.log` is truncated once it exceeds 10MB, and `deploy/compose.yml`
  limits the runner containers' own logs on the host the same way.

The threshold is measured with `df` on `/var/lib/docker`. Since the anonymous volumes
live on the host's filesystem, that is the **host's** disk usage, shared by all runners
and anything else on it. Once the host goes above the threshold, every idle runner
cleans, and while other data keeps it above, they do so every interval. Pruning images
means the next jobs pull them again. Checkouts are only removed once they are older than
`CLEANUP_CHECKOUT_HOURS`, so busy repositories keep theirs; raise the value to keep
checkouts longer. Set the threshold with the whole host in mind. Runners start their
checks at a random offset within the interval so they don't all clean at once.

## Building

```sh
docker build . -t local-actions-runner
```

The runner version is set via the `RUNNER_VERSION` build argument.

## License

[MIT](LICENSE)
