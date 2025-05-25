#!/bin/bash

# Bootstrap script to download and run setup_outline_server.sh
# Run on the first Ubuntu server with internet access

# Exit on error
set -e

# Variables
SCRIPT_URL="https://bash.hiradnikoo.com/outline/setup_outline_server.sh"
SCRIPT_NAME="setup_outline_server.sh"

# Step 1: Download the setup script
echo "Downloading setup script from ${SCRIPT_URL}..."
if ! wget -q --tries=3 --timeout=10 "${SCRIPT_URL}" -O "${SCRIPT_NAME}"; then
  echo "Error: Failed to download ${SCRIPT_URL}. Check the URL or network connection."
  exit 1
fi

# Step 2: Make the script executable
echo "Making the script executable..."
chmod +x "${SCRIPT_NAME}"

# Step 3: Run the script
echo "Running setup_outline_server.sh..."
sudo ./"${SCRIPT_NAME}"

# Step 4: Clean up
echo "Cleaning up..."
rm "${SCRIPT_NAME}"

echo "Setup complete. Upload outline_docker_bundle.zip and docker_offline.tar.gz to https://bash.hiradnikoo.com/outline/files/"
echo "You can now transfer the files to the second server and run deploy_outline_server.sh."
