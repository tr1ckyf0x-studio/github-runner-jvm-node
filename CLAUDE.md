# github-runner-jvm-node

GitHub Actions self-hosted runner for JVM + Android builds.
Supports JDK 25, Android SDK, nvm/Node.js, Gradle, Maven.
Multi-platform: `linux/amd64` and `linux/arm64`.

## Architecture

### Dockerfile (multi-stage)

**Stage 1 (`runner-downloader`, `--platform=$BUILDPLATFORM`):**
Runs natively on the build machine. Downloads the GitHub Actions runner binary
for `$TARGETARCH` (amd64 → x64, arm64 → arm64) without QEMU overhead.

**Stage 2 (final image, `eclipse-temurin:25-jdk-noble`):**
Runs on the target platform. Installs system dependencies, copies the runner
binary from Stage 1, installs Android SDK, then installs nvm + Node.js as the
`runner` user. Entrypoint runs as root (Docker socket GID sync) and drops
privileges via `gosu`.

### Key Build ARGs

| ARG | Default | Purpose |
|-----|---------|---------|
| `RUNNER_VERSION` | `2.333.1` | GitHub Actions runner release |
| `NVM_VERSION` | `0.40.4` | nvm release |
| `NODE_VERSION` | `24` | Default Node.js major version |
| `ANDROID_COMMANDLINETOOLS_VERSION` | `14742923` | Android cmdline-tools ZIP version |
| `ANDROID_PLATFORM_VERSION` | `36` | `platforms;android-XX` |
| `ANDROID_BUILD_TOOLS_VERSION` | `36.0.0` | `build-tools;X.Y.Z` |

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

Update `ANDROID_COMMANDLINETOOLS_VERSION` in Dockerfile and the workflow default.

## CI/CD

`.github/workflows/build-and-push.yml` builds and pushes to GHCR on every push
to `main` (Dockerfile or entrypoint.sh changes) and on manual dispatch.

Registry: `ghcr.io/tr1ckyf0x-studio/github-runner-jvm-node`
Local mirror: `docker.tr1ckyf0x.dev/tr1ckyf0x-studio/github-runner-jvm-node`

Manual dispatch inputs let you override runner, nvm, Node.js, and Android SDK versions.

## Deployment

```bash
# AMD Ryzen x64 server
RUNNER_PLATFORM=linux/amd64 docker compose up -d

# Apple M1 (arm64)
RUNNER_PLATFORM=linux/arm64 docker compose up -d
```

The runner is persistent (`restart: unless-stopped`) and non-ephemeral.
