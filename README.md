# GitHub Actions Runner — JVM

Self-hosted GitHub Actions runner for JVM applications, built on JDK 25 with nvm/Node.js support.

## Features

- **JDK 25** via Eclipse Temurin
- **nvm** for switching Node.js versions per project
- **Gradle & Maven** local caches persisted via Docker volumes
- **Multi-platform**: `linux/amd64` (x64) and `linux/arm64` (ARM)
- **Auto-published** to GHCR on every push to `main`

## Quick Start

### 1. Create `.env`

```env
ORG=your-github-org
GITHUB_ACCESS_TOKEN=ghp_xxxxxxxxxxxx
RUNNER_PLATFORM=linux/amd64
```

The token requires the `manage_runners:org` permission scope.

> **Apple Silicon (M1/M2/M3):** set `RUNNER_PLATFORM=linux/arm64` to pull the native ARM image.

### 2. Run

```bash
docker compose up -d
```

Or use this as your `docker-compose.yml`:

```yaml
services:
  jvm-runner:
    container_name: github-jvm-runner
    image: ghcr.io/tr1ckyf0x-studio/github-runner-jvm-node:latest
    platform: ${RUNNER_PLATFORM:-linux/amd64}
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - github-jvm-runner-gradle:/home/runner/.gradle
      - github-jvm-runner-m2:/home/runner/.m2
      - github-jvm-runner-npm:/home/runner/.npm

volumes:
  github-jvm-runner-gradle:
  github-jvm-runner-m2:
  github-jvm-runner-npm:
```

The runner registers itself under your organization with the labels `jvm-runner`, `jdk25`, and `nvm`, then starts polling for jobs.

## Using in Workflows

Target this runner with:

```yaml
jobs:
  build:
    runs-on: [self-hosted, jvm-runner]

  # Target specifically by Node.js availability
  frontend:
    runs-on: [self-hosted, nvm]
```

### Switching Node.js versions

nvm is pre-installed and available in every step without any extra setup:

```yaml
steps:
  - run: nvm use 24

  # or via actions/setup-node (also works)
  - uses: actions/setup-node@v4
    with:
      node-version: '24'
```

## Configuration

All versions are build-time arguments with defaults:

| ARG | Default | Description |
|---|---|---|
| `RUNNER_VERSION` | `2.333.1` | GitHub Actions Runner version |
| `NVM_VERSION` | `0.40.4` | nvm version |
| `NODE_VERSION` | `24` | Default Node.js major version |

Override at build time:

```bash
docker build \
  --build-arg NODE_VERSION=24 \
  --build-arg RUNNER_VERSION=2.333.1 \
  -t github-runner-jvm-node .
```

Or trigger a manual build via **Actions → Build and Push to GHCR → Run workflow** with custom version inputs.

## Image

```
ghcr.io/tr1ckyf0x-studio/github-runner-jvm-node:latest
```

| Tag | Description |
|---|---|
| `latest` | Latest build from `main` |
| `sha-<commit>` | Pinned to a specific commit |

## Architecture

```
Container
├── eclipse-temurin:25-jdk-noble (base)
├── GitHub Actions Runner (actions-runner/)
├── nvm (~/.nvm) + Node.js 24 (default)
├── ~/.gradle  ← mounted volume (Gradle cache)
└── ~/.m2      ← mounted volume (Maven cache)
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ORG` | Yes | GitHub organization name |
| `GITHUB_ACCESS_TOKEN` | Yes | PAT with `manage_runners:org` scope |

## Volumes

| Volume | Mount | Purpose |
|---|---|---|
| `github-jvm-runner-gradle` | `/home/runner/.gradle` | Gradle dependency cache |
| `github-jvm-runner-m2` | `/home/runner/.m2` | Maven dependency cache |
| `github-jvm-runner-npm` | `/home/runner/.npm` | npm package cache |

## License

MIT
