#!/bin/bash

# Read Node.js version from environment variable or use default
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
source "$NVM_DIR/nvm.sh"

nvm install ${NODE_VERSION}
nvm use ${NODE_VERSION}
nvm alias default

# Install Yarn
npm install -g yarn
npm install -g pnpm

# Verify installations
node --version
npm --version
yarn --version
pnpm --version
