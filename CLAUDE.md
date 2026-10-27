# github-runner-jvm-node

GitHub Actions self-hosted runner for JVM + Android builds.
Supports JDK 25, Android SDK, nvm/Node.js, Gradle (system `gradle` plus the cache), Maven (cache only).
Platforms: CI publishes `linux/amd64` only (since 2026-10-27); the Dockerfile still builds
`linux/arm64` locally. Why, and the way back: README, "Known warnings".

## Architecture

### Dockerfile (multi-stage)

**Stage 1 (`runner-downloader`, `ubuntu:resolute`, `--platform=$BUILDPLATFORM`):**
Runs natively on the build machine. Downloads the GitHub Actions runner binary
for `$TARGETARCH` (amd64 → x64, arm64 → arm64) without QEMU overhead.

**Stage 2 (final image, `eclipse-temurin:25-jdk-resolute`, Ubuntu 26.04):**
Runs on the target platform. Installs system dependencies, copies the runner
binary from Stage 1, installs Android SDK and Gradle, then installs nvm + Node.js as the
`runner` user. Entrypoint runs as root (Docker socket GID sync) and drops
privileges via `gosu`.

### Key Build ARGs

| ARG | Default | Purpose |
|-----|---------|---------|
| `RUNNER_VERSION` | `2.338.2` | GitHub Actions runner release |
| `NVM_VERSION` | `0.40.8` | nvm release |
| `NODE_VERSION` | `24` | Default Node.js major version |
| `GRADLE_VERSION` | `9.8.2` | System Gradle in `/opt/gradle` (`GRADLE_HOME`, on `PATH`) |
| `ANDROID_COMMANDLINETOOLS_VERSION` | `15859902` | Android cmdline-tools ZIP version (22.0, held) |
| `ANDROID_PLATFORM_VERSION` | `37.0` | `platforms;android-XX` (from API 36.1 on, with a minor: `37.0`, `37.1`) |
| `ANDROID_BUILD_TOOLS_VERSION` | `37.0.0` | `build-tools;X.Y.Z` |

### ENV Variables (Runtime)

Set via `.env` file (not committed):

| Variable | Required | Description |
|----------|----------|-------------|
| `ORG` | yes | GitHub org name (`tr1ckyf0x-studio`) |
| `GITHUB_ACCESS_TOKEN` | yes | PAT with `manage_runners:org` scope |
| `RUNNER_NAME` | no | Custom runner name (auto-generated if unset) |
| `RUNNER_PLATFORM` | no | Docker platform (`linux/amd64` or `linux/arm64`) |

### Runner Labels

The runner registers with: `jvm-runner,jdk25,nvm,android-runner,has-docker-builder`

Use these labels in workflow `runs-on`:
```yaml
runs-on: [self-hosted, jvm-runner]      # any JVM job
runs-on: [self-hosted, android-runner]  # Android APK build
```

### Android SDK

Installed at `/opt/android-sdk`. Included components:
- `cmdline-tools/latest` — sdkmanager, avdmanager
- `platform-tools` — adb
- `platforms;android-${ANDROID_PLATFORM_VERSION}`
- `build-tools;${ANDROID_BUILD_TOOLS_VERSION}`

`ANDROID_HOME` and `PATH` are set in the image. Gradle workflows pick these up
automatically via the `local.properties` convention or the env.

## Local Development

### Build the image

```bash
# Single platform (fast, no QEMU)
docker build --platform linux/amd64 -t github-runner-jvm-node:local .

# With custom Android SDK versions
docker build \
  --build-arg ANDROID_PLATFORM_VERSION=35 \
  --build-arg ANDROID_BUILD_TOOLS_VERSION=35.0.1 \
  --platform linux/amd64 \
  -t github-runner-jvm-node:local .
```

### Run locally

```bash
cp .env.example .env  # fill in ORG and GITHUB_ACCESS_TOKEN
docker compose up
```

### Update Android SDK versions

Find the latest `commandlinetools` version number at:
https://developer.android.com/studio#command-line-tools-only

Update `ANDROID_COMMANDLINETOOLS_VERSION` in Dockerfile and the workflow default. It is held at 22.0
(`15859902`): from 23.0 `sdkmanager` only calls the x86-64-only `bin/android`, so the arm64 build
fails. CI builds amd64 only for now, so 23.0 would pass there; it is still held, so that arm64 comes
back together with the move to the Android CLI (README, "Known warnings"). A local amd64 build never
catches an arm64 break.
Every package path and version is also in Google's index,
https://dl.google.com/android/repository/repository2-3.xml (`channel-0` is stable).

### Update Gradle

The newest version is at https://services.gradle.org/versions/current. Bump `GRADLE_VERSION` in
the Dockerfile; the build checks the archive against the `.sha256` published next to it.

### Base image

The runner user must stay uid 1001: the deployed compose chowns its volumes to `1001:1001`. That
holds because the Ubuntu base already has `ubuntu` at 1000, so check `id runner` after changing it.

## CI/CD

`.github/workflows/build-and-push.yml` builds and pushes to GHCR on every push
to `main` (Dockerfile or entrypoint.sh changes) and on manual dispatch.

Registry: `ghcr.io/tr1ckyf0x-studio/github-runner-jvm-node`
Local mirror: `docker.tr1ckyf0x.dev/tr1ckyf0x-studio/github-runner-jvm-node`

Manual dispatch inputs let you override runner, nvm, Node.js, Gradle, and Android SDK versions.

## Deployment

```bash
# AMD Ryzen x64 server
RUNNER_PLATFORM=linux/amd64 docker compose up -d

# Apple M1 (arm64): GHCR has no arm64 image for now; build it locally first
docker build --platform linux/arm64 -t docker.tr1ckyf0x.dev/tr1ckyf0x-studio/github-runner-jvm-node:latest .
RUNNER_PLATFORM=linux/arm64 docker compose up -d
```

The runner is persistent (`restart: unless-stopped`) and non-ephemeral.

The organisation's own runner on the server Earth (`jvm-runner-earth`) is not started by hand: it is
the Komodo stack `github-runner-jvm-node`. After a push to `main` the `deploy` job posts a signed
webhook (secrets `DEPLOY_WEBHOOK_URL`, `DEPLOY_WEBHOOK_SECRET`); Komodo pulls the new image from
GHCR and recreates the runner once no job is running. GitHub has no SSH access to the server.
