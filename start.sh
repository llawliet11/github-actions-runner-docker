#!/bin/bash

# Install Node.js with specified version
sudo -E /usr/local/bin/install-node.sh

# Generate a unique runner name using hostname
HOSTNAME=$(hostname)
RUNNER_NAME="runner-${HOSTNAME}"
echo "Configuring runner: ${RUNNER_NAME}"

# Registration function using PAT
registration_pat() {
    RUNNER_TOKEN=$(curl -s -X POST \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${GITHUB_PAT}" \
        "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/actions/runners/registration-token" \
        | jq -r .token)
}

# Registration function using manual token
registration_token() {
    RUNNER_TOKEN=${RUNNER_TOKEN}
}

# Choose registration method
if [ -n "${GITHUB_PAT}" ]; then
    echo "Using PAT for runner registration"
    registration_pat
elif [ -n "${RUNNER_TOKEN}" ]; then
    echo "Using manual runner token"
    registration_token
else
    echo "Error: Neither GITHUB_PAT nor RUNNER_TOKEN is provided"
    exit 1
fi

# Configure the runner
./config.sh \
    --url "https://github.com/${GITHUB_OWNER}/${GITHUB_REPOSITORY}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --work "${RUNNER_WORKDIR:-_work}" \
    --labels "${RUNNER_LABELS:-self-hosted}" \
    --unattended \
    --replace \
    --ephemeral

# Cleanup function for graceful shutdown
cleanup() {
    if [ -n "${GITHUB_PAT}" ]; then
        TOKEN=$(curl -s -X POST \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Authorization: token ${GITHUB_PAT}" \
            "https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPOSITORY}/actions/runners/remove-token" \
            | jq -r .token)
    else
        TOKEN=${RUNNER_TOKEN}
    fi

    ./config.sh remove --token "${TOKEN}"
    exit
}

# Set up signal handlers
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Start the runner
./run.sh "$*" &

# Wait for the runner to exit
wait $!
