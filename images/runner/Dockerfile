FROM ubuntu:24.04

# Image version: 2026-03-09-r5 (fix: planner-loop reads model from constitution; issue #968)
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

# Fix npm bundled dependency CVEs (issue #858, issue #658)
# npm bundles tar, minimatch, and glob in /usr/lib/node_modules/npm/node_modules/
# HIGH CVEs fixed:
#   tar: >=7.5.10 (CVE-2026-29786: prior to 7.5.10 has HIGH severity vulnerability)
#   minimatch: >=10.2.3 (CVE-2026-27903, CVE-2026-27904: 10.2.2 vulnerable, 10.2.3 is fixed)
#     NOTE: constraint must be >=10.2.3 not >=9.0.7 because npm 11 resolves to v10.x series
#     and 10.2.2 has HIGH CVEs; using >=9.0.7 installs 10.2.2 (latest matching), not 10.2.3
#   glob: >=10.5.0 (CVE for glob <10.5.0)
# Fix: upgrade npm itself (npm 11+ ships with patched bundled deps)
# Also: upgrade specific vulnerable packages directly in npm's own node_modules
RUN npm install -g npm@latest \
    && cd /usr/lib/node_modules/npm \
    && npm install --prefer-online \
        tar@">=7.5.10" \
        minimatch@">=10.2.3" \
        glob@">=10.5.0" \
    2>/dev/null || true \
    && npm cache clean --force \
    && rm -rf /root/.npm

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
COPY planner-loop.sh /usr/local/bin/planner-loop.sh
COPY identity.sh /agent/identity.sh
RUN mkdir -p /agent && chmod +x /entrypoint.sh /usr/local/bin/coordinator.sh /usr/local/bin/planner-loop.sh /agent/identity.sh && chown -R agentex:agentex /entrypoint.sh /usr/local/bin/coordinator.sh /usr/local/bin/planner-loop.sh /agent

USER agentex
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
