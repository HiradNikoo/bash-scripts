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
DOCKER_VERSION="20.10.7"
DOCKER_OFFLINE_DIR="/tmp/docker_offline"
DOCKER_OFFLINE_TAR="docker_${DOCKER_VERSION}.tar.gz"
OUTLINE_REPO="https://github.com/Jigsaw-Code/outline-server.git"
OUTLINE_DIR="/tmp/outline-server"
OUTLINE_IMAGE="outline/shadowbox:custom"
OUTLINE_CONTAINER_NAME="shadowbox"

# Step 1: Install Docker and build dependencies
echo "Installing Docker and build dependencies..."
sudo apt-get update
sudo apt-get install -y docker.io git unzip nodejs npm
# Install Yarn, required for Outline build
sudo npm install -g yarn
sudo systemctl start docker
sudo systemctl enable docker

# Step 2: Clone Outline repository and build Shadowbox image
echo "Cloning Outline server repository..."
rm -rf ${OUTLINE_DIR}
git clone ${OUTLINE_REPO} ${OUTLINE_DIR}
cd ${OUTLINE_DIR}/src/shadowbox
echo "Building Shadowbox Docker image..."
sudo docker build -t ${OUTLINE_IMAGE} .
if [ $? -ne 0 ]; then
    echo "Error: Failed to build Shadowbox image. Check the Dockerfile and build requirements."
    exit 1
fi
cd /tmp
rm -rf ${OUTLINE_DIR}

# Step 3: Create configuration directory
echo "Creating configuration directory..."
sudo mkdir -p ${CONFIG_DIR}

# Step 4: Generate a sample configuration (customizable)
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

# Step 5: Export Docker image
echo "Exporting Docker image to tar file..."
sudo docker save -o outline_server_image.tar ${OUTLINE_IMAGE}

# Step 6: Download Docker offline installer
echo "Downloading Docker offline installer..."
mkdir -p ${DOCKER_OFFLINE_DIR}
cd ${DOCKER_OFFLINE_DIR}
wget https://download.docker.com/linux/ubuntu/dists/focal/pool/stable/amd64/containerd.io_1.6.9-1_amd64.deb
wget https://download.docker.com/linux/ubuntu/dists/focal/pool/stable/amd64/docker-ce-cli_${DOCKER_VERSION}~3-0~ubuntu-focal_amd64.deb
wget https://download.docker.com/linux/ubuntu/dists/focal/pool/stable/amd64/docker-ce_${DOCKER_VERSION}~3-0~ubuntu-focal_amd64.deb
tar -czvf ${DOCKER_OFFLINE_TAR} *.deb
mv ${DOCKER_OFFLINE_TAR} /tmp/
cd /tmp
rm -rf ${DOCKER_OFFLINE_DIR}

# Step 7: Zip Outline image, configuration, and Docker installer
echo "Zipping Outline image, configuration, and Docker installer..."
zip -r ${ZIP_OUTPUT} outline_server_image.tar ${CONFIG_FILE} ${DOCKER_OFFLINE_TAR}

# Step 8: Clean up
echo "Cleaning up temporary files..."
rm outline_server_image.tar ${DOCKER_OFFLINE_TAR}

echo "Bundle created as ${ZIP_OUTPUT}"
echo "Transfer ${ZIP_OUTPUT} to https://bash.hiradnikoo.com/outline/files/ and extract docker_${DOCKER_VERSION}.tar.gz for separate upload."
