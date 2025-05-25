#!/bin/bash

# Script to set up Outline Server and Docker offline installer, then zip them
# Run on the first Ubuntu server with internet access

# Exit on error
set -e

# Variables
CONFIG_DIR="/opt/outline/config"
ZIP_OUTPUT="outline_docker_bundle.zip"
DOCKER_PORT="8080"
API_PORT="8081"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
DOCKER_VERSION="28.1.1"
DOCKER_OFFLINE_DIR="/tmp/docker_offline"
DOCKER_OFFLINE_TAR="docker_${DOCKER_VERSION}.tar.gz"
OUTLINE_IMAGE="quay.io/outline/shadowbox:latest"
OUTLINE_CONTAINER_NAME="shadowbox"
UBUNTU_CODENAME=$(lsb_release -cs)

# Step 1: Install prerequisites
echo "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip

# Step 2: Set up Docker repository
echo "Setting up Docker repository..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Step 3: Install Docker
echo "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker
sudo systemctl enable docker

# Step 4: Pull Outline Server image
echo "Pulling Outline Server image..."
sudo docker pull ${OUTLINE_IMAGE}

# Step 5: Create configuration directory
echo "Creating configuration directory..."
sudo mkdir -p ${CONFIG_DIR}

# Step 6: Generate a sample configuration (customizable)
echo "Generating sample configuration..."
sudo docker run --name ${OUTLINE_CONTAINER_NAME} -d -p ${DOCKER_PORT}:8080 -p ${API_PORT}:8081 ${OUTLINE_IMAGE}
sleep 10
sudo docker exec ${OUTLINE_CONTAINER_NAME} /bin/sh -c "echo '{
  \"apiUrl\": \"https://0.0.0.0:${API_PORT}\",
  \"port\": ${DOCKER_PORT},
  \"hostname\": \"0.0.0.0\"
}' > /root/shadowbox_config.json"

# Copy configuration to host
sudo docker cp ${OUTLINE_CONTAINER_NAME}:/root/shadowbox_config.json ${CONFIG_FILE}

# Stop and remove the temporary container
echo "Cleaning up temporary container..."
sudo docker stop ${OUTLINE_CONTAINER_NAME}
sudo docker rm ${OUTLINE_CONTAINER_NAME}

# Step 7: Export Docker image
echo "Exporting Docker image to tar file..."
sudo docker save -o outline_server_image.tar ${OUTLINE_IMAGE}

# Step 8: Download Docker offline installer packages
echo "Downloading Docker offline installer packages..."
mkdir -p ${DOCKER_OFFLINE_DIR}
cd ${DOCKER_OFFLINE_DIR}
wget https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/pool/stable/amd64/containerd.io_1.7.26-1_amd64.deb
wget https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/pool/stable/amd64/docker-ce-cli_${DOCKER_VERSION}-1~ubuntu.24.04~noble_amd64.deb
wget https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/pool/stable/amd64/docker-ce_${DOCKER_VERSION}-1~ubuntu.24.04~noble_amd64.deb
wget https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/pool/stable/amd64/docker-buildx-plugin_0.16.2-1~ubuntu.24.04~noble_amd64.deb
wget https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/pool/stable/amd64/docker-compose-plugin_2.35.1-1~ubuntu.24.04~noble_amd64.deb
tar -czvf ${DOCKER_OFFLINE_TAR} *.deb
mv ${DOCKER_OFFLINE_TAR} /tmp/
cd /tmp
rm -rf ${DOCKER_OFFLINE_DIR}

# Step 9: Zip Outline image, configuration, and Docker installer
echo "Zipping Outline image, configuration, and Docker installer..."
zip -r ${ZIP_OUTPUT} outline_server_image.tar ${CONFIG_FILE} ${DOCKER_OFFLINE_TAR}

# Step 10: Clean up
echo "Cleaning up temporary files..."
rm outline_server_image.tar ${DOCKER_OFFLINE_TAR}

echo "Bundle created as ${ZIP_OUTPUT}"
echo "Transfer ${ZIP_OUTPUT} to https://bash.hiradnikoo.com/outline/files and extract docker_${DOCKER_VERSION}.tar.gz for separate upload."
# End of script