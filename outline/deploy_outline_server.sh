#!/bin/bash

# Script to deploy Outline Server on a second Ubuntu server with limited internet
# Run on the second server after transferring the bundle from setup_outline_server.sh
# Expects outline_docker_bundle.zip in the current directory or downloads it
# Deploys Docker, loads the Outline image, sets up configuration and certificates, and runs the container
# Verifies the container is running and the API is accessible

# Exit on error
set -e

# Store original directory
ORIGINAL_DIR="$(pwd)"

# Variables
ZIP_BUNDLE="outline_docker_bundle.zip"
DOWNLOAD_URL="http://github.com/HiradNikoo/bash-scripts/releases/latest/download/outline_docker_bundle.zip"
FILES_DIR="${ORIGINAL_DIR}/files"
CONFIG_DIR="/opt/outline/config"
PERSISTED_STATE_DIR="/root/shadowbox/persisted-state"
CERT_DIR="${PERSISTED_STATE_DIR}"
CONFIG_FILE="config/shadowbox_config.json"  # Relative to FILES_DIR
CERT_FILE="persisted-state/shadowbox.crt"  # Directly in FILES_DIR
KEY_FILE="persisted-state/shadowbox.key"   # Directly in FILES_DIR
ACCESS_FILE="access.txt"                   # Directly in FILES_DIR
DOCKER_OFFLINE_TAR="docker_offline.tar.gz"
OUTLINE_IMAGE_TAR="outline_server_image.tar"
OUTLINE_IMAGE="quay.io/outline/shadowbox:stable"
OUTLINE_CONTAINER_NAME="shadowbox"
DOCKER_PORT="8080"
API_PORT="8081"
LOG_FILE="${ORIGINAL_DIR}/deploy_shadowbox_logs.txt"
UBUNTU_CODENAME=$(lsb_release -cs)
ARCH=$(dpkg --print-architecture)

# Step 0: Clean up residual files and folders
# List of residual files and folders to check
RESIDUAL_FILES=("deploy_outline_server.sh" "outline_docker_bundle.zip")
RESIDUAL_FOLDERS=("files")

# Function to prompt user for confirmation
prompt_for_deletion() {
  local item="$1"
  read -p "Found residual item: $item. Do you want to delete it? (y/N): " response
  case "$response" in
    [yY][eE][sS]|[yY])
      return 0  # User approved deletion
      ;;
    *)
      return 1  # User declined deletion
      ;;
  esac
}

# Flag to track if any residuals are found
residuals_found=false

# Check for residual files
for file in "${RESIDUAL_FILES[@]}"; do
  if [ -f "$file" ]; then
    residuals_found=true
    echo "Found residual file: $file"
    if prompt_for_deletion "$file"; then
      echo "Deleting $file..."
      rm -f "$file" || {
        echo "Error: Failed to delete $file"
        exit 1
      }
    else
      echo "User declined to delete $file. Exiting to prevent conflicts."
      exit 1
    fi
  fi
done

# Check for residual folders
for folder in "${RESIDUAL_FOLDERS[@]}"; do
  if [ -d "$folder" ]; then
    residuals_found=true
    echo "Found residual folder: $folder"
    if prompt_for_deletion "$folder"; then
      echo "Deleting $folder..."
      rm -rf "$folder" || {
        echo "Error: Failed to delete $folder"
        exit 1
      }
    else
      echo "User declined to delete $folder. Exiting to prevent conflicts."
      exit 1
    fi
  fi
done

# If no residuals were found, proceed
if [ "$residuals_found" = false ]; then
  echo "No residual files or folders found. Proceeding with clean deployment."
fi

echo "Clean-up complete. Ready to proceed with Outline VPN deployment."

# Step 1: Install prerequisites
echo "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip tar net-tools openssl jq

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
ls -laR "${FILES_DIR}"
echo "=============================================================="

# Verify required files
for file in "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}" "${DOCKER_OFFLINE_TAR}" "${OUTLINE_IMAGE_TAR}"; do
  if [ ! -f "${FILES_DIR}/${file}" ]; then
    echo "Error: Required file ${file} not found in ${FILES_DIR}."
    exit 1
  fi
  echo "Confirmed ${FILES_DIR}/${file} exists."
done
# Check for optional private key
if [ -f "${FILES_DIR}/${KEY_FILE}" ]; then
  echo "Confirmed ${FILES_DIR}/${KEY_FILE} exists."
fi

# Step 4: Check if Docker is installed, install if not
echo "Checking for Docker installation..."
if ! command -v docker &> /dev/null; then
  echo "Docker not found, installing from offline packages..."
  cd "${FILES_DIR}" || {
    echo "Error: Failed to change to ${FILES_DIR}."
    exit 1
  }
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
  cd "${ORIGINAL_DIR}" || {
    echo "Error: Failed to return to original directory."
    exit 1
  }
else
  echo "Docker is already installed."
fi

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
sudo chown "$(whoami):$(whoami)" "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"
sudo chmod 700 "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"

# Step 7: Move configuration and certificate files
echo "Moving configuration and certificate files..."

# Backup existing shadowbox_config.json if it exists
[ -f "${CONFIG_DIR}/shadowbox_config.json" ] && sudo cp "${CONFIG_DIR}/shadowbox_config.json" "${CONFIG_DIR}/shadowbox_config.json.bak"

sudo mv -f "${FILES_DIR}/${CONFIG_FILE}" "${CONFIG_DIR}/shadowbox_config.json" || {
  echo "Error: Failed to move configuration file."
  exit 1
}
sudo mv -f "${FILES_DIR}/${CERT_FILE}" "${CERT_DIR}/shadowbox.crt" || {
  echo "Error: Failed to move certificate file."
  exit 1
}
if [ -f "${FILES_DIR}/${KEY_FILE}" ]; then
  sudo mv -f "${FILES_DIR}/${KEY_FILE}" "${CERT_DIR}/shadowbox.key" || {
    echo "Error: Failed to move private key file."
    exit 1
  }
fi

sudo chown "$(whoami):$(whoami)" "${CONFIG_DIR}/shadowbox_config.json" "${CERT_DIR}/shadowbox.crt" "${FILES_DIR}/access.txt"
[ -f "${CERT_DIR}/shadowbox.key" ] && sudo chown "$(whoami):$(whoami)" "${CERT_DIR}/shadowbox.key"
sudo chmod 600 "${CONFIG_DIR}/shadowbox_config.json" "${CERT_DIR}/shadowbox.crt" "${FILES_DIR}/access.txt"
[ -f "${CERT_DIR}/shadowbox.key" ] && sudo chmod 600 "${CERT_DIR}/shadowbox.key"


# Step 8: Update configuration with server IP
echo "Updating configuration with server IP..."
SERVER_IP=$(ip addr show $(ip route | awk '/default/ {print $5}') | grep "inet" | head -n 1 | awk '/inet/ {print $2}' | cut -d'/' -f1)
if [ -z "${SERVER_IP}" ]; then
  echo "Error: Could not determine server IP address."
  exit 1
fi
echo "Using SERVER_IP: ${SERVER_IP}"
if ! jq . "${CONFIG_DIR}/shadowbox_config.json" >/dev/null 2>&1; then
  echo "Error: ${CONFIG_DIR}/shadowbox_config.json is not valid JSON."
  exit 1
fi
jq --arg ip "$SERVER_IP" --arg port "$API_PORT" '.apiUrl = "https://" + $ip + ":" + $port' "${CONFIG_DIR}/shadowbox_config.json" > "${CONFIG_DIR}/shadowbox_config.json.tmp" && mv "${CONFIG_DIR}/shadowbox_config.json.tmp" "${CONFIG_DIR}/shadowbox_config.json" || {
  echo "Error: Failed to update ${CONFIG_DIR}/shadowbox_config.json with server IP."
  exit 1
}


# Step 9: Check for existing container and stop/remove if found

# Function to prompt user for confirmation
prompt_for_container_deletion() {
  read -p "Existing container '${OUTLINE_CONTAINER_NAME}' found. Delete it? (y/N): " response
  case "$response" in
    [yY][eE][sS]|[yY])
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

echo "Checking for existing Outline Server container..."
if sudo docker ps -a --filter "name=^${OUTLINE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
  echo "Existing container found with name ${OUTLINE_CONTAINER_NAME}."
  if ! prompt_for_container_deletion; then
    echo "User declined to delete existing container. Exiting."
    exit 0
  fi
  if sudo docker ps --filter "name=^${OUTLINE_CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
    echo "Container is running. Stopping it..."
    sudo docker stop "${OUTLINE_CONTAINER_NAME}" || {
      echo "Error: Failed to stop existing container."
      exit 1
    }
  fi
  echo "Removing container..."
  sudo docker rm "${OUTLINE_CONTAINER_NAME}" || {
    echo "Error: Failed to remove existing container."
    exit 1
  }
fi

# Step 10: Check for port conflicts
echo "Checking for port conflicts..."
for port in "${DOCKER_PORT}" "${API_PORT}"; do
  if sudo netstat -tuln | grep ":${port}" > /dev/null; then
    echo "Error: Port ${port} is already in use."
    sudo netstat -tulnp | grep ":${port}" > "${FILES_DIR}/port_conflict.txt" 2>&1
    cat "${FILES_DIR}/port_conflict.txt"
    exit 1
  fi
done


# Step 11: Run Outline Server container
echo "Starting Outline Server container..."
CERT_ENV=""
if [ -f "${CERT_DIR}/shadowbox.key" ]; then
  CERT_ENV="-e SB_PRIVATE_KEY_FILE=/opt/outline/shadowbox.key -v ${CERT_DIR}/shadowbox.key:/opt/outline/shadowbox.key"
fi
sudo docker run -d --name "${OUTLINE_CONTAINER_NAME}" --restart=always \
  -p "${DOCKER_PORT}:${DOCKER_PORT}" \
  -p "${API_PORT}:${API_PORT}" \
  -v "${CONFIG_DIR}/shadowbox_config.json:/opt/outline/shadowbox_config.json" \
  -v "${PERSISTED_STATE_DIR}:/root/shadowbox/persisted-state" \
  -v "${CERT_DIR}/shadowbox.crt:/opt/outline/shadowbox.crt" \
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
    sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}"
    cat "${LOG_FILE}"
    sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
    exit 1
  fi
  sleep 1
done

# Step 13: Check container logs
echo "Checking container logs for errors..."
sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}" 2>&1
if sudo docker inspect "${OUTLINE_CONTAINER_NAME}" --format '{{.State.ExitCode}}' | grep -q -v "0"; then
  echo "Error: Container exited with non-zero status. Full logs saved to ${LOG_FILE}"
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
API_PREFIX=$(grep "apiUrl" "${FILES_DIR}/access.txt" | sed -n 's|.*https://[^/]*:[0-9]*/\([^"]*\)/access-keys.*|\1|p' || echo "")
if [ -z "${API_PREFIX}" ]; then
  echo "Warning: Could not extract API_PREFIX from ${FILES_DIR}/access.txt. Assuming empty prefix."
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

echo "Configuration and access details:"
echo "Server IP: ${SERVER_IP}"
cat "${FILES_DIR}/config/shadowbox_config.json"

# Step 17: Clean up
echo "Cleaning up temporary files..."
rm -f "${FILES_DIR}/${OUTLINE_IMAGE_TAR}" "${FILES_DIR}/${DOCKER_OFFLINE_TAR}" "${FILES_DIR}"/*.deb "${ZIP_BUNDLE}"
rm -rf "${FILES_DIR}/config"  # Remove config directory
rm -f "${LOG_FILE}"

echo "Outline Server deployed successfully."
echo "Access the API at https://${SERVER_IP}:${API_PORT}/${API_PREFIX}"
echo "Use ${FILES_DIR}/access.txt to connect Outline Manager to the server."
echo "To inspect the running container, use: sudo docker logs ${OUTLINE_CONTAINER_NAME}"
echo "To access the container shell, use: sudo docker exec -it ${OUTLINE_CONTAINER_NAME} /bin/sh"
