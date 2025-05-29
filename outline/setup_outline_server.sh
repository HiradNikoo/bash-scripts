#!/bin/bash

# Script to set up Outline Server and Docker offline installer, then zip them
# Run on the first Ubuntu server with internet access
# Creates a 'files' directory in the current working directory for output
# Verifies Outline VPN container is running and functional before exporting image
# Ensures container is rewritten on rerun by removing existing container
# Handles port conflicts and logs detailed errors

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
LOG_FILE="${FILES_DIR}/shadowbox_logs.txt"  # Log file for container logs

# Step 1: Install prerequisites
echo "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip wget apt-transport-https gnupg lsb-release zip net-tools

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

# Step 6: Generate sample configuration (use http to avoid SSL issues)
echo "Generating sample configuration..."
sudo bash -c "cat > ${CONFIG_FILE} <<EOF
{
  \"apiUrl\": \"http://0.0.0.0:${API_PORT}\",
  \"port\": ${DOCKER_PORT},
}
EOF"
sudo chown $(whoami):$(whoami) "${CONFIG_FILE}"  # Ensure user can read config file

# Step 6.5: Verify Outline VPN container is working (ensure container is rewritten)
echo "Verifying Outline VPN container functionality..."
# Create FILES_DIR early to ensure log file can be written
echo "Creating output directory ${FILES_DIR}..."
mkdir -p "${FILES_DIR}"
if [ ! -d "${FILES_DIR}" ] || [ ! -w "${FILES_DIR}" ]; then
  echo "Error: Directory ${FILES_DIR} does not exist or is not writable."
  exit 1
fi

# Check for port conflicts before starting container
echo "Checking for port conflicts on ${API_PORT}..."
if sudo netstat -tuln | grep ":${API_PORT}" > /dev/null; then
  echo "Error: Port ${API_PORT} is already in use by another process."
  sudo netstat -tulnp | grep ":${API_PORT}"
  exit 1
fi
echo "Port ${API_PORT} is free."

# Forcefully remove any existing container to ensure a fresh instance
if sudo docker ps -a --filter "name=^${OUTLINE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
  echo "Removing existing container ${OUTLINE_CONTAINER_NAME} to rewrite with fresh instance..."
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}" || {
    echo "Error: Failed to remove existing container ${OUTLINE_CONTAINER_NAME}."
    exit 1
  }
else
  echo "No existing ${OUTLINE_CONTAINER_NAME} container found. Proceeding with fresh container."
fi

# Run a new Outline container in detached mode
echo "Starting new Outline VPN container..."
sudo docker run -d --name "${OUTLINE_CONTAINER_NAME}" \
  -p "${DOCKER_PORT}:${DOCKER_PORT}" \
  -p "${API_PORT}:${API_PORT}" \
  -v "${CONFIG_FILE}:/opt/outline/shadowbox_config.json" \
  "${OUTLINE_IMAGE}" || {
  echo "Error: Failed to start Outline container."
  exit 1
}

# Wait for the container to start (up to 60 seconds to account for slow startups)
echo "Waiting for Outline container to start..."
for i in {1..60}; do
  if sudo docker ps --filter "name=^${OUTLINE_CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
    echo "Outline container is running."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "Error: Outline container failed to start within 60 seconds."
    sudo docker logs "${OUTLINE_CONTAINER_NAME}"
    sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
    exit 1
  fi
  sleep 1
done

# Check container logs for errors
echo "Checking container logs for errors..."
sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}"
if grep -i "error" "${LOG_FILE}"; then
  echo "Error: Errors found in container logs. Full logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
echo "No errors found in logs."

# Verify API port is listening
echo "Verifying API port ${API_PORT} is listening..."
if ! sudo netstat -tuln | grep ":${API_PORT}" > /dev/null; then
  echo "Error: API port ${API_PORT} is not listening."
  echo "Container logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
echo "API port ${API_PORT} is listening."

# Test API accessibility (focus on http, add delay and verbose output)
echo "Testing Outline API accessibility..."
# Wait briefly to ensure API is fully initialized
sleep 5
# Test HTTP with verbose output for debugging
echo "Testing HTTP API..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${API_PORT}" || echo "curl_failed")
if [ "$HTTP_STATUS" = "curl_failed" ]; then
  echo "Error: curl command failed for http://localhost:${API_PORT}"
  curl -v "http://localhost:${API_PORT}" > "${FILES_DIR}/curl_http_output.txt" 2>&1
  echo "curl output saved to ${FILES_DIR}/curl_http_output.txt"
  cat "${FILES_DIR}/curl_http_output.txt"
  echo "Container logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  echo "Container will remain running for debugging. Inspect with 'sudo docker logs shadowbox' or 'sudo docker exec -it shadowbox /bin/sh'."
  exit 1
fi
if [ "$HTTP_STATUS" != "200" ]; then
  echo "Error: Outline API returned non-200 status on port ${API_PORT} (HTTP: $HTTP_STATUS)."
  curl -v "http://localhost:${API_PORT}" > "${FILES_DIR}/curl_http_output.txt" 2>&1
  echo "curl output saved to ${FILES_DIR}/curl_http_output.txt"
  cat "${FILES_DIR}/curl_http_output.txt"
  echo "Container logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  echo "Container will remain running for debugging. Inspect with 'sudo docker logs shadowbox' or 'sudo docker exec -it shadowbox /bin/sh'."
  exit 1
fi
echo "Outline API is accessible (HTTP: $HTTP_STATUS)."

# Additional VPN-specific check (verify management API returns valid response)
echo "Verifying Outline VPN management API..."
API_RESPONSE=$(curl -s "http://localhost:${API_PORT}/access-keys" || echo "curl_failed")
if [ "$API_RESPONSE" = "curl_failed" ]; then
  echo "Error: curl command failed for http://localhost:${API_PORT}/access-keys"
  curl -v "http://localhost:${API_PORT}/access-keys" > "${FILES_DIR}/curl_access_keys_output.txt" 2>&1
  echo "curl output saved to ${FILES_DIR}/curl_access_keys_output.txt"
  cat "${FILES_DIR}/curl_access_keys_output.txt"
  echo "Container logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  echo "Container will remain running for debugging. Inspect with 'sudo docker logs shadowbox' or 'sudo docker exec -it shadowbox /bin/sh'."
  exit 1
fi
if ! echo "${API_RESPONSE}" | grep -q "accessKeys"; then
  echo "Error: Outline VPN management API did not return expected response."
  echo "API Response: ${API_RESPONSE}"
  echo "Container logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  echo "Container will remain running for debugging. Inspect with 'sudo docker logs shadowbox' or 'sudo docker exec -it shadowbox /bin/sh'."
  exit 1
fi
echo "Outline VPN management API is functional."

# Stop and remove the test container
echo "Stopping and removing test container..."
sudo docker stop "${OUTLINE_CONTAINER_NAME}" || {
  echo "Error: Failed to stop Outline container."
  exit 1
}
sudo docker rm "${OUTLINE_CONTAINER_NAME}" || {
  echo "Error: Failed to remove Outline container."
  exit 1
}
echo "Outline VPN verification successful."

# Clean up log file
echo "Cleaning up log file..."
rm -f "${LOG_FILE}"

# Step 7: Export Docker image
echo "Exporting Docker image to tar file..."
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
