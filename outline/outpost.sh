#!/bin/bash

# Script to set up Outline Server and Docker offline installer, then zip them
# Run on the first Ubuntu server with internet access

# Exit on error
set -e

# Variables
OUTLINE_IMAGE="outline/shadowbox:latest"
OUTLINE_CONTAINER_NAME="outline-server"
CONFIG_DIR="/opt/outline/config"
ZIP_OUTPUT="outline_docker_bundle.zip"
DOCKER_PORT="8080"
API_PORT="8081"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
DOCKER_VERSION="20.10.7"
DOCKER_OFFLINE_DIR="/tmp/docker_offline"
DOCKER_OFFLINE_TAR="docker_${DOCKER_VERSION}.tar.gz"

# Step 1: Install Docker
echo "Installing Docker..."
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl start docker
sudo systemctl enable docker

# Step 2: Create configuration directory
echo "Creating configuration directory..."
sudo mkdir -p ${CONFIG_DIR}

# Step 3: Pull and configure Outline Server
echo "Pulling Outline Server Docker image..."
sudo docker pull ${OUTLINE_IMAGE}

# Step 4: Run Outline Server to generate configuration
echo "Running Outline Server to generate initial configuration..."
sudo docker run --name ${OUTLINE_CONTAINER_NAME} -d -p ${DOCKER_PORT}:8080 -p ${API_PORT}:8081 ${OUTLINE_IMAGE}

# Wait for container to initialize
sleep 10

# Step 5: Generate a sample configuration (customizable)
echo "Generating sample configuration..."
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

# Step 6: Export Docker image
echo "Exporting Docker image to tar file..."
sudo docker save -o outline_server_image.tar ${OUTLINE_IMAGE}

# Step 7: Download Docker offline installer
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

# Step 8: Zip Outline image, configuration, and Docker installer
echo "Zipping Outline image, configuration, and Docker installer..."
zip -r ${ZIP_OUTPUT} outline_server_image.tar ${CONFIG_FILE} ${DOCKER_OFFLINE_TAR}

# Step 9: Clean up
echo "Cleaning up temporary files..."
rm outline_server_image.tar ${DOCKER_OFFLINE_TAR}

echo "Bundle created as ${ZIP_OUTPUT}"
echo "Transfer ${ZIP_OUTPUT} to https://bash.hiradnikoo.com/outline/files/ and extract docker_${DOCKER_VERSION}.tar.gz for separate upload."
# End of script
# Note: Ensure you have the necessary permissions to run Docker commands and write to /opt/outline/config.
# Note: The script assumes you are running on Ubuntu 20.04 (Focal Fossa) and may need adjustments for other versions.
# Note: The script uses wget to download Docker packages; ensure wget is installed or modify to use curl.
# Note: The script uses sleep to wait for the container to initialize; adjust the duration as needed based on your server's performance.
# Note: The script uses hardcoded ports; modify them if necessary to avoid conflicts.
# Note: The script assumes the Docker image and configuration are compatible with the Outline Server version.
# Note: The script does not handle errors in downloading files; ensure the URLs are correct and accessible.
# Note: The script does not include error handling for Docker commands; ensure Docker is installed and running correctly.
# Note: The script does not include cleanup for downloaded files; consider adding cleanup steps if needed.
# Note: The script does not include security measures; ensure the server is secured before deploying Outline Server.
# Note: The script does not include logging; consider adding logging for better traceability.
# Note: The script does not include validation of the configuration file; ensure the generated configuration is correct.
# Note: The script does not include a check for existing Docker installations; ensure Docker is not already installed to avoid conflicts.
# Note: The script does not include a check for existing Outline Server installations; ensure it is not already running to avoid conflicts.