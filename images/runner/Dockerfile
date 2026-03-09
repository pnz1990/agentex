FROM ubuntu:24.04

# Image version: 2026-03-09-r7 (fix: security CVEs - fix npm CVE patch using clean-dir install; issue #963)
ARG KUBECTL_VERSION=1.35.2
ARG GH_VERSION=2.87.3
ARG OPENCODE_VERSION=latest

# Run apt-get upgrade to pick up latest security patches for system packages (issue #858)
# This fixes: libgnutls30t64, libexpat1, and other Ubuntu 24.04 security updates
# NOTE: gnupg is intentionally NOT installed here to avoid its CVEs (CVE-2025-68972 et al).
# The nodesource setup script temporarily needs gpg — it will install/use it automatically.
# After nodejs is installed, we purge gnupg to reduce attack surface.
RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    curl \
    git \
    jq \
    unzip \
    ca-certificates \
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
# nodesource setup script installs gnupg for apt key verification; we purge it afterward
# to eliminate 11 medium-severity gnupg CVEs (CVE-2025-68972 etc.) since gnupg is not
# used at runtime.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get purge -y --auto-remove gnupg gnupg2 gnupg-l10n gnupg-utils \
        gpg gpg-agent gpg-wks-client gpgconf gpgsm gpgv dirmngr keyboxd 2>/dev/null || true \
    && rm -rf /var/lib/apt/lists/*

# OpenCode CLI
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm cache clean --force

# Fix npm bundled dependency CVEs (issue #858, issue #658, issue #963)
# npm bundles tar and minimatch in its own node_modules directory.
# HIGH CVEs fixed:
#   tar 7.5.9 -> 7.5.11 (CVE-2026-29786: prior to 7.5.10 has HIGH severity vulnerability)
#   minimatch 10.2.2 -> 10.2.3 (CVE-2026-27903, CVE-2026-27904: 10.2.2 vulnerable)
#
# APPROACH: Install patched packages into a clean temp directory (no existing package.json),
# then copy them over npm's bundled versions.
#
# Why NOT use "cd $(npm root -g)/npm && npm install tar minimatch":
#   npm's own package.json has @npmcli/docs as a devDependency which doesn't exist on
#   the npm registry (returns 404). Running npm install in npm's directory triggers
#   resolution of ALL deps including devDeps, causing E404 build failure.
#
# The clean-dir approach: install packages in an isolated directory with a minimal
# package.json — no extra deps, no 404 errors, fully deterministic.
RUN NPM_DIR="$(npm root -g)/npm" \
    && echo "Patching npm bundled deps at: ${NPM_DIR}" \
    && mkdir -p /tmp/npm-patch \
    && echo '{"name":"patch","version":"1.0.0"}' > /tmp/npm-patch/package.json \
    && cd /tmp/npm-patch \
    && npm install --save-exact tar@7.5.11 minimatch@10.2.3 \
    && echo "Installed tar: $(node -e 'console.log(require("/tmp/npm-patch/node_modules/tar/package.json").version)')" \
    && echo "Installed minimatch: $(node -e 'console.log(require("/tmp/npm-patch/node_modules/minimatch/package.json").version)')" \
    && cp -r /tmp/npm-patch/node_modules/tar/. "${NPM_DIR}/node_modules/tar/" \
    && cp -r /tmp/npm-patch/node_modules/minimatch/. "${NPM_DIR}/node_modules/minimatch/" \
    && cd / \
    && npm cache clean --force \
    && rm -rf /tmp/npm-patch /root/.npm

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
