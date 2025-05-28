#!/bin/bash

# Script to deploy Outline Server on a server with limited internet
# Run on the second Ubuntu server

# Exit on error
set -e

# Variables
CONFIG_DIR="/opt/outline/config"
ZIP_BUNDLE="outline_docker_bundle.zip"
DOWNLOAD_URL="http://github.com/HiradNikoo/bash-scripts/releases/latest/download/outline_docker_bundle.zip"
DOCKER_PORT="8080"
API_PORT="8081"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
DOCKER_OFFLINE_TAR="docker_offline.tar.gz"
OUTLINE_IMAGE="quay.io/outline/shadowbox:stable"
OUTLINE_CONTAINER_NAME="shadowbox"

# Step 1: Install wget and unzip
echo "Installing wget and unzip..."
sudo apt-get update
sudo apt-get install -y wget unzip tar

# Step 2: Download the bundle
echo "Downloading the bundle from ${DOWNLOAD_URL}..."
wget -O "${ZIP_BUNDLE}" "${DOWNLOAD_URL}"
if [ ! -f "${ZIP_BUNDLE}" ]; then
  echo "Error: Failed to download the bundle."
  exit 1
fi

# Step 3: Unzip the bundle
echo "Unzipping the bundle..."
unzip "${ZIP_BUNDLE}"

# Step 4: Install Docker from offline packages
echo "Installing Docker from offline packages..."
tar -xzvf "${DOCKER_OFFLINE_TAR}"
sudo dpkg -i *.deb
if ! sudo systemctl is-active --quiet docker; then
  echo "Starting Docker service..."
  sudo systemctl start docker || {
    echo "Error: Failed to start Docker service. Check 'systemctl status docker' for details."
    exit 1
  }
fi
sudo systemctl enable docker

# Step 5: Load Outline Server image
echo "Loading Outline Server image..."
sudo docker load -i outline_server_image.tar

# Step 6: Create configuration directory
echo "Creating configuration directory..."
sudo mkdir -p "${CONFIG_DIR}"

# Step 7: Move configuration file
echo "Moving configuration file..."
sudo mv shadowbox_config.json "${CONFIG_FILE}"

# Step 8: Update configuration with server IP
echo "Updating configuration with server IP..."
SERVER_IP=$(ip addr show $(ip route | awk '/default/ {print $5}') | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)
if [ -z "${SERVER_IP}" ]; then
  echo "Error: Could not determine server IP address."
  exit 1
fi
sudo sed -i "s/0.0.0.0/${SERVER_IP}/g" "${CONFIG_FILE}"

# Step 9: Run Outline Server container
echo "Starting Outline Server container..."
sudo docker run --name "${OUTLINE_CONTAINER_NAME}" -d --restart=always \
  -p "${DOCKER_PORT}:8080" -p "${API_PORT}:8081" \
  -v "${CONFIG_FILE}:/root/shadowbox_config.json" \
  "${OUTLINE_IMAGE}"

# Step 10: Clean up
echo "Cleaning up..."
rm -f outline_server_image.tar "${DOCKER_OFFLINE_TAR}" *.deb "${ZIP_BUNDLE}"

echo "Outline Server deployed successfully."
echo "Access the API at https://${SERVER_IP}:${API_PORT}"
echo "Access the web interface at http://${SERVER_IP}:${DOCKER_PORT}"