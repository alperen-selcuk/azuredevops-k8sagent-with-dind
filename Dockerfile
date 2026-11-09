# Toolchain versions (override with --build-arg)
ARG NODE_VERSION=24
ARG MAVEN_VERSION=3.9
ARG DOTNET_SDK_VERSION=8.0
# Docker CLI image tag: "cli" = latest, or pin e.g. "27-cli" / "27.3.1-cli"
ARG DOCKER_TAG=cli

FROM docker:${DOCKER_TAG} AS docker
FROM node:${NODE_VERSION}-bookworm-slim AS node
FROM maven:${MAVEN_VERSION}-eclipse-temurin-21 AS maven

# Ubuntu 24.04 (noble) based image with the .NET SDK preinstalled
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_VERSION}-noble

ENV DEBIAN_FRONTEND=noninteractive

# UTF-8 locale for every process in the agent (build steps, tasks, JVM).
# Without this the locale falls back to POSIX/ASCII and Java's sun.jnu.encoding
# becomes ANSI_X3.4-1968, so file names with non-ASCII characters (e.g. Turkish
# "Çalışma-Masası.png") fail with java.nio.file.InvalidPathException in the
# SonarScanner, Maven, etc. C.UTF-8 ships with glibc on noble, no extra package needed.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LANGUAGE=C.UTF-8

# Architecture used for kubectl / helm downloads: amd64 | arm64
ARG K8S_ARCH=amd64
# Leave empty to use the latest release; set to pin a version (e.g. v1.x.y / v3.x.y)
ARG KUBECTL_VERSION=""
ARG HELM_VERSION=""
# Leave empty to use the latest Azure Pipelines agent; set to pin (e.g. 4.x.y)
ARG RUNNER_VERSION=""
ENV AZP_AGENT_VERSION=${RUNNER_VERSION}

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y -qq --no-install-recommends \
      ca-certificates \
      curl \
      git \
      iputils-ping \
      jq \
      lsb-release \
      libicu74 \
      build-essential \
      python3 \
      openjdk-17-jdk-headless \
      unzip \
      wget && \
    rm -rf /var/lib/apt/lists/*

# JDK 21 (copied from the Maven image). Java is required by the SonarQube scanner tasks
# (also detected by the agent as the "java" capability).
COPY --from=maven /opt/java/openjdk /usr/lib/jvm/default-java
ENV JAVA_HOME=/usr/lib/jvm/default-java
# The Maven task resolves the JDK selected by jdkVersionOption from these variables.
# JDK 17 stays available for pipelines that select it; JDK 21 is the default.
ENV JAVA_HOME_21_X64=/usr/lib/jvm/default-java
ENV JAVA_HOME_17_X64=/usr/lib/jvm/java-1.17.0-openjdk-amd64
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Git: show non-ASCII paths as-is in logs/output instead of octal escapes ("\303\207...")
RUN git config --system core.quotepath false

# Docker CLI + buildx/compose plugins. The daemon runs in the dind sidecar (see kubernetes/deployment.yaml).
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins

# Node.js + npm (copied from the official image, glibc compatible with noble)
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    ln -s ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

# Maven (uses the JDK installed above)
COPY --from=maven /usr/share/maven /usr/share/maven
RUN ln -s /usr/share/maven/bin/mvn /usr/local/bin/mvn
ENV MAVEN_HOME=/usr/share/maven

RUN set -eux; dotnet --version; node -v; npm -v; java -version; "${JAVA_HOME_17_X64}/bin/java" -version; "${JAVA_HOME_21_X64}/bin/java" -version; mvn -v; docker --version; docker buildx version

# Fail the build if the JVM does not pick up UTF-8 for file names
RUN set -eux; \
    locale; \
    java -XshowSettings:properties -version 2>&1 | grep -E 'sun.jnu.encoding = UTF-8'

# Install powershell
RUN wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y -qq --no-install-recommends powershell && \
    rm -rf /var/lib/apt/lists/*

# Install az cli
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash && \
    rm -rf /var/lib/apt/lists/*

# Install kubectl (inside a pod it authenticates with the mounted ServiceAccount token)
RUN set -eux; \
    v="${KUBECTL_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"; \
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${v}/bin/linux/${K8S_ARCH}/kubectl"; \
    curl -fsSL "https://dl.k8s.io/release/${v}/bin/linux/${K8S_ARCH}/kubectl.sha256" -o /tmp/kubectl.sha256; \
    echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c -; \
    chmod +x /usr/local/bin/kubectl; \
    rm /tmp/kubectl.sha256

# Install helm
RUN set -eux; \
    h="${HELM_VERSION:-$(curl -fsSL https://get.helm.sh/helm-latest-version)}"; \
    curl -fsSL "https://get.helm.sh/helm-${h}-linux-${K8S_ARCH}.tar.gz" | tar -xz -C /tmp; \
    mv "/tmp/linux-${K8S_ARCH}/helm" /usr/local/bin/helm; \
    rm -rf "/tmp/linux-${K8S_ARCH}"; \
    kubectl version --client; helm version

# Can be 'linux-x64', 'linux-arm64', 'linux-arm', 'rhel.6-x64'.
ENV TARGETARCH=linux-x64

WORKDIR /azp
COPY ./start.sh .
RUN chmod +x start.sh

ENV HOME=/root
ENV USER=root
ENV AZP_WORK=/azp/_work
# global dotnet tools
ENV PATH="${PATH}:/root/.dotnet/tools"

# Code coverage and SonarQube analysis tools used by the .NET pipelines
RUN set -eux; \
    dotnet tool install --global dotnet-coverage; \
    dotnet tool install --global dotnet-sonarscanner; \
    dotnet-coverage --version; \
    dotnet tool list --global | grep -i dotnet-sonarscanner

# Pipelines that run UseDotNet@2 (e.g. 6.0) point DOTNET_ROOT at the agent tool cache,
# which has no .NET 8 runtime, so the ~/.dotnet/tools apphost shim fails with
# "You must install or update .NET". This wrapper (ahead of ~/.dotnet/tools in PATH)
# runs the tool DLL with the image's own .NET 8 muxer and leaves DOTNET_ROOT untouched
# for the child processes (dotnet test) it starts.
RUN set -eux; \
    dll="$(find /root/.dotnet/tools/.store/dotnet-coverage -name dotnet-coverage.dll | sort | tail -n1)"; \
    test -n "$dll"; \
    printf '#!/bin/sh\nexec /usr/share/dotnet/dotnet "%s" "$@"\n' "$dll" > /usr/local/bin/dotnet-coverage; \
    chmod +x /usr/local/bin/dotnet-coverage; \
    DOTNET_ROOT=/nonexistent dotnet-coverage --version

# SonarScanner CLI for non-.NET projects (runs on the default JDK)
ARG SONAR_SCANNER_VERSION=8.3.1.16491
RUN set -eux; \
    curl -fsSLo /tmp/sonar-scanner.zip "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip"; \
    unzip -q /tmp/sonar-scanner.zip -d /tmp; \
    mv "/tmp/sonar-scanner-${SONAR_SCANNER_VERSION}" /opt/sonar-scanner; \
    ln -s /opt/sonar-scanner/bin/sonar-scanner /usr/local/bin/sonar-scanner; \
    rm /tmp/sonar-scanner.zip; \
    sonar-scanner --version

ENTRYPOINT [ "./start.sh" ]
