#!/bin/bash

# Script to set up Outline Server and Docker offline installer, then zip them
# Run on the first Ubuntu server with internet access
# Creates a 'files' directory in the current working directory for output
# Verifies Outline VPN container is running and functional before exporting image
# Ensures resources are cleaned up on rerun to avoid conflicts
# Handles port conflicts and logs detailed errors
# Generates self-signed certificate and certSha256 using Shadowbox

# Exit on error
set -e

# Variables
FILES_DIR="$(pwd)/files"  # Use absolute path for FILES_DIR
CONFIG_DIR="${FILES_DIR}/config"
PERSISTED_STATE_DIR="${FILES_DIR}/persisted-state"
ZIP_OUTPUT="${FILES_DIR}/outline_docker_bundle.zip"
DOCKER_PORT="8080"
API_PORT="8081"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
CERT_DIR="${PERSISTED_STATE_DIR}/outline-ss-server"
CERT_FILE="${CERT_DIR}/shadowbox.crt"
ACCESS_FILE="${FILES_DIR}/access.txt"
DOCKER_OFFLINE_DIR="/tmp/docker_offline"
DOCKER_OFFLINE_TAR="docker_offline.tar.gz"
OUTLINE_IMAGE="quay.io/outline/shadowbox:stable"
OUTLINE_CONTAINER_NAME="shadowbox"
TEMP_CONTAINER_NAME="shadowbox_temp"
UBUNTU_CODENAME=$(lsb_release -cs)
ARCH=$(dpkg --print-architecture)
OUTLINE_IMAGE_TAR="${FILES_DIR}/outline_server_image.tar"
LOG_FILE="${FILES_DIR}/shadowbox_logs.txt"
CLEANUP_LOG="${FILES_DIR}/cleanup_log.txt"

# Function to log messages
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "${CLEANUP_LOG}"
}

# Function to check and free ports
check_ports() {
  local ports=("$@")
  for port in "${ports[@]}"; do
    if sudo netstat -tuln | grep -q ":${port}"; then
      log_message "Error: Port ${port} is already in use."
      sudo netstat -tulnp | grep ":${port}" >> "${CLEANUP_LOG}"
      exit 1
    fi
  done
  log_message "Ports ${ports[*]} are free."
}

# Function to remove Docker container if it exists
remove_container() {
  local container_name="$1"
  if sudo docker ps -a --filter "name=^${container_name}$" --format '{{.Names}}' | grep -q "${container_name}"; then
    log_message "Removing existing container ${container_name}..."
    sudo docker rm -f "${container_name}" || {
      log_message "Error: Failed to remove container ${container_name}."
      exit 1
    }
  else
    log_message "No existing ${container_name} container found."
  fi
}

# Step 1: Initial cleanup to avoid conflicts
log_message "Starting cleanup of existing resources..."
mkdir -p "${FILES_DIR}"
echo > "${CLEANUP_LOG}"  # Initialize cleanup log

# Remove existing containers
remove_container "${OUTLINE_CONTAINER_NAME}"
remove_container "${TEMP_CONTAINER_NAME}"

# Clean up existing files and directories
log_message "Cleaning up existing files and directories..."
if [ -d "${FILES_DIR}" ]; then
  log_message "Removing existing ${FILES_DIR} contents..."
  rm -rf "${FILES_DIR}"/* || {
    log_message "Error: Failed to clean ${FILES_DIR}."
    exit 1
  }
fi
mkdir -p "${FILES_DIR}" "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}" "${CERT_DIR}"
sudo chown -R $(whoami):$(whoami) "${FILES_DIR}"
sudo chmod -R 700 "${FILES_DIR}"
log_message "Output directories recreated: ${FILES_DIR}, ${CONFIG_DIR}, ${PERSISTED_STATE_DIR}, ${CERT_DIR}"

# Check for port conflicts early
log_message "Checking for port conflicts..."
check_ports "${DOCKER_PORT}" "${API_PORT}"

# Step 2: Install prerequisites
log_message "Installing prerequisites..."
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip wget apt-transport-https gnupg lsb-release zip net-tools openssl

# Step 3: Set up Docker repository
log_message "Setting up Docker repository..."
sudo install -m 0755 -d /etc/apt/keyrings
[ -f /etc/apt/keyrings/docker.gpg ] && sudo rm /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Step 4: Install Docker
log_message "Installing Docker..."
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
if ! sudo systemctl is-active --quiet docker; then
  log_message "Starting Docker service..."
  sudo systemctl start docker || {
    log_message "Error: Failed to start Docker service."
    exit 1
  }
fi
sudo systemctl enable docker

# Step 5: Pull Outline Server image
log_message "Pulling Outline Server image..."
sudo docker pull "${OUTLINE_IMAGE}"

# Step 6: Generate sample configuration, certificate, and certSha256
log_message "Generating configuration and certificate..."
sudo chown $(whoami):$(whoami) "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}" "${CERT_DIR}"
sudo chmod -R 700 "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}" "${CERT_DIR}"

# Verify write access
sudo -u "$(whoami)" touch "${CONFIG_DIR}/test_write" || {
  log_message "Error: User $(whoami) cannot write to ${CONFIG_DIR}"
  exit 1
}
rm -f "${CONFIG_DIR}/test_write"

# Get public IP
PUBLIC_IP=$(curl -s https://api.ipify.org || echo "unknown")
if [ "$PUBLIC_IP" = "unknown" ]; then
  log_message "Warning: Could not determine public IP. Using localhost."
  PUBLIC_IP="localhost"
fi

# Generate a random API prefix
API_PREFIX=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

# Run temporary Outline container
log_message "Running temporary Outline container..."
sudo docker run -d --name "${TEMP_CONTAINER_NAME}" \
  -p "${DOCKER_PORT}:${DOCKER_PORT}" \
  -p "${API_PORT}:${API_PORT}" \
  -v "${CONFIG_DIR}:/opt/outline/config" \
  -v "${PERSISTED_STATE_DIR}:/root/shadowbox/persisted-state" \
  -e "SB_API_PORT=${API_PORT}" \
  -e "SB_PUBLIC_IP=${PUBLIC_IP}" \
  -e "SB_DEFAULT_SERVER_NAME=OutlineServer" \
  -e "SB_API_PREFIX=${API_PREFIX}" \
  "${OUTLINE_IMAGE}" || {
  log_message "Error: Failed to start temporary Outline container."
  exit 1
}

# Wait for container to initialize
log_message "Waiting for temporary container to initialize..."
for i in {1..60}; do
  if sudo docker ps --filter "name=^${TEMP_CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "${TEMP_CONTAINER_NAME}"; then
    log_message "Temporary container is running."
    break
  fi
  if [ "$i" -eq 60 ]; then
    log_message "Error: Temporary container failed to start within 60 seconds."
    sudo docker logs "${TEMP_CONTAINER_NAME}" >> "${CLEANUP_LOG}"
    remove_container "${TEMP_CONTAINER_NAME}"
    exit 1
  fi
  sleep 1
done

# Wait for config file
log_message "Waiting for configuration file..."
for i in {1..30}; do
  if [ -f "${CONFIG_FILE}" ]; then
    log_message "Configuration file generated: ${CONFIG_FILE}"
    break
  fi
  if [ "$i" -eq 30 ]; then
    log_message "Warning: Configuration file not generated. Creating default..."
    cat << EOF > "${CONFIG_FILE}"
{
  "apiUrl": "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}",
  "certSha256": "placeholder-cert-sha256",
  "hostname": "$(hostname)",
  "port": ${API_PORT}
}
EOF
    log_message "Default configuration created."
    break
  fi
  sleep 1
done

# Extract certificate
log_message "Extracting certificate..."
for i in {1..30}; do
  if [ -f "${CERT_DIR}/config.yml" ]; then
    if [ -f "${CERT_FILE}" ]; then
      log_message "Certificate found at ${CERT_FILE}"
      break
    elif grep -q "cert:" "${CERT_DIR}/config.yml"; then
      CERT_CONTENT=$(awk '/cert:/{flag=1; next} /key:/{flag=0} flag' "${CERT_DIR}/config.yml" | sed 's/^[ \t]*//' | tr -d '\n')
      echo "${CERT_CONTENT}" | base64 -d > "${CERT_FILE}" 2>/dev/null || echo "${CERT_CONTENT}" > "${CERT_FILE}"
      if [ -s "${CERT_FILE}" ]; then
        log_message "Certificate extracted to ${CERT_FILE}"
        break
      fi
    fi
  fi
  if [ "$i" -eq 30 ]; then
    log_message "Error: Certificate file not found in ${CERT_DIR}."
    sudo docker logs "${TEMP_CONTAINER_NAME}" >> "${CLEANUP_LOG}"
    remove_container "${TEMP_CONTAINER_NAME}"
    exit 1
  fi
  sleep 1
done

# Compute certSha256
log_message "Computing certSha256..."
CERT_SHA256=$(openssl x509 -in "${CERT_FILE}" -outform der | sha256sum | awk '{print $1}' || echo "error")
if [ "$CERT_SHA256" = "error" ] || [ -z "$CERT_SHA256" ]; then
  log_message "Error: Failed to compute certSha256."
  cat "${CERT_FILE}" >> "${CLEANUP_LOG}"
  remove_container "${TEMP_CONTAINER_NAME}"
  exit 1
fi
log_message "Computed certSha256: ${CERT_SHA256}"

# Update configuration
if grep -q "placeholder-cert-sha256" "${CONFIG_FILE}"; then
  log_message "Updating configuration with certSha256..."
  sed -i "s/\"certSha256\": \"placeholder-cert-sha256\"/\"certSha256\": \"${CERT_SHA256}\"/" "${CONFIG_FILE}" || {
    log_message "Error: Failed to update ${CONFIG_FILE}."
    exit 1
  }
fi

# Validate config
log_message "Validating configuration file..."
if ! grep -q "apiUrl" "${CONFIG_FILE}" || ! grep -q "certSha256" "${CONFIG_FILE}"; then
  log_message "Error: Configuration file missing required fields."
  cat "${CONFIG_FILE}" >> "${CLEANUP_LOG}"
  remove_container "${TEMP_CONTAINER_NAME}"
  exit 1
fi

# Save access information
log_message "Saving access information..."
cat << EOF > "${ACCESS_FILE}"
{
  "apiUrl": "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}",
  "certSha256": "${CERT_SHA256}"
}
EOF
sudo chown $(whoami):$(whoami) "${ACCESS_FILE}"
sudo chmod 600 "${ACCESS_FILE}"
log_message "Access information saved to ${ACCESS_FILE}"

# Secure permissions
sudo chmod -R 600 "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}"
sudo chown -R $(whoami):$(whoami) "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"

# Remove temporary container
log_message "Removing temporary container..."
remove_container "${TEMP_CONTAINER_NAME}"

# Step 7: Verify Outline VPN container
log_message "Starting Outline VPN container verification..."
sudo docker run -d --name "${OUTLINE_CONTAINER_NAME}" \
  -p "${DOCKER_PORT}:${DOCKER_PORT}" \
  -p "${API_PORT}:${API_PORT}" \
  -v "${CONFIG_FILE}:/opt/outline/shadowbox_config.json" \
  -v "${PERSISTED_STATE_DIR}:/root/shadowbox/persisted-state" \
  -v "${CERT_FILE}:/opt/outline/shadowbox.crt" \
  -e "SB_CERTIFICATE_FILE=/opt/outline/shadowbox.crt" \
  "${OUTLINE_IMAGE}" || {
  log_message "Error: Failed to start Outline container."
  exit 1
}

# Wait for container
log_message "Waiting for Outline container..."
for i in {1..60}; do
  if sudo docker ps --filter "name=^${OUTLINE_CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
    log_message "Outline container is running."
    break
  fi
  if [ "$i" -eq 60 ]; then
    log_message "Error: Outline container failed to start."
    sudo docker logs "${OUTLINE_CONTAINER_NAME}" >> "${CLEANUP_LOG}"
    remove_container "${OUTLINE_CONTAINER_NAME}"
    exit 1
  fi
  sleep 1
done

# Check logs
log_message "Checking container logs..."
sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}"
if grep -i "error" "${LOG_FILE}"; then
  log_message "Error: Errors in container logs."
  cat "${LOG_FILE}" >> "${CLEANUP_LOG}"
  remove_container "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
log_message "No errors in logs."

# Verify API port
log_message "Verifying API port ${API_PORT}..."
if ! sudo netstat -tuln | grep -q ":${API_PORT}"; then
  log_message "Error: API port ${API_PORT} not listening."
  cat "${LOG_FILE}" >> "${CLEANUP_LOG}"
  remove_container "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
log_message "API port ${API_PORT} is listening."

# Test API
log_message "Testing Outline API..."
sleep 10
for attempt in {1..3}; do
  log_message "Testing API (attempt ${attempt})..."
  HTTP_STATUS=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w "%{http_code}" "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}" || echo "curl_failed")
  if [ "$HTTP_STATUS" = "curl_failed" ] || [ "$HTTP_STATUS" != "200" ]; then
    log_message "Warning: API test failed (HTTP: $HTTP_STATUS, attempt ${attempt})."
    curl -v --connect-timeout 5 --max-time 10 "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}" > "${FILES_DIR}/curl_http_output.txt" 2>&1
    cat "${FILES_DIR}/curl_http_output.txt" >> "${CLEANUP_LOG}"
  else
    log_message "Outline API is accessible (HTTP: $HTTP_STATUS)."
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    log_message "Error: Outline API failed after 3 attempts."
    cat "${LOG_FILE}" >> "${CLEANUP_LOG}"
    remove_container "${OUTLINE_CONTAINER_NAME}"
    exit 1
  fi
  sleep 5
done

# Verify management API
log_message "Verifying management API..."
API_RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys" || echo "curl_failed")
if [ "$API_RESPONSE" = "curl_failed" ] || ! echo "${API_RESPONSE}" | grep -q "accessKeys"; then
  log_message "Error: Management API failed."
  curl -v --connect-timeout 5 --max-time 10 "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys" > "${FILES_DIR}/curl_access_keys_output.txt" 2>&1
  cat "${FILES_DIR}/curl_access_keys_output.txt" >> "${CLEANUP_LOG}"
  cat "${LOG_FILE}" >> "${CLEANUP_LOG}"
  remove_container "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
log_message "Management API is functional."

# Remove test container
log_message "Removing test container..."
remove_container "${OUTLINE_CONTAINER_NAME}"
rm -f "${LOG_FILE}"

# Step 8: Export Docker image
log_message "Exporting Docker image..."
sudo docker save -o "${OUTLINE_IMAGE_TAR}" "${OUTLINE_IMAGE}"
sudo chown $(whoami):$(whoami) "${OUTLINE_IMAGE_TAR}"
log_message "Docker image exported to ${OUTLINE_IMAGE_TAR}"

# Step 9: Download Docker offline installer
log_message "Downloading Docker offline installer..."
mkdir -p "${DOCKER_OFFLINE_DIR}"
cd "${DOCKER_OFFLINE_DIR}"
BASE_URL="https://download.docker.com/linux/ubuntu/dists/${UBUNTU_CODENAME}/pool/stable/${ARCH}"
for pkg in "containerd.io" "docker-ce" "docker-ce-cli" "docker-buildx-plugin" "docker-compose-plugin"; do
  log_message "Fetching ${pkg}..."
  pkg_file=$(curl -s "${BASE_URL}/" | grep "${pkg}_" | awk -F'"' '{print $2}' | sort -V | tail -n 1)
  wget -q "${BASE_URL}/${pkg_file}" || {
    log_message "Error: Failed to download ${pkg_file}."
    exit 1
  }
done
tar -czvf "${DOCKER_OFFLINE_TAR}" *.deb
mv "${DOCKER_OFFLINE_TAR}" "${FILES_DIR}/"
sudo chown $(whoami):$(whoami) "${FILES_DIR}/${DOCKER_OFFLINE_TAR}"
cd /tmp
rm -rf "${DOCKER_OFFLINE_DIR}"
log_message "Docker offline installer created at ${FILES_DIR}/${DOCKER_OFFLINE_TAR}"

# Step 10: Zip files
log_message "Zipping files..."
cd "${FILES_DIR}"
zip -r "${ZIP_OUTPUT}" "$(basename ${OUTLINE_IMAGE_TAR})" "$(basename ${CONFIG_FILE})" "$(basename ${CERT_FILE})" "$(basename ${ACCESS_FILE})" "${DOCKER_OFFLINE_TAR}" || {
  log_message "Error: Failed to create zip file."
  exit 1
}
log_message "Zip file created: ${ZIP_OUTPUT}"

# Step 11: Clean up
log_message "Cleaning up temporary files..."
rm -f "${OUTLINE_IMAGE_TAR}" "${FILES_DIR}/${DOCKER_OFFLINE_TAR}"
log_message "Cleanup completed."

echo "Bundle created as ${ZIP_OUTPUT}"
echo "Transfer ${ZIP_OUTPUT} to https://bash.hiradnikoo.com/outline/files."
echo "Use ${ACCESS_FILE} to connect Outline Manager to the server."
echo "On the second server, run: wget -O bootstrap-deploy.sh https://bash.hiradnikoo.com/outline/bootstrap-deploy.sh && chmod +x bootstrap-deploy.sh && sudo ./bootstrap-deploy.sh"
