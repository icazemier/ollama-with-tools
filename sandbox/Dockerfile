# Sandbox container — a dev environment for running code alongside the AI.
#
# This gives you a Node.js environment with git and Azure CLI,
# isolated inside Docker. Think of it as a lightweight VM where
# you can run code, manage repos, and interact with Azure DevOps —
# without installing anything on your host machine.
#
# What's inside:
#   - Node.js 22 (for running JavaScript/TypeScript)
#   - git + SSH client (for cloning, pushing, pulling repos)
#   - Azure CLI (for Azure DevOps work items and code reviews)
#   - curl, build-essential (for general dev tasks and compiling native modules)
#
# The sandbox runs as a non-root user (sandbox, UID 1001) for security.
# Your host's SSH keys and git config can be mounted read-only via .env.

FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    ca-certificates \
    build-essential \
    gnupg \
    lsb-release \
    apt-transport-https \
    && curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root user for security
RUN groupadd -g 1001 sandbox \
    && useradd -u 1001 -g sandbox -m -s /bin/bash sandbox

# Set up workspace directory
RUN mkdir -p /workspace/node_modules \
    && chown -R sandbox:sandbox /workspace

WORKDIR /workspace
USER sandbox

# Keep container running so you can exec into it
CMD ["tail", "-f", "/dev/null"]
