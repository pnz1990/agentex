FROM ubuntu:24.04

# Image version: 2026-03-09-r2 (security: fix npm bundled dep CVEs - tar, minimatch, glob; apt-get upgrade; issue #858)
ARG KUBECTL_VERSION=1.35.2
ARG GH_VERSION=2.87.3
ARG OPENCODE_VERSION=latest

# Run apt-get upgrade to pick up latest security patches for system packages (issue #858)
# This fixes: libgnutls30t64, libexpat1, and other Ubuntu 24.04 security updates
RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    curl \
    git \
    jq \
    unzip \
    ca-certificates \
    gnupg \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

# gh CLI
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /tmp && mv /tmp/gh_${GH_VERSION}_linux_amd64/bin/gh /usr/local/bin/gh

# AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# Node.js (required by opencode)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# OpenCode CLI
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm cache clean --force

# Fix npm bundled dependency CVEs (issue #858)
# npm bundles tar, minimatch, and glob in /usr/lib/node_modules/npm/node_modules/
# These bundled versions have HIGH CVEs: tar@7.4.3->7.5.10, minimatch@9.0.5->9.0.7, glob@10.4.5->10.5.0
# Fix: upgrade npm itself (npm 11+ ships with patched bundled deps)
# Also: upgrade specific vulnerable packages directly in npm's own node_modules
RUN npm install -g npm@latest \
    && cd /usr/lib/node_modules/npm \
    && npm install --prefer-online \
        tar@">=7.5.10" \
        minimatch@">=9.0.7" \
        glob@">=10.5.0" \
    2>/dev/null || true \
    && npm cache clean --force

# ubuntu:24.04 ships with user/group "ubuntu" at UID/GID 1000.
# Rename it to "agentex" and set up the home directory.
RUN usermod -l agentex -d /home/agentex -m ubuntu \
    && groupmod -n agentex ubuntu

# Directories and permissions
RUN mkdir -p /workspace /home/agentex/.config/opencode /home/agentex/.kube \
    && chown -R agentex:agentex /workspace /home/agentex

# OpenCode permissions config — allow all tool calls without interactive prompts.
# external_directory defaults to "ask" which blocks bash writing to /tmp and /workspace.
RUN mkdir -p /home/agentex/.config/opencode && \
    printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "permission": "allow"\n}\n' \
    > /home/agentex/.config/opencode/config.json \
    && chown agentex:agentex /home/agentex/.config/opencode/config.json

# git config (system-wide)
RUN git config --system user.name "agentex-bot" \
    && git config --system user.email "agentex@pnz1990.bot" \
    && git config --system credential.helper store \
    && git config --system safe.directory '*'

COPY entrypoint.sh /entrypoint.sh
COPY coordinator.sh /usr/local/bin/coordinator.sh
COPY identity.sh /agent/identity.sh
RUN mkdir -p /agent && chmod +x /entrypoint.sh /usr/local/bin/coordinator.sh /agent/identity.sh && chown -R agentex:agentex /entrypoint.sh /usr/local/bin/coordinator.sh /agent

USER agentex
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
