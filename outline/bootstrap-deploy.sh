#!/bin/bash

# Bootstrap script to download and run deploy_outline_server.sh
# Run on the second Ubuntu server with limited internet

# Exit on error
set -e

# Variables
SCRIPT_URL="https://bash.hiradnikoo.com/outline/files/deploy_outline_server.sh"
SCRIPT_NAME="deploy_outline_server.sh"

# Step 1: Download the deploy script
echo "Downloading deploy script from ${SCRIPT_URL}..."
if ! wget -q --tries=3 --timeout=10 "${SCRIPT_URL}" -O "${SCRIPT_NAME}"; then
  echo "Error: Failed to download ${SCRIPT_URL}. Check the URL or network connection."
  exit 1
fi

# Step 2: Make the script executable
echo "Making the script executable..."
chmod +x "${SCRIPT_NAME}"

# Step 3: Run the script
echo "Running deploy_outline_server.sh..."
sudo ./"${SCRIPT_NAME}"

# Step 4: Clean up
echo "Cleaning up..."
rm "${SCRIPT_NAME}"

echo "Deployment complete."

