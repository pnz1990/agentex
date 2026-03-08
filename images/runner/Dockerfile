FROM ubuntu:24.04

ARG KUBECTL_VERSION=1.31.0
ARG GH_VERSION=2.63.2
ARG OPENCODE_VERSION=latest

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

# git config
RUN git config --global user.name "agentex-bot" \
    && git config --global user.email "agentex@pnz1990.bot" \
    && git config --global credential.helper store

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /workspace
ENTRYPOINT ["/entrypoint.sh"]
