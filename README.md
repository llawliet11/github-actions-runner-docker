# Self-hosted GitHub Actions Runner

This repository contains Docker configurations for running self-hosted GitHub Actions runners. It supports multiple runners with automatic scaling capabilities and is configured to work with AWS deployments.

## Prerequisites

- Docker and Docker Compose installed
- GitHub Personal Access Token (PAT) with `repo` scope for private repositories or `admin:org` scope for organization runners
- AWS credentials configured (if using AWS deployments)

## Files Structure

```text
.
├── Dockerfile
├── docker-compose.yml
├── docker-compose.pull.yml
├── docker-build.sh
├── install-node.sh
├── start.sh
├── run-runner-supervisor.sh
├── systemd/
│   └── github-runner@.service
├── .env.sample
└── README.md
```

## Configuration

### Environment Variables

Create a `.env` file with the following variables:

```env
# GitHub Runner Configuration
RUNNER_REPO=https://github.com/your-org/your-repo
RUNNER_TOKEN=your_runner_token  # Optional if using GITHUB_PAT
RUNNER_VERSION=2.334.0
RUNNER_LABELS=self-hosted

# Node.js Configuration
NODE_VERSION=22

# GitHub Authentication (Recommended over RUNNER_TOKEN)
GITHUB_PAT=your_personal_access_token
GITHUB_OWNER=your-org-or-username
GITHUB_REPOSITORY=your-repository-name
```

### Building the Runner Image

Normally you do not build by hand - `docker compose build` (or the supervisor)
tags the image for you, one tag per clone (see
[Per-runner customisation](#per-runner-customisation)). Build directly only when
you need a specific platform:

```bash
# Using Docker buildx for AMD64 platform
docker buildx build --platform linux/amd64 -t github-runner:"${PWD##*/}" --load .
```

> The tag must match what compose expects, which defaults to the compose project
> name (the clone's directory name), **not** `github-runner:latest`. Check with
> `docker compose config | grep image:`.

## Per-runner customisation

Several clones of this repo commonly share one host, one per runner. **Do not
edit the tracked `docker-compose.yml` to tell them apart** - those edits are
invisible to the next clone, and `git pull` will conflict with or clobber them.
Everything that differs per runner is driven from the env file instead:

| Variable | Default | What it is for |
| --- | --- | --- |
| `RUNNER_IMAGE_TAG` | compose project name (the clone's directory name) | The image tag this clone builds and runs. The default already gives every clone its own tag; set it only to pin one, or to `latest` to deliberately share an image between clones. |
| `RUNNER_RESTART_POLICY` | `unless-stopped` | Restart policy for the service model. Keep the default there - see [Which orchestration model](#which-orchestration-model). Ignored under the supervisor model. |
| `DOCKERFILE` | `Dockerfile` | `Dockerfile.docker-build` for jobs that need the docker CLI. |
| `RUNNER_LABELS` | `self-hosted` | Labels this runner registers with. |
| `RUNNER_VERSION` | `2.334.0` | Keep in sync with the `ARG RUNNER_VERSION` default - see [Maintenance](#updating-runner-version). |
| `DOCKER_SOCK_GID` | `999` | GID of this host's `/var/run/docker.sock`. Required for any repo whose jobs declare `services:` containers - see [Jobs that use `services:` containers](#jobs-that-use-services-containers). |

For anything the table does not cover, add a `docker-compose.override.yml` next
to the compose file. Compose merges it automatically on every command, and it is
gitignored, so the tracked template stays pristine:

```yaml
# docker-compose.override.yml - host-specific, never committed
services:
  github-runner:
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 4G
        reservations:
          cpus: "0.5"
          memory: 1G
```

> Compose deep-merges, so a partial `limits:` block leaves the template's
> `reservations:` untouched - override both or you can end up reserving more
> than you allow.

### Jobs that use `services:` containers

A workflow with a `services:` block makes the runner create those containers as
**siblings**, through the mounted docker socket - not as children. Two
consequences, neither of which the defaults cover:

**1. The socket's group.** The socket is owned by a group on the *host*; the
`docker` group baked into the image is a different thing and cannot be relied on
to match. Set `DOCKER_SOCK_GID` in the env file to the real value
(`stat -c '%g' /var/run/docker.sock`). Symptom when it is wrong: the runner
starts and idles happily, then the first job with a `services:` block dies at
`Initialize containers` with `permission denied ... /var/run/docker.sock`.

**2. Host networking.** Sibling containers publish their ports on the *host*
network namespace, so a job talking to `localhost:<port>` only reaches them if
the runner shares that namespace. Add it as an override:

```yaml
# docker-compose.override.yml
services:
  github-runner:
    network_mode: host
```

The template deliberately declares no `networks:` key so this stays a one-line
override - compose refuses `network_mode` and `networks` together, and a merge
can add keys but never remove them.

> Host networking puts every such runner in **one shared host port space**. It is
> safe with a single `--ephemeral` runner because jobs run one at a time. Before
> scaling past one replica, give the service containers distinct host ports, or
> publish only the container port and resolve the assigned one at runtime with
> `${{ job.services.<id>.ports['<port>'] }}`.

### Never set `container_name`

A fixed `container_name` is actively harmful for an `--ephemeral` runner: it
lets Docker restart the **same** container, so the same runner name re-registers
over a registration GitHub still believes is busy. The runner then logs
"Listening for Jobs" while the API reports it `offline busy=true` and hands it no
work - it looks alive and is silently dead. Use a distinct compose project
(`docker compose -p <name>`) per runner instead, which is what the supervisor
does.

### Migrating a clone that already has local compose edits

Keep a copy of the local edits, then take the template back cleanly - do not
`git stash pop` across this pull, the compose file changed and the pop will
conflict:

```bash
git diff docker-compose.yml > ../"${PWD##*/}"-compose.local.patch
git checkout -- docker-compose.yml
git pull origin main
cat ../"${PWD##*/}"-compose.local.patch      # re-read: most of it is now redundant
```

Then re-express each edit. Most local edits on a working runner are load-bearing
- treat them as requirements to translate, not as noise to discard:

| Local edit | Where it goes now |
| --- | --- |
| `dockerfile: Dockerfile.docker-build` | `DOCKERFILE=Dockerfile.docker-build` in the env file |
| a distinct `image:` tag | nothing to do - the default already derives one per clone |
| `network_mode: host` | `docker-compose.override.yml` (the template no longer declares `networks:`, so this now merges cleanly) |
| `group_add: ["<gid>"]` | `DOCKER_SOCK_GID=<gid>` in the env file |
| raised `deploy.resources` | `docker-compose.override.yml` |
| `container_name:` | **drop it** - this one really is harmful, see above |
| `RUNNER_NAME` passthrough | drop it; `start.sh` derives the name from the container hostname and ignores the variable |

Verify before rebuilding:

```bash
docker compose config | grep -E 'image:|restart:|container_name:'
git status --porcelain docker-compose.yml   # expect: empty
```

Expected: `image:` ends in this clone's directory name, and no `container_name:`
line at all. If `image:` still reads `github-runner:latest`, your Docker Compose
is too old to expose `COMPOSE_PROJECT_NAME` for interpolation - it falls back
safely, but set `RUNNER_IMAGE_TAG` explicitly in the env file to get the
isolation.

> Changing the image tag means the first `up -d` after this pull rebuilds under
> the new tag. Clones that previously shared `github-runner:latest` each get
> their own copy; reclaim the old one with `docker image rm github-runner:latest`
> once every clone has migrated.

## Usage

### Starting Runners

1. Start with default 1 runner
```bash
docker compose up -d
```

2. Scale to a specific number of runners:
```bash
docker compose up -d --scale github-runner=5
```

> Note: `--scale=N` is passed on the CLI, not via a `replicas:` key. Preserve
> `--scale=N` on every `up`/recreate or you silently drop back to 1 runner.

### Which orchestration model

Two supported models. The default `docker-compose.yml` ships the service model
because that is what `docker compose up -d` has to be; the supervisor model is
the more robust one.

| | Service model | Supervisor model (recommended) |
| --- | --- | --- |
| Command | `docker compose up -d` | `./run-runner-supervisor.sh <env-file>` |
| Container per job | reuses one writable layer | fresh from the image, every job |
| `restart:` policy | **load-bearing** - see below | ignored (`compose run` does not honour it) |
| Multiple runners | `--scale=N` | N supervisors, distinct project names |

`--ephemeral` makes the runner process exit after **one** job. In the service
model the `restart:` policy is therefore the only thing that brings the next
runner up - drop it and `docker compose up -d` gives you exactly one job, ever.
So the default stays `unless-stopped`.

What made that combination the root of the historical crash-loop was never the
policy on its own, it was the runner state the restarted container kept in its
writable layer: a stale `.runner` file, or a `bin/` left half-swapped by an
interrupted self-update. `start.sh` now clears the former and self-heals the
latter on every start, so a restart is a clean re-configure. Set
`RUNNER_RESTART_POLICY=no` if you want the old behaviour back.

The supervisor model removes the class of bug rather than repairing it, by
running **one fresh container per job**:

```bash
# Foreground supervisor: a clean container (and clean writable layer) per job.
./run-runner-supervisor.sh .env.cisgenics
./run-runner-supervisor.sh .env.llab_dashboard
```

It stays in the foreground, so run it under a process manager. Ctrl-C / SIGTERM
stops it after the current job finishes. For N parallel runners, start N
supervisors with distinct project names. No state survives across jobs, so a
stale registration or an interrupted self-update can never accumulate.

#### Running the supervisor under systemd

`systemd/github-runner@.service` is a templated **user** unit - no root needed.
The instance name is the clone's directory name:

```bash
mkdir -p ~/.config/systemd/user
cp systemd/github-runner@.service ~/.config/systemd/user/
loginctl enable-linger "$USER"        # survives logout; required
systemctl --user daemon-reload
systemctl --user enable --now github-runner@kisstour-sites

systemctl --user status github-runner@kisstour-sites
journalctl --user -u github-runner@kisstour-sites -f
```

The unit assumes clones live in `~/projects/WORKERS/<name>` and reads `.env`.
For a different layout or env file, override per instance rather than editing
the tracked template:

```bash
systemctl --user edit github-runner@kisstour-sites
# [Service]
# WorkingDirectory=/srv/runners/kisstour-sites
# Environment=RUNNER_ENV_FILE=.env.kisstour
# ExecStart=
# ExecStart=/srv/runners/kisstour-sites/run-runner-supervisor.sh ${RUNNER_ENV_FILE} runner-%i
```

`TimeoutStopSec=900` gives an in-flight job 15 minutes to finish on stop; raise
it in a drop-in if your jobs run longer.

### Managing Runners

1. View running containers:
```bash
docker compose ps
```

2. View logs:
```bash
# All runners
docker compose logs -f

# Specific runner
docker compose logs -f github-runner-xxx-1
```

3. Stop runners:
```bash
# Stop all
docker compose down

# Stop specific number of runners
docker compose scale github-runner=2
```

## GitHub Actions Workflow Example

```yaml
name: AWS Deployment
on:
  push:
    branches: [ main ]
permissions:
  id-token: write
  contents: read
jobs:
  verify-aws:
    runs-on: self-hosted
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region: ap-southeast-1
          role-session-name: GitHubActions
      
      - name: Verify AWS Access
        run: aws sts get-caller-identity

  build:
    needs: verify-aws
    runs-on: self-hosted
    steps:
      - uses: actions/checkout@v4
      
      - name: Use Node.js
        uses: actions/setup-node@v4
        with:
          node-version: ${{ vars.NODE_VERSION }}
          
      - name: Install dependencies
        run: yarn install
        
      - name: Build
        run: yarn run build:staging

  # Additional jobs as needed
```

## Features

- Scalable runner architecture
- Automatic runner registration and cleanup
- Support for Node.js applications
- AWS CLI integration
- Docker-in-Docker support
- Resource management and limitations
- Automatic runner naming

## Maintenance

### Updating Runner Version

1. Update `RUNNER_VERSION` in your `.env` file **and keep it in sync with the
   `ARG RUNNER_VERSION` default in the Dockerfile(s)** — the `.env` value
   overrides the build arg, so a stale `.env` silently ships an old runner that
   GitHub then forces to self-update on connect (a known crash-loop trigger).
   Track the current release at
   <https://github.com/actions/runner/releases/latest> (or automate the bump
   with Renovate/Dependabot).
2. Rebuild and restart the containers:
```bash
docker compose down
docker compose build --no-cache
docker compose up -d
```

### Pulling template updates

```bash
git status --porcelain docker-compose.yml   # expect empty; if not, see
                                            # "Migrating a clone that already
                                            # has local compose edits"
git pull origin main
docker compose build --no-cache
docker compose up -d --force-recreate
```

A clone with no local compose edits pulls cleanly. If that first command prints
anything, resolve the drift **before** pulling - a template change to
`docker-compose.yml` will otherwise conflict with, or silently outrank, the local
edit.

### Cleanup

Remove all containers and volumes:
```bash
docker compose down -v
```

## Troubleshooting

1. **Runner Registration Failed**
    - Check if your PAT or runner token is valid
    - Ensure the repository/organization permissions are correct

2. **Node.js Version Issues**
    - Verify `NODE_VERSION` in your `.env` file
    - Check logs for installation errors

3. **AWS Authentication Issues**
    - Verify AWS role ARN and permissions
    - Check AWS credentials configuration

4. **Container restarts forever (crash loop)**
    - `Cannot configure the runner because it is already configured` - a stale
      `.runner` from a prior run in the persisted layer. The hardened `start.sh`
      clears `.runner`/`.credentials*` before configuring; if you see this on an
      old image, rebuild so the fix is baked in.
    - `./bin/Runner.Listener: No such file or directory` / `exit code 127` - an
      interrupted runner self-update left `bin/` missing. `start.sh` self-heals
      from the newest `bin.*` backup; the durable fix is to keep
      `RUNNER_VERSION` current (see Maintenance) so no auto-update is triggered.
    - For a model where neither can accumulate, use the supervisor (see
      "Which orchestration model").

5. **Runner says "Listening for Jobs" but never gets any**
    - GitHub's side still holds the previous registration. Check with
      `gh api repos/$GITHUB_OWNER/$GITHUB_REPOSITORY/actions/runners` - the
      symptom is your runner listed as `"status": "offline"` with `"busy": true`.
    - Almost always caused by a `container_name:` pinned in a local
      `docker-compose.yml` or override, which lets Docker restart the same
      container and re-register the same runner name. Remove it (see
      "Never set `container_name`"), then `docker compose down && up -d`.

6. **Another runner's rebuild replaced my image**
    - Symptom: a clone starts running a build it never asked for, or an old one,
      after a sibling clone rebuilt. Both were on `github-runner:latest`.
    - Fixed by default now: the tag derives from the compose project name, so
      each clone owns its tag. Confirm with `docker compose config | grep image:`
      and make sure no local edit or `RUNNER_IMAGE_TAG=latest` puts it back.

## Notes

- Runners are configured as ephemeral and will be automatically removed from GitHub when stopped
- Each runner gets a unique name based on its container ID
- Docker socket is mounted to allow Docker operations inside the runner
- The configuration includes memory limits and resource management

## Security Considerations

- Keep your `.env` file secure and never commit it to version control
- Use secrets management for sensitive values in production
- Regularly update the runner version for security patches
- Review and limit the permissions granted to the GitHub PAT

## FAQ
- Does the container take too long to start? 
Yeah, I'm a chill guy.