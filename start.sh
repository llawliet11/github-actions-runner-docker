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

# --- Idempotent guard -------------------------------------------------------
# With a restart policy + --ephemeral, the same container layer can outlive a
# job and keep a stale .runner file. config.sh would then abort with
# "Cannot configure the runner because it is already configured", and the
# container would crash-loop. Clearing the local registration first makes every
# (re)start a clean configure. (--replace only fixes the GitHub-side conflict,
# not this local guard.)
rm -f .runner .credentials .credentials_rsaparams 2>/dev/null || true

# --- Self-heal bin/ ---------------------------------------------------------
# A forced runner self-update runs `mv bin bin.<old>; mv bin.<new> bin`. If that
# swap is interrupted (container restart mid-update) bin/ goes missing and
# run.sh dies with `./bin/Runner.Listener: No such file or directory` (exit 127).
# Restore bin/ from the newest bin.* backup, or re-extract a bundled tarball.
if [ ! -x ./bin/Runner.Listener ]; then
    echo "bin/Runner.Listener missing - attempting self-heal"
    newest_bin=$(ls -d bin.* 2>/dev/null | sort -V | tail -n1)
    tarball=$(ls actions-runner-linux-*.tar.gz 2>/dev/null | sort -V | tail -n1)
    if [ -n "${newest_bin}" ] && [ -x "${newest_bin}/Runner.Listener" ]; then
        echo "Restoring bin/ from ${newest_bin}"
        rm -rf bin && cp -a "${newest_bin}" bin
    elif [ -n "${tarball}" ]; then
        echo "Re-extracting runner from ${tarball}"
        tar xzf "${tarball}"
    else
        echo "ERROR: cannot self-heal bin/ (no bin.* backup, no tarball)." >&2
        echo "       Recreate the container from the image to recover." >&2
        exit 1
    fi
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
