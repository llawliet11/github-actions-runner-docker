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

```bash
# Using Docker buildx for AMD64 platform
docker buildx build --platform linux/amd64 -t github-runner:latest --load .
```

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

### Robust ephemeral orchestration (recommended)

`--ephemeral` + `restart: unless-stopped` + runner state living in the container
layer is the root of the historical crash-loop. The hardened `start.sh` now
self-heals that case, but the cleanest model is **one fresh container per job**:

```bash
# Foreground supervisor: a clean container (and clean writable layer) per job.
./run-runner-supervisor.sh .env.cisgenics
./run-runner-supervisor.sh .env.llab_dashboard
```

Run it under systemd / tmux / `nohup` (it stays in the foreground). Ctrl-C
stops it after the current job. For N parallel runners, start N supervisors with
distinct project names. With this model no state survives across jobs, so a
stale registration or an interrupted self-update can never accumulate.

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
      "Robust ephemeral orchestration").

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