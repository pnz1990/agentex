FROM ubuntu:24.04

ARG KUBECTL_VERSION=1.31.0
ARG GH_VERSION=2.63.2
ARG OPENCODE_VERSION=latest
# Note: UID/GID are reserved shell vars in bash; use AGENT_UID/AGENT_GID instead
ARG AGENT_UID=1000
ARG AGENT_GID=1000

RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    unzip \
    ca-certificates \
    gnupg \
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
RUN npm install -g opencode-ai@${OPENCODE_VERSION}

# Create non-root user for PSA restricted compliance
RUN groupadd -g ${AGENT_GID} agentex && useradd -u ${AGENT_UID} -g ${AGENT_GID} -m -s /bin/bash agentex

# Directories the agent needs write access to
RUN mkdir -p /workspace /home/agentex/.config/opencode /home/agentex/.kube \
    && chown -R agentex:agentex /workspace /home/agentex

# OpenCode permissions config — allow all tool calls without interactive prompts.
# Agents run headlessly; any "ask" action blocks the entire task indefinitely.
# external_directory defaults to "ask" and must be overridden for /tmp, /workspace etc.
RUN mkdir -p /home/agentex/.config/opencode && \
    printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "permission": "allow"\n}\n' \
    > /home/agentex/.config/opencode/config.json

# git config (global, owned by agentex user)
RUN git config --system user.name "agentex-bot" \
    && git config --system user.email "agentex@pnz1990.bot" \
    && git config --system credential.helper store \
    && git config --system safe.directory '*'

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown agentex:agentex /entrypoint.sh

USER agentex
WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
