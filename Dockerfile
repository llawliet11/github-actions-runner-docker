FROM ubuntu:22.04

# Prevent prompts during package installation
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETPLATFORM
ARG TARGETARCH

# Arguments that can be passed during build
ARG RUNNER_VERSION="2.314.1"

# Environment variables
ENV GITHUB_PAT=""
ENV GITHUB_OWNER=""
ENV GITHUB_REPOSITORY=""
ENV RUNNER_NAME=""
ENV RUNNER_WORKDIR="_work"
ENV RUNNER_GROUP="default"
ENV RUNNER_LABELS=""
ENV NODE_VERSION="18"

# Install required packages and dependencies
RUN apt-get update && apt-get install -y \
    curl \
    sudo \
    git \
    jq \
    build-essential \
    libssl-dev \
    libffi-dev \
    python3 \
    python3-pip \
    python3-venv \
    unzip \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js using a script that reads the version from env
COPY --chown=root:root install-node.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/install-node.sh

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && sudo ./aws/install \
    && rm -rf aws awscliv2.zip

# Create a user for the runner
RUN useradd -m -s /bin/bash runner \
    && usermod -aG sudo runner \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set up the GitHub runner
WORKDIR /home/runner
USER runner

# Download and install the GitHub runner
RUN RUNNER_ARCH=$(case ${TARGETARCH:-amd64} in \
        "amd64") echo "x64" ;; \
        "arm64") echo "arm64" ;; \
        *) echo "x64" ;; \
    esac) \
    && curl -o actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz \
        -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz \
    && tar xzf actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz \
    && rm actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz

# Install runner dependencies
RUN sudo ./bin/installdependencies.sh

# Copy the startup script
COPY --chown=runner:runner start.sh .
RUN sudo chmod +x start.sh

# Start the runner
ENTRYPOINT ["./start.sh"]