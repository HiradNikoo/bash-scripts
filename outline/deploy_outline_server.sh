#!/bin/bash

# Script to deploy Outline Server on a second Ubuntu server with limited internet
# Run on the second server after transferring the bundle from setup_outline_server.sh
# Expects outline_docker_bundle.zip in the current directory or downloads it
# Deploys Docker, loads the Outline image, sets up configuration and certificates, and runs the container
# Verifies the container is running and the API is accessible

# Exit on error
set -e

# Variables
ZIP_BUNDLE="outline_docker_bundle.zip"
# Update DOWNLOAD_URL to your preferred location or comment out if transferring manually
DOWNLOAD_URL="http://github.com/HiradNikoo/bash-scripts/releases/latest/download/outline_docker_bundle.zip"
FILES_DIR="$(pwd)/files"
CONFIG_DIR="/opt/outline/config"
PERSISTED_STATE_DIR="/root/shadowbox/persisted-state"
CERT_DIR="${PERSISTED_STATE_DIR}"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
CERT_FILE="${CERT_DIR}/shadowbox.crt"
KEY_FILE="${CERT_DIR}/shadowbox.key"
ACCESS_FILE="${FILES_DIR}/access.txt"
DOCKER_OFFLINE_TAR="docker_offline.tar.gz"
OUTLINE_IMAGE_TAR="outline_server_image.tar"
OUTLINE_IMAGE="quay.io/outline/shadowbox:stable"
OUTLINE_CONTAINER_NAME="shadowbox"
DOCKER_PORT="8080"
API_PORT="8081"
LOG_FILE="$(pwd)/deploy_shadowbox_logs.txt"
UBUNTU_CODENAME=$(lsb_release -cs)
ARCH=$(dpkg --print-architecture)

# Step 1: Install prerequisites
echo "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip tar net-tools openssl

# Step 2: Download or verify the bundle
if [ ! -f "${ZIP_BUNDLE}" ]; then
  echo "Bundle ${ZIP_BUNDLE} not found in current directory."
  if [ -n "${DOWNLOAD_URL}" ]; then
    echo "Downloading the bundle from ${DOWNLOAD_URL}..."
    wget -O "${ZIP_BUNDLE}" "${DOWNLOAD_URL}" || {
      echo "Error: Failed to download the bundle."
      exit 1
    }
  else
    echo "Error: No bundle found and no DOWNLOAD_URL specified. Please transfer ${ZIP_BUNDLE} to the current directory."
    exit 1
  fi
else
  echo "Bundle ${ZIP_BUNDLE} found in current directory."
fi

# Step 3: Unzip the bundle
echo "Unzipping the bundle..."
mkdir -p "${FILES_DIR}"
unzip -o "${ZIP_BUNDLE}" -d "${FILES_DIR}" || {
  echo "Error: Failed to unzip ${ZIP_BUNDLE}."
  exit 1
}
echo "=================== Contents of ${FILES_DIR} =================="
ls -la "${FILES_DIR}"
echo "=============================================================="

# Verify required files
for file in "${OUTLINE_IMAGE_TAR}" "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}" "${DOCKER_OFFLINE_TAR}"; do
  if [ ! -f "${FILES_DIR}/${file}" ]; then
    echo "Error: Required file ${file} not found in ${FILES_DIR}."
    exit 1
  fi
  echo "Confirmed ${FILES_DIR}/${file} exists."
done
# Check for optional private key
if [ -f "${FILES_DIR}/shadowbox.key" ]; then
  echo "Confirmed ${FILES_DIR}/shadowbox.key exists."
fi

# Step 4: Check if Docker is installed, install if not
echo "Checking for Docker installation..."
if ! command -v docker &> /dev/null; then
  echo "Docker not found, installing from offline packages..."
  cd "${FILES_DIR}"
  tar -xzvf "${DOCKER_OFFLINE_TAR}" || {
    echo "Error: Failed to extract ${DOCKER_OFFLINE_TAR}."
    exit 1
  }
  sudo dpkg -i *.deb || {
    echo "Error: Failed to install Docker packages. Attempting to fix dependencies..."
    sudo apt-get install -f -y || {
      echo "Error: Failed to resolve dependencies."
      exit 1
    }
  }
  if ! sudo systemctl is-active --quiet docker; then
    echo "Starting Docker service..."
    sudo systemctl start docker || {
      echo "Error: Failed to start Docker service. Check 'systemctl status docker' for details."
      sudo systemctl status docker > "${FILES_DIR}/docker_service_status.txt" 2>&1
      cat "${FILES_DIR}/docker_service_status.txt"
      exit 1
    }
  fi
  sudo systemctl enable docker
  echo "Docker installed and running."
else
  echo "Docker is already installed."
fi
cd "$(pwd)"  # Return to original directory

# Step 5: Load Outline Server image
echo "Loading Outline Server image..."
sudo docker load -i "${FILES_DIR}/${OUTLINE_IMAGE_TAR}" || {
  echo "Error: Failed to load Outline Docker image from ${OUTLINE_IMAGE_TAR}."
  exit 1
}
if ! sudo docker images -q "${OUTLINE_IMAGE}" | grep -q .; then
  echo "Error: Docker image ${OUTLINE_IMAGE} not loaded."
  exit 1
fi
echo "Outline image loaded successfully."

# Step 6: Create configuration and certificate directories
echo "Creating configuration and certificate directories..."
sudo mkdir -p "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"
sudo chown $(whoami):$(whoami) "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"
sudo chmod 700 "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"

# Step 7: Move configuration and certificate files
echo "Moving configuration and certificate files..."
sudo mv "${FILES_DIR}/shadowbox_config.json" "${CONFIG_FILE}" || {
  echo "Error: Failed to move configuration file."
  exit 1
}
sudo mv "${FILES_DIR}/shadowbox.crt" "${CERT_FILE}" || {
  echo "Error: Failed to move certificate file."
  exit 1
}
if [ -f "${FILES_DIR}/shadowbox.key" ]; then
  sudo mv "${FILES_DIR}/shadowbox.key" "${KEY_FILE}" || {
    echo "Error: Failed to move private key file."
    exit 1
  }
fi
sudo mv "${FILES_DIR}/access.txt" "${ACCESS_FILE}" || {
  echo "Error: Failed to move access file."
  exit 1
}
sudo chown $(whoami):$(whoami) "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}"
[ -f "${KEY_FILE}" ] && sudo chown $(whoami):$(whoami) "${KEY_FILE}"
sudo chmod 600 "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}"
[ -f "${KEY_FILE}" ] && sudo chmod 600 "${KEY_FILE}"

# Step 8: Update configuration with server IP
echo "Updating configuration with server IP..."
SERVER_IP=$(ip addr show $(ip route | awk '/default/ {print $5}') | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)
if [ -z "${SERVER_IP}" ]; then
  echo "Error: Could not determine server IP address."
  exit 1
fi
echo "Using SERVER_IP: ${SERVER_IP}"
# Update apiUrl in the configuration file
sed -i "s|https://[^:]*:${API_PORT}|https://${SERVER_IP}:${API_PORT}|" "${CONFIG_FILE}" || {
  echo "Error: Failed to update ${CONFIG_FILE} with server IP."
  exit 1
}

# Step 9: Check for port conflicts
echo "Checking for port conflicts..."
for port in "${DOCKER_PORT}" "${API_PORT}"; do
  if sudo netstat -tuln | grep ":${port}" > /dev/null; then
    echo "Error: Port ${port} is already in use."
    sudo netstat -tulnp | grep ":${port}" > "${FILES_DIR}/port_conflict.txt" 2>&1
    cat "${FILES_DIR}/port_conflict.txt"
    exit 1
  fi
done

# Step 10: Check for existing container and remove if found
echo "Checking for existing Outline Server container..."
if sudo docker ps -a --filter "name=^${OUTLINE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
  echo "Existing container found with name ${OUTLINE_CONTAINER_NAME}. Removing it..."
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}" || {
    echo "Error: Failed to remove existing container."
    exit 1
  }
fi

# Step 11: Run Outline Server container
echo "Starting Outline Server container..."
CERT_ENV=""
[ -f "${KEY_FILE}" ] && CERT_ENV="-e SB_PRIVATE_KEY_FILE=/opt/outline/shadowbox.key -v ${KEY_FILE}:/opt/outline/shadowbox.key"
sudo docker run -d --name "${OUTLINE_CONTAINER_NAME}" --restart=always \
  -p "${DOCKER_PORT}:${DOCKER_PORT}" \
  -p "${API_PORT}:${API_PORT}" \
  -v "${CONFIG_FILE}:/opt/outline/shadowbox_config.json" \
  -v "${PERSISTED_STATE_DIR}:/root/shadowbox/persisted-state" \
  -v "${CERT_FILE}:/opt/outline/shadowbox.crt" \
  -e "SB_CERTIFICATE_FILE=/opt/outline/shadowbox.crt" \
  ${CERT_ENV} \
  "${OUTLINE_IMAGE}" || {
  echo "Error: Failed to start Outline container."
  sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
  cat "${LOG_FILE}"
  exit 1
}

# Step 12: Verify container is running
echo "Waiting for Outline container to start..."
for i in {1..60}; do
  if sudo docker ps --filter "name=^${OUTLINE_CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
    echo "Outline container is running."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "Error: Outline container failed to start within 60 seconds."
    sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
    cat "${LOG_FILE}"
    exit 1
  fi
  sleep 1
done

# Step 13: Check container logs
echo "Checking container logs for errors..."
sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
if grep -i "error" "${LOG_FILE}"; then
  echo "Error: Errors found in container logs. Full logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
echo "No errors found in logs."

# Step 14: Verify API port
echo "Verifying API port ${API_PORT} is listening..."
if ! sudo netstat -tuln | grep ":${API_PORT}" > /dev/null; then
  echo "Error: API port ${API_PORT} is not listening."
  sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
echo "API port ${API_PORT} is listening."

# Step 15: Test API accessibility
echo "Testing Outline API accessibility..."
sleep 10  # Wait for API initialization
# Extract API_PREFIX from access.txt
API_PREFIX=$(grep "apiUrl" "${ACCESS_FILE}" | sed -n 's|.*https://[^/]*:[0-9]*/\([^"]*\)/access-keys.*|\1|p')
if [ -z "${API_PREFIX}" ]; then
  echo "Warning: Could not extract API_PREFIX from ${ACCESS_FILE}. Assuming empty prefix."
  API_PREFIX=""
fi
for attempt in {1..3}; do
  echo "Testing HTTPS API (attempt ${attempt})..."
  HTTP_STATUS=$(curl -s --connect-timeout 5 --max-time 10 -k -o /dev/null -w "%{http_code}" "https://${SERVER_IP}:${API_PORT}/${API_PREFIX}/access-keys" || echo "curl_failed")
  if [ "$HTTP_STATUS" = "curl_failed" ]; then
    echo "Warning: curl command failed for https://${SERVER_IP}:${API_PORT}/${API_PREFIX}/access-keys (attempt ${attempt})"
    curl -v --connect-timeout 5 --max-time 10 -k "https://${SERVER_IP}:${API_PORT}/${API_PREFIX}/access-keys" > "${FILES_DIR}/curl_http_output.txt" 2>&1
    echo "curl output saved to ${FILES_DIR}/curl_http_output.txt"
    cat "${FILES_DIR}/curl_http_output.txt"
  elif [ "$HTTP_STATUS" != "200" ]; then
    echo "Warning: Outline API returned non-200 status on port ${API_PORT} (HTTP: $HTTP_STATUS, attempt ${attempt})."
    curl -v --connect-timeout 5 --max-time 10 -k "https://${SERVER_IP}:${API_PORT}/${API_PREFIX}/access-keys" > "${FILES_DIR}/curl_http_output.txt" 2>&1
    echo "curl output saved to ${FILES_DIR}/curl_http_output.txt"
    cat "${FILES_DIR}/curl_http_output.txt"
  else
    echo "Outline API is accessible (HTTP: $HTTP_STATUS)."
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "Error: Outline API failed after 3 attempts."
    sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
    cat "${LOG_FILE}"
    sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
    exit 1
  fi
  sleep 5
done

# Step 16: Verify management API
echo "Verifying Outline VPN management API..."
API_RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -k "https://${SERVER_IP}:${API_PORT}/${API_PREFIX}/access-keys" || echo "curl_failed")
if [ "$API_RESPONSE" = "curl_failed" ]; then
  echo "Error: curl command failed for https://${SERVER_IP}:${API_PORT}/${API_PREFIX}/access-keys"
  curl -v --connect-timeout 5 --max-time 10 -k "https://${SERVER_IP}:${API_PORT}/${API_PREFIX}/access-keys" > "${FILES_DIR}/curl_access_keys_output.txt" 2>&1
  echo "curl output saved to ${FILES_DIR}/curl_access_keys_output.txt"
  cat "${FILES_DIR}/curl_access_keys_output.txt"
  sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
if ! echo "${API_RESPONSE}" | grep -q "accessKeys"; then
  echo "Error: Outline VPN management API did not return expected response."
  echo "API Response: ${API_RESPONSE}"
  sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
echo "Outline VPN management API is functional."

# Step 17: Clean up
echo "Cleaning up temporary files..."
rm -f "${FILES_DIR}/${OUTLINE_IMAGE_TAR}" "${FILES_DIR}/${DOCKER_OFFLINE_TAR}" "${FILES_DIR}"/*.deb "${ZIP_BUNDLE}"
rm -f "${LOG_FILE}"

echo "Outline Server deployed successfully."
echo "Access the API at https://${SERVER_IP}:${API_PORT}/${API_PREFIX}"
echo "Use ${ACCESS_FILE} to connect Outline Manager to the server."
echo "To inspect the running container, use: sudo docker logs ${OUTLINE_CONTAINER_NAME}"
echo "To access the container shell, use: sudo docker exec -it ${OUTLINE_CONTAINER_NAME} /bin/sh"
