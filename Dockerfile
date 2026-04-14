### Stage 1: download the runner binary natively on the build machine (no QEMU)
# --platform=$BUILDPLATFORM → stage runs on the builder's native arch (amd64).
# TARGETARCH is correctly injected by buildx: amd64 or arm64.
FROM --platform=$BUILDPLATFORM ubuntu:noble AS runner-downloader

ARG RUNNER_VERSION="2.333.1"
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
        "amd64") RUNNER_ARCH="x64" ;; \
        "arm64") RUNNER_ARCH="arm64" ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    mkdir /actions-runner && cd /actions-runner && \
    curl -fsSL -o runner.tar.gz \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" && \
    tar xzf runner.tar.gz && rm runner.tar.gz

### Stage 2: final image for the target platform (arm64 or amd64)
FROM eclipse-temurin:25-jdk-noble

ARG RUNNER_VERSION="2.333.1"
ARG NVM_VERSION="0.40.4"
ARG NODE_VERSION="24"
ARG ANDROID_COMMANDLINETOOLS_VERSION="14742923"
ARG ANDROID_PLATFORM_VERSION="36"
ARG ANDROID_BUILD_TOOLS_VERSION="36.0.0"

LABEL org.opencontainers.image.source="https://github.com/tr1ckyf0x-studio/github-runner-jvm-node"
LABEL org.opencontainers.image.description="GitHub Actions self-hosted runner for JVM and Android applications (JDK 25)"
LABEL org.opencontainers.image.licenses="MIT"

ENV ANDROID_HOME=/opt/android-sdk
ENV PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

RUN useradd -m runner

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    git-lfs \
    wget \
    unzip \
    jq \
    build-essential \
    libicu-dev \
    libcurl4 \
    openssh-client \
    zip \
    docker.io \
    gosu \
    && rm -rf /var/lib/apt/lists/* \
    && usermod -aG docker runner

WORKDIR /home/runner

# Copy the runner binary from stage 1 (already the correct arch)
COPY --from=runner-downloader /actions-runner ./actions-runner

# Install runner system dependencies on the target platform
RUN ./actions-runner/bin/installdependencies.sh && \
    mkdir -p .gradle .m2 .npm && \
    chown -R runner:runner /home/runner

WORKDIR /

# Install Android SDK (commandlinetools, platform-tools, platforms, build-tools)
RUN mkdir -p $ANDROID_HOME/cmdline-tools && \
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMANDLINETOOLS_VERSION}_latest.zip" \
         -O /tmp/cmdline-tools.zip && \
    unzip -q /tmp/cmdline-tools.zip -d $ANDROID_HOME/cmdline-tools && \
    rm /tmp/cmdline-tools.zip && \
    mv $ANDROID_HOME/cmdline-tools/cmdline-tools $ANDROID_HOME/cmdline-tools/latest && \
    yes | sdkmanager --licenses > /dev/null && \
    sdkmanager \
        "platform-tools" \
        "platforms;android-${ANDROID_PLATFORM_VERSION}" \
        "build-tools;${ANDROID_BUILD_TOOLS_VERSION}" && \
    chown -R runner:runner $ANDROID_HOME

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD pgrep -f "Runner.Listener" > /dev/null || exit 1

# Install nvm and Node.js as runner user
USER runner

ENV NVM_DIR=/home/runner/.nvm

RUN curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | PROFILE=/dev/null bash && \
    . "$NVM_DIR/nvm.sh" && \
    nvm install ${NODE_VERSION} && \
    nvm alias default ${NODE_VERSION} && \
    nvm cache clear

# BASH_ENV is sourced by bash on every invocation (including GitHub Actions steps).
# This makes `nvm` and `node` available without explicit source in workflow files.
RUN printf '. "%s/nvm.sh"\n' "$NVM_DIR" > /home/runner/.nvm_env
ENV BASH_ENV=/home/runner/.nvm_env

# Entrypoint runs as root — to sync the Docker socket GID.
# Control is then handed off to the runner user via gosu.
USER root
ENTRYPOINT ["/entrypoint.sh"]
