# Self-hosted GitHub Actions Runner

This repository contains Docker configurations for running self-hosted GitHub Actions runners. It supports multiple runners with automatic scaling capabilities and is configured to work with AWS deployments.

## Prerequisites

- Docker and Docker Compose installed
- GitHub Personal Access Token (PAT) with `repo` scope for private repositories or `admin:org` scope for organization runners
- AWS credentials configured (if using AWS deployments)

## Files Structure

```
.
├── Dockerfile
├── docker-compose.yml
├── install-node.sh
├── start.sh
├── .env
└── README.md
```

## Configuration

### Environment Variables

Create a `.env` file with the following variables:

```env
# GitHub Runner Configuration
RUNNER_REPO=https://github.com/your-org/your-repo
RUNNER_TOKEN=your_runner_token  # Optional if using GITHUB_PAT
RUNNER_VERSION=2.321.0
RUNNER_LABELS=self-hosted

# Node.js Configuration
NODE_VERSION=20

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

1. Start with default number of runners (3):
```bash
docker compose up -d
```

2. Scale to a specific number of runners:
```bash
docker compose up -d --scale github-runner=5
```

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
docker compose logs -f github-runner-1
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

1. Update `RUNNER_VERSION` in your `.env` file
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