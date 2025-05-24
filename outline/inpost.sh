#!/bin/bash

# Script to deploy Outline Server with offline Docker installation
# Run on the second Ubuntu server with limited internet

# Exit on error
set -e

# Variables
WEBSITE_URL="https://files.hiradnikoo.com/outline"
ZIP_FILE="outline_docker_bundle.zip"
DOCKER_OFFLINE_TAR="docker_20.10.7.tar.gz"
CONFIG_DIR="/opt/outline/config"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
OUTLINE_IMAGE="outline/shadowbox:latest"
OUTLINE_CONTAINER_NAME="outline-server"
DOCKER_PORT="8080"
API_PORT="8081"
SERVER_IP=$(ip addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | grep -v '127.0.0.1' | head -n 1)

# Step 1: Download the bundle and Docker offline installer
echo "Downloading files from ${WEBSITE_URL}..."
wget ${WEBSITE_URL}/${ZIP_FILE}
wget ${WEBSITE_URL}/${DOCKER_OFFLINE_TAR}

# Step 2: Unzip the bundle
echo "Unzipping bundle..."
unzip ${ZIP_FILE}

# Step 3: Install dependencies for Docker
echo "Installing Docker dependencies..."
sudo apt-get update
sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common \
    unzip

# Step 4: Install Docker offline
echo "Installing Docker from offline packages..."
tar -xzvf ${DOCKER_OFFLINE_TAR}
sudo dpkg -i containerd.io_*.deb
sudo dpkg -i docker-ce-cli_*.deb
sudo dpkg -i docker-ce_*.deb
sudo systemctl start docker
sudo systemctl enable docker

# Step 5: Load Docker image
echo "Loading Outline Server Docker image..."
sudo docker load -i outline_server_image.tar

# Step 6: Create configuration directory
echo "Creating configuration directory..."
sudo mkdir -p ${CONFIG_DIR}

# Step 7: Move configuration file
echo "Moving configuration file..."
sudo mv shadowbox_config.json ${CONFIG_FILE}

# Step 8: Update configuration with new server IP
echo "Updating configuration with server IP: ${SERVER_IP}..."
sudo sed -i "s/0.0.0.0/${SERVER_IP}/g" ${CONFIG_FILE}

# Step 9: Run Outline Server
echo "Starting Outline Server..."
sudo docker run --name ${OUTLINE_CONTAINER_NAME} -d \
  -p ${DOCKER_PORT}:8080 \
  -p ${API_PORT}:8081 \
  -v ${CONFIG_FILE}:/root/shadowbox_config.json \
  ${OUTLINE_IMAGE}

# Step 10: Clean up
echo "Cleaning up temporary files..."
rm outline_server_image.tar ${DOCKER_OFFLINE_TAR} *.deb ${ZIP_FILE}

echo "Outline Server is running on ${SERVER_IP}:${DOCKER_PORT}"
echo "API is accessible at ${SERVER_IP}:${API_PORT}"
echo "Setup complete. Outline Server is ready to use."