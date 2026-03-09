#!/bin/bash
set -e

if [[ -z "$ORG" || -z "$GITHUB_ACCESS_TOKEN" ]]; then
  echo "ERROR: ORG and GITHUB_ACCESS_TOKEN must be set"
  exit 1
fi

# Grant runner access to the Docker socket.
# Linux: sync the docker group GID with the host socket GID via groupmod.
# macOS Docker Desktop: socket has GID 0 (root), groupmod cannot reassign it —
#   fall back to making the socket world-accessible (chmod 666).
if [ -S /var/run/docker.sock ]; then
  SOCK_GID=$(stat -c '%g' /var/run/docker.sock)
  if groupmod -g "$SOCK_GID" docker 2>/dev/null; then
    echo "→ Docker socket GID synced: ${SOCK_GID}"
  else
    chmod 666 /var/run/docker.sock
    echo "→ Docker socket: world-accessible (fallback for GID ${SOCK_GID})"
  fi
fi

REG_TOKEN=$(curl -fsSL \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_ACCESS_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/orgs/${ORG}/actions/runners/registration-token" \
  | jq .token --raw-output
)

cd /home/runner/actions-runner

if [[ -f ".runner" || -f ".credentials" ]]; then
  echo "→ Runner already configured, skipping registration"
else
  echo "→ Runner not configured, registering…"
  CONFIG_ARGS=(
    --unattended
    --url "https://github.com/${ORG}"
    --token "${REG_TOKEN}"
    --labels "jvm-runner,jdk25,nvm,has-docker-builder"
    --replace
  )
  [[ -n "$RUNNER_NAME" ]] && CONFIG_ARGS+=(--name "$RUNNER_NAME")
  gosu runner ./config.sh "${CONFIG_ARGS[@]}"
fi

cleanup() {
  echo "→ Removing runner from GitHub…"
  gosu runner ./config.sh remove --unattended --token "${REG_TOKEN}"
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

exec gosu runner ./run.sh
