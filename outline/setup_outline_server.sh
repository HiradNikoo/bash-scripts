#!/bin/bash

# Script to set up Outline Server and Docker offline installer, then zip them
# Run on the first Ubuntu server with internet access
# Creates a 'files' directory in the current working directory for output

# Exit on error
set -e

# Variables
FILES_DIR="$(pwd)/files"  # Use absolute path for FILES_DIR
CONFIG_DIR="/opt/outline/config"
ZIP_OUTPUT="${FILES_DIR}/outline_docker_bundle.zip"
DOCKER_PORT="8080"
API_PORT="8081"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
DOCKER_OFFLINE_DIR="/tmp/docker_offline"
DOCKER_OFFLINE_TAR="docker_offline.tar.gz"
OUTLINE_IMAGE="quay.io/outline/shadowbox:stable"
OUTLINE_CONTAINER_NAME="shadowbox"
UBUNTU_CODENAME=$(lsb_release -cs)
ARCH=$(dpkg --print-architecture)
OUTLINE_IMAGE_TAR="${FILES_DIR}/outline_server_image.tar"  # Store tar in FILES_DIR

# Step 1: Install prerequisites
echo "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip wget apt-transport-https gnupg lsb-release zip

# Step 2: Set up Docker repository
echo "Setting up Docker repository..."
sudo install -m 0755 -d /etc/apt/keyrings
[ -f /etc/apt/keyrings/docker.gpg ] && sudo rm /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Step 3: Install Docker
echo "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
if ! sudo systemctl is-active --quiet docker; then
  echo "Starting Docker service..."
  sudo systemctl start docker || {
    echo "Error: Failed to start Docker service. Check 'systemctl status docker' for details."
    exit 1
  }
fi
sudo systemctl enable docker

# Step 4: Pull Outline Server image
echo "Pulling Outline Server image..."
sudo docker pull "${OUTLINE_IMAGE}"

# Step 5: Create configuration directory
echo "Creating configuration directory..."
sudo mkdir -p "${CONFIG_DIR}"
sudo chown $(whoami):$(whoami) "${CONFIG_DIR}"  # Ensure user can write to config dir

# Step 6: Generate sample configuration
echo "Generating sample configuration..."
sudo bash -c "cat > ${CONFIG_FILE} <<EOF
{
  \"apiUrl\": \"https://0.0.0.0:${API_PORT}\",
  \"port\": ${DOCKER_PORT},
  \"hostname\": \"0.0.0.0\"
}
EOF"
sudo chown $(whoami):$(whoami) "${CONFIG_FILE}"  # Ensure user can read config file

# Step 7: Export Docker image
echo "Exporting Docker image to tar file..."
mkdir -p "${FILES_DIR}"
sudo docker save -o "${OUTLINE_IMAGE_TAR}" "${OUTLINE_IMAGE}"
if [ ! -f "${OUTLINE_IMAGE_TAR}" ]; then
  echo "Error: Failed to create ${OUTLINE_IMAGE_TAR}"
  exit 1
fi
sudo chown $(whoami):$(whoami) "${OUTLINE_IMAGE_TAR}"  # Ensure user can read tar file

# Step 8: Download Docker offline installer packages
echo "Downloading Docker offline installer packages..."
mkdir -p "${DOCKER_OFFLINE_DIR}"
cd "${DOCKER_OFFLINE_DIR}"

# Dynamically fetch the latest stable package versions
BASE_URL="https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/pool/stable/${ARCH}"
for pkg in "containerd.io" "docker-ce" "docker-ce-cli" "docker-buildx-plugin" "docker-compose-plugin"; do
  echo "Fetching latest ${pkg}..."
  pkg_file=$(curl -s "${BASE_URL}/" | grep "${pkg}_" | awk -F'"' '{print $2}' | sort -V | tail -n 1)
  if [ -z "${pkg_file}" ]; then
    echo "Error: Could not find package for ${pkg}."
    exit 1
  fi
  wget -q "${BASE_URL}/${pkg_file}" || {
    echo "Error: Failed to download ${pkg_file}."
    exit 1
  }
done

tar -czvf "${DOCKER_OFFLINE_TAR}" *.deb
if [ ! -f "${DOCKER_OFFLINE_TAR}" ]; then
  echo "Error: Failed to create ${DOCKER_OFFLINE_TAR}"
  exit 1
fi
mkdir -p "${FILES_DIR}"
mv "${DOCKER_OFFLINE_TAR}" "${FILES_DIR}/" || {
  echo "Error: Failed to move ${DOCKER_OFFLINE_TAR} to ${FILES_DIR}/"
  exit 1
}
sudo chown $(whoami):$(whoami) "${FILES_DIR}/${DOCKER_OFFLINE_TAR}"  # Ensure user can read tar file
cd /tmp
rm -rf "${DOCKER_OFFLINE_DIR}"

# Step 9: Zip Outline image and configuration
echo "Zipping Outline image, configuration, and Docker installer..."
# Verify all files exist
for file in "${OUTLINE_IMAGE_TAR}" "${CONFIG_FILE}" "${FILES_DIR}/${DOCKER_OFFLINE_TAR}"; do
  if [ ! -f "${file}" ]; then
    echo "Error: File ${file} does not exist"
    exit 1
  fi
  echo "Confirmed ${file} exists"
done

# Ensure zip command is available
if ! command -v zip &> /dev/null; then
  echo "Error: zip command not found. Please ensure zip is installed."
  exit 1
fi

# Change to FILES_DIR to simplify zip paths
cd "${FILES_DIR}"
zip -r "${ZIP_OUTPUT}" "$(basename ${OUTLINE_IMAGE_TAR})" "${CONFIG_FILE}" "${DOCKER_OFFLINE_TAR}" || {
  echo "Error: Failed to create zip file ${ZIP_OUTPUT}"
  exit 1
}

# Verify zip file was created
if [ ! -f "${ZIP_OUTPUT}" ]; then
  echo "Error: Zip file ${ZIP_OUTPUT} was not created"
  exit 1
fi
echo "Zip file created successfully: ${ZIP_OUTPUT}"

# Step 10: Clean up
echo "Cleaning up temporary files..."
rm -f "${OUTLINE_IMAGE_TAR}"
# Comment out the next line if you want to keep docker_offline.tar.gz in FILES_DIR for separate upload
# rm -f "${FILES_DIR}/${DOCKER_OFFLINE_TAR}"

echo "Bundle created as ${ZIP_OUTPUT}"
echo "Transfer ${ZIP_OUTPUT} to https://bash.hiradnikoo.com/outline/files and extract docker_offline.tar.gz for separate upload."
echo "You can now transfer the files to the second server and run deploy_outline_server.sh."
echo "On the second server (serverB), run the following command to fetch and execute bootstrap-deploy.sh:"
echo "wget -O bootstrap-deploy.sh https://bash.hiradnikoo.com/outline/bootstrap-deploy.sh && chmod +x bootstrap-deploy.sh && sudo ./bootstrap-deploy.sh"
