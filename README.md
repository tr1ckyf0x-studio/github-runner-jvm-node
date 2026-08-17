# GitHub Actions Runner — JVM

Self-hosted GitHub Actions runner for JVM and Android projects, built on JDK 25, with its own
isolated Docker daemon.

## Features

- **JDK 25** via Eclipse Temurin
- **nvm** for switching Node.js versions per project
- **Android SDK** — command-line tools, platform-tools, platform and build-tools
- **Docker** — client and buildx, talking to a `dind` sidecar rather than the host's daemon, so
  containers started by a workflow never appear on the machine
- **Gradle, Maven and npm** caches persisted in Docker volumes
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

Use `docker-compose.yml` from this repository as it is — it is deliberately not reproduced here,
because a copy in a README drifts from the file it copies and this one already had.

It brings up three things: the `dind` sidecar, a one-shot container that fixes volume ownership, and
the runner itself. The runner registers under your organization with the labels `jvm-runner`,
`jdk25`, `nvm`, `android-runner` and `has-docker-builder`, then starts polling for jobs.

## Docker inside workflows

Every `docker` command in a workflow reaches the **sidecar**, through `DOCKER_HOST=tcp://dind:2375`.
Nothing here touches the machine's own daemon, and no socket is mounted for it to touch.

What that buys, and what it does not:

- Images, containers and bound ports created by a job live and die inside the sidecar. The host stays
  clean, and two jobs cannot collide on a host port.
- **Testcontainers works with no configuration.** Given a TCP `DOCKER_HOST` it addresses mapped ports
  through that same name; with a mounted unix socket it assumes `localhost`, which inside a container
  is the container itself — the classic symptom being tests that hang and then time out connecting to
  a database that is demonstrably running.
- `docker run -v "$PWD:/x"` resolves correctly, because the runner's `_work` directory is a volume
  mounted at the **same path** in both containers. Under a mounted socket that bind silently produced
  an empty directory, since the path existed only inside the runner.
- It is **not** a security boundary. A nested daemon needs `privileged`, and a privileged container
  can reach the host if it tries. This isolates state, not intent — run the runner on a host that
  carries nothing else valuable.

`docker buildx` is present and multi-platform builds work; `docker/setup-buildx-action` still has a
job to do in a workflow, because it creates the builder on the `docker-container` driver that a
manifest list requires.

## Using in Workflows

```yaml
jobs:
  build:
    runs-on: [self-hosted, jvm-runner]

  # Or target by capability
  images:
    runs-on: [self-hosted, has-docker-builder]

  android:
    runs-on: [self-hosted, android-runner]
```

There is no need for `actions/setup-java`: JDK 25 is already the one on `PATH`, and the action would
download a second one beside it.

### Switching Node.js versions

nvm is pre-installed and available in every step without any extra setup:

```yaml
steps:
  - run: nvm use 24

  # or via actions/setup-node (also works)
  - uses: actions/setup-node@v7
    with:
      node-version: '24'
```

## Configuration

All versions are build-time arguments with defaults:

| ARG | Default | Description |
|---|---|---|
| `RUNNER_VERSION` | `2.336.0` | GitHub Actions Runner version |
| `NVM_VERSION` | `0.40.6` | nvm version |
| `NODE_VERSION` | `24` | Default Node.js major version |
| `ANDROID_COMMANDLINETOOLS_VERSION` | `15859902` | Android command-line tools build |
| `ANDROID_PLATFORM_VERSION` | `36` | Android platform API level |
| `ANDROID_BUILD_TOOLS_VERSION` | `36.0.0` | Android build-tools version |

Override at build time:

```bash
docker build \
  --build-arg NODE_VERSION=24 \
  --build-arg RUNNER_VERSION=2.336.0 \
  -t github-runner-jvm-node .
```

Or trigger a manual build via **Actions → Build and Push to GHCR → Run workflow** with custom version
inputs.

## Image

CI publishes to GHCR on every push to `main`:

```
ghcr.io/tr1ckyf0x-studio/github-runner-jvm-node:latest
```

| Tag | Description |
|---|---|
| `latest` | Latest build from `main` |
| `sha-<commit>` | Pinned to a specific commit |

### Pulling through Nexus

`docker-compose.yml` does not name GHCR directly. It pulls from `docker.tr1ckyf0x.dev`, a Nexus
group that fetches upstream and caches — so a restart, or a second host, does not re-download the
image across the internet, and the pull keeps working while GitHub does not.

The reference follows from one rule: **a Docker proxy mirrors the upstream path after the registry
host.** Drop `ghcr.io`, put the proxy in its place, change nothing else.

```
ghcr.io/tr1ckyf0x-studio/github-runner-jvm-node:latest
        └──────────────── unchanged ────────────────┘
docker.tr1ckyf0x.dev/tr1ckyf0x-studio/github-runner-jvm-node:latest
```

Every image in `docker-compose.yml` goes through that host, not only this one — which is why `dind`
and `alpine` are written with a `library/` prefix. Official Docker Hub images live in that implicit
namespace, and the Docker CLI fills it in *only* when the registry is Docker Hub itself; against any
other host it must be spelled out. Checked against the Hub API, where `/v2/docker/manifests/latest`
answers 401 and `/v2/library/docker/manifests/latest` answers 200. This works because the host serves
a Nexus **group**: one proxy repository has exactly one remote, so GHCR and Docker Hub reach the same
hostname only as two members of a group.

Two settings on the group's **GHCR member** decide whether this works, and both fail in ways that
look like something else:

- **Remote storage** is `https://ghcr.io`.
- **Docker Index** must be *Use proxy registry*, not *Use Docker Hub*. GHCR issues its own pull
  tokens; pointed at Docker Hub for them, Nexus asks the wrong service and the pull fails as
  unauthorized rather than as misconfigured.

This image needs no upstream credentials — the package is public, and an anonymous token pulls its
manifest. A **private** package does: the proxy needs HTTP authentication with a GitHub PAT carrying
`read:packages`. That is not academic here — `fox-signer` is a private repository, so its image is
private too, and a proxy that works for this one will 401 on that one until the credentials are set.

## Architecture

```
host
├── dind                              ← the runner's own Docker daemon, privileged
│    ├── /var/lib/docker  ← volume    (images and build cache survive restarts)
│    └── containers started by jobs   (never on the host)
└── jvm-runner                        ← DOCKER_HOST=tcp://dind:2375
     ├── eclipse-temurin:25-jdk-noble (base)
     ├── GitHub Actions Runner (actions-runner/)
     ├── docker client + buildx       (docker.io + docker-buildx, daemon unused)
     ├── Android SDK (/opt/android-sdk)
     ├── nvm (~/.nvm) + Node.js 24
     ├── ~/.gradle, ~/.m2, ~/.npm     ← volumes
     └── actions-runner/_work         ← volume, shared with dind at the same path
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `ORG` | Yes | GitHub organization name |
| `GITHUB_ACCESS_TOKEN` | Yes | PAT with `manage_runners:org` scope |
| `RUNNER_NAME` | No | Name shown in the Actions UI; generated when unset |
| `RUNNER_PLATFORM` | No | Image platform to pull, `linux/amd64` by default |
| `DOCKER_HOST` | — | Set by compose to `tcp://dind:2375`; do not override in a workflow |

## Volumes

| Volume | Mount | Purpose |
|---|---|---|
| `github-jvm-runner-gradle` | `/home/runner/.gradle` | Gradle dependency cache |
| `github-jvm-runner-m2` | `/home/runner/.m2` | Maven dependency cache |
| `github-jvm-runner-npm` | `/home/runner/.npm` | npm package cache |
| `github-jvm-runner-tool-cache` | `/opt/hostedtoolcache` | `setup-*` action downloads |
| `github-jvm-runner-work` | `/home/runner/actions-runner/_work` | Job workspace, shared with `dind` |
| `github-jvm-runner-docker` | `/var/lib/docker` (in `dind`) | Images and build cache |

## Known warnings

**`The SDK Manager CLI tool (sdkmanager) is deprecated. Use Android CLI instead.`** — printed on every
build, and deliberately not acted on. The replacement `android` binary shipped in
`commandlinetools-linux` is an **x86-64 ELF executable**, and the archive contains no arm64 build of
it, so switching would break the `linux/arm64` image. `sdkmanager` and `avdmanager` are shell scripts
that run under the JDK and work on both. Worth revisiting when a check like this stops saying
`x86-64`:

```bash
docker run --rm --platform linux/arm64 eclipse-temurin:25-jdk-noble bash -c \
  'apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq wget unzip file >/dev/null 2>&1 \
   && wget -q https://dl.google.com/android/repository/commandlinetools-linux_latest.zip -O /tmp/ct.zip \
   && unzip -q /tmp/ct.zip -d /opt && file -b /opt/cmdline-tools/bin/android'
```

## License

MIT
