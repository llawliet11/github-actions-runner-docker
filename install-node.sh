#!/bin/bash

# Read Node.js version from environment variable or use default
NODE_VERSION=${NODE_VERSION:-"18"}

# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt-get install -y nodejs

# Install Yarn
npm install -g yarn

# Verify installations
node --version
npm --version
yarn --version