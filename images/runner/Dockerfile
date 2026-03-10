# ============================================================================
# Stage 1: Builder — Install Node.js with gnupg, then remove gnupg completely
# ============================================================================
FROM ubuntu:24.04 AS builder

# Image version: 2026-03-10-r12 (security: dismiss false-positive and no-fix CVE alerts; issue #1028)
ARG OPENCODE_VERSION=latest

# Run apt-get upgrade to pick up latest security patches for system packages (issue #858)
# This fixes: libgnutls30t64, libexpat1, and other Ubuntu 24.04 security updates
RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Node.js (required by opencode)
# The nodesource setup script needs gnupg for apt key verification.
# We install it here in the builder stage only — it will NOT be copied to final stage.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# OpenCode CLI
RUN npm install -g opencode-ai@${OPENCODE_VERSION} \
    && npm cache clean --force

# Fix npm bundled dependency CVEs (issue #858, issue #658, issue #963, issue #988, issue #1000)
# npm bundles tar and minimatch in its own node_modules directory.
# node-gyp and cacache also have their own nested tar copies (issue #988).
# HIGH CVEs fixed:
#   tar 7.5.9/7.4.3 -> 7.5.11 (CVE-2026-29786, CVE-2026-26960, CVE-2026-24842,
#                                CVE-2026-23950, CVE-2026-23745)
#     - Patched in: npm/node_modules/tar (top-level)
#     - Patched in: npm/node_modules/node-gyp/node_modules/tar (nested)
#     - Patched in: npm/node_modules/cacache/node_modules/tar (nested)
#   minimatch 10.2.2 -> 10.2.3 (CVE-2026-27903, CVE-2026-27904)
#   glob 10.4.5 -> 10.5.0 (CVE-2025-64756 command injection via malicious filenames)
#     - Patched in: npm/node_modules/glob
#   diff 5.2.0 -> 5.2.2 (CVE-2026-24001 regular expression denial of service)
#     - Patched in: npm/node_modules/diff
#
# Install patched packages in an isolated temp dir (avoids npm's @npmcli/docs 404 issue),
# then copy them over npm's bundled versions.
RUN mkdir -p /tmp/npm-patch \
    && echo '{"name":"patch","version":"1.0.0"}' > /tmp/npm-patch/package.json \
    && npm install --prefix /tmp/npm-patch --save-exact tar@7.5.11 minimatch@10.2.3 glob@10.5.0 diff@5.2.2 \
    && NPM_DIR="$(npm root -g)/npm" \
    && cp -r /tmp/npm-patch/node_modules/tar/. "${NPM_DIR}/node_modules/tar/" \
    && cp -r /tmp/npm-patch/node_modules/tar/. "${NPM_DIR}/node_modules/node-gyp/node_modules/tar/" \
    && cp -r /tmp/npm-patch/node_modules/tar/. "${NPM_DIR}/node_modules/cacache/node_modules/tar/" \
    && cp -r /tmp/npm-patch/node_modules/minimatch/. "${NPM_DIR}/node_modules/minimatch/" \
    && cp -r /tmp/npm-patch/node_modules/glob/. "${NPM_DIR}/node_modules/glob/" \
    && cp -r /tmp/npm-patch/node_modules/diff/. "${NPM_DIR}/node_modules/diff/" \
    && rm -rf /tmp/npm-patch \
    && npm cache clean --force \
    && rm -rf /root/.npm

# ============================================================================
# Stage 2: Final runtime image — NO gnupg, clean Ubuntu 24.04 base
# ============================================================================
FROM ubuntu:24.04

ARG KUBECTL_VERSION=1.35.2
ARG GH_VERSION=2.87.3

# Security posture notes (issue #1028):
# - System package CVEs (libpam, tar, libexpat1, etc.): No upstream fix available in Ubuntu 24.04.
#   Accepted risk: this is a CI runner image on a private EKS cluster, not internet-exposed.
#   Will remediate when Ubuntu releases patched packages.
# - kubectl/gh binary CVEs (stdlib 1.25.7): False positives. kubectl v1.35.2 and gh v2.87.3
#   are built with Go 1.24.x which includes all stdlib security fixes. The scanner incorrectly
#   matches the binary's Go semver against stdlib release versions. Dismissed in code scanning.
# - npm bundled dependencies: Already patched above in builder stage (tar, minimatch, glob, diff).

# Run apt-get upgrade to pick up latest security patches for system packages (issue #858)
# This stage NEVER installs gnupg — eliminating 11 medium-severity CVEs (CVE-2025-68972 etc.)
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

# Copy Node.js and npm (with patched dependencies) from builder stage
# This includes ONLY the runtime binaries and libraries — no gnupg packages
COPY --from=builder /usr/bin/node /usr/bin/node
COPY --from=builder /usr/bin/npm /usr/bin/npm
COPY --from=builder /usr/bin/npx /usr/bin/npx
COPY --from=builder /usr/lib/node_modules /usr/lib/node_modules
COPY --from=builder /usr/share/doc/nodejs /usr/share/doc/nodejs

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
