#!/bin/bash
set -e

# AZP_URL control
if [ -z "${AZP_URL}" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

# AZP_TOKEN control
if [ -z "${AZP_TOKEN}" ]; then
  echo 1>&2 "error: missing AZP_TOKEN environment variable"
  exit 1
fi

# AZP_POOL control
if [ -z "${AZP_POOL}" ]; then
  echo 1>&2 "error: missing AZP_POOL environment variable"
  exit 1
fi


AZP_WORK="${AZP_WORK:-/azp/_work}"
mkdir -p "${AZP_WORK}"

cleanup() {
  trap "" EXIT

  if [ -e ./config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    # wait agent
    while true; do
      ./config.sh remove --unattended --auth "PAT" --token "${AZP_TOKEN}" && break

      echo "Retrying in 30 seconds..."
      sleep 30
    done
  fi
}

print_header() {
  lightcyan="\033[1;36m"
  nocolor="\033[0m"
  echo -e "\n${lightcyan}$1${nocolor}\n"
}

export VSO_AGENT_IGNORE="AZP_TOKEN,AZP_TOKEN_FILE,HELM_REPO_PASSWORD"

# Docker daemon runs in the dind sidecar; don't register the agent before it is reachable,
# otherwise the first jobs would fail with "Cannot connect to the Docker daemon".
if [ -n "${DOCKER_HOST}" ]; then
  print_header "0a. Waiting for Docker daemon (${DOCKER_HOST})..."
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  docker info >/dev/null 2>&1 \
    && echo "Docker daemon is ready" \
    || echo 1>&2 "warning: Docker daemon is not reachable, docker commands in jobs will fail"
fi

# Optional: register a (private) helm repo on every container start.
# HELM_REPO_NAME + HELM_REPO_URL are required; HELM_REPO_USERNAME / HELM_REPO_PASSWORD are optional.
if [ -n "${HELM_REPO_NAME}" ] && [ -n "${HELM_REPO_URL}" ]; then
  print_header "0b. Adding helm repo ${HELM_REPO_NAME}..."
  if [ -n "${HELM_REPO_USERNAME}" ]; then
    printf '%s' "${HELM_REPO_PASSWORD}" | helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" \
      --username "${HELM_REPO_USERNAME}" --password-stdin --force-update \
      && helm repo update "${HELM_REPO_NAME}" \
      || echo 1>&2 "warning: could not add/update helm repo ${HELM_REPO_NAME}"
  else
    helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" --force-update \
      && helm repo update "${HELM_REPO_NAME}" \
      || echo 1>&2 "warning: could not add/update helm repo ${HELM_REPO_NAME}"
  fi
fi

print_header "1. Determining matching Azure Pipelines agent..."

# AZP_AGENT_VERSION (RUNNER_VERSION build-arg) empty -> latest, otherwise the pinned version
if [ -n "${AZP_AGENT_VERSION}" ]; then
  AZP_AGENT_TOP=100
  AZP_AGENT_FILTER=".value | map(select(.version == \"${AZP_AGENT_VERSION}\")) | .[0].downloadUrl"
else
  AZP_AGENT_TOP=1
  AZP_AGENT_FILTER=".value[0].downloadUrl"
fi

AZP_AGENT_PACKAGES=$(curl -LsS \
    -u user:"${AZP_TOKEN}" \
    -H "Accept:application/json;" \
    "${AZP_URL}/_apis/distributedtask/packages/agent?platform=${TARGETARCH}&top=${AZP_AGENT_TOP}")

AZP_AGENT_PACKAGE_LATEST_URL=$(echo "${AZP_AGENT_PACKAGES}" | jq -r "${AZP_AGENT_FILTER}")

if [ -z "${AZP_AGENT_PACKAGE_LATEST_URL}" -o "${AZP_AGENT_PACKAGE_LATEST_URL}" == "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent${AZP_AGENT_VERSION:+ (version ${AZP_AGENT_VERSION})}"
  echo 1>&2 "check that account "${AZP_URL}" is correct and the token is valid for that account"
  exit 1
fi

print_header "2. Downloading and extracting Azure Pipelines agent..."

curl -LsS "${AZP_AGENT_PACKAGE_LATEST_URL}" | tar -xz & wait $!

source ./env.sh

trap "cleanup; exit 0" EXIT
trap "cleanup; exit 130" INT
trap "cleanup; exit 143" TERM

print_header "3. Configuring Azure Pipelines agent..."

./config.sh --unattended \
  --agent "$(hostname)" \
  --url "${AZP_URL}" \
  --auth "PAT" \
  --token "${AZP_TOKEN}" \
  --pool "${AZP_POOL}" \
  --work "${AZP_WORK}" \
  --replace \
  --acceptTeeEula & wait $!

print_header "4. Running Azure Pipelines agent..."

chmod +x ./run.sh

# azuredevops agent start
./run.sh "$@" & wait $!
