#!/bin/bash

# Script to set up Outline Server and Docker offline installer, then zip them
# Run on the first Ubuntu server with internet access
# Creates a 'files' directory in the current working directory for output
# Verifies Outline VPN container is running and functional before exporting image
# Ensures container is rewritten on rerun by removing existing container
# Handles port conflicts and logs detailed errors
# Generates self-signed certificate and certSha256 using Shadowbox or fallback

# Exit on error
set -e

# Variables
TEMP_CONTAINER_NAME="shadowbox_temp"
FILES_DIR="$(pwd)/files"  # Use absolute path for FILES_DIR
CONFIG_DIR="${FILES_DIR}/config"
PERSISTED_STATE_DIR="${FILES_DIR}/persisted-state"
ZIP_OUTPUT="${FILES_DIR}/outline_docker_bundle.zip"
DOCKER_PORT="8080"
API_PORT="8081"
CONFIG_FILE="${CONFIG_DIR}/shadowbox_config.json"
CERT_DIR="${PERSISTED_STATE_DIR}"
CERT_FILE="${CERT_DIR}/shadowbox.crt"
KEY_FILE="${CERT_DIR}/shadowbox.key"
ACCESS_FILE="${FILES_DIR}/access.txt"
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
sudo apt-get install -y ca-certificates curl unzip wget apt-transport-https gnupg lsb-release zip net-tools openssl

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

# Step 5: Create output directory
echo "Creating output directory ${FILES_DIR}..."
mkdir -p "${FILES_DIR}"
if [ ! -d "${FILES_DIR}" ] || [ ! -w "${FILES_DIR}" ]; then
  echo "Error: Directory ${FILES_DIR} does not exist or is not writable."
  exit 1
fi

# Step 6: Generate sample configuration, certificate, and certSha256
echo "Creating configuration and persisted-state directories..."
sudo mkdir -p "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"
sudo chown $(whoami):$(whoami) "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"
sudo chmod -R 777 "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"  # Temporary permissive permissions

# Verify write access
sudo -u "$(whoami)" touch "${CONFIG_DIR}/test_write" || {
  echo "Error: User $(whoami) cannot write to ${CONFIG_DIR}"
  exit 1
}
rm -f "${CONFIG_DIR}/test_write"

# Get public IP
PUBLIC_IP=$(curl -s https://api.ipify.org || echo "unknown")
if [ "$PUBLIC_IP" = "unknown" ]; then
  echo "Warning: Could not determine public IP. Please set SB_PUBLIC_IP manually."
  PUBLIC_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)
  if [ -z "$PUBLIC_IP" ]; then
    echo "Error: Could not determine local IP. Please set PUBLIC_IP manually."
    exit 1
  fi
fi
echo "Using PUBLIC_IP: ${PUBLIC_IP}"

# Generate a random API prefix
API_PREFIX=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
echo "Using API_PREFIX: ${API_PREFIX}"

# Trap to clean up temporary container on exit
cleanup() {
  if sudo docker ps -a --filter "name=^${TEMP_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${TEMP_CONTAINER_NAME}"; then
    echo "Cleaning up temporary container ${TEMP_CONTAINER_NAME}..."
    sudo docker rm -f "${TEMP_CONTAINER_NAME}" || echo "Warning: Failed to clean up temporary container."
  fi
}
trap cleanup EXIT

# Verify TEMP_CONTAINER_NAME is set
if [ -z "${TEMP_CONTAINER_NAME}" ]; then
  echo "Error: TEMP_CONTAINER_NAME is not set."
  exit 1
fi

# Verify Docker service is running
if ! sudo systemctl is-active --quiet docker; then
  echo "Error: Docker service is not running."
  sudo systemctl status docker > "${FILES_DIR}/docker_service_status.txt" 2>&1
  cat "${FILES_DIR}/docker_service_status.txt"
  exit 1
fi

# Verify Outline image exists
if ! sudo docker images -q "${OUTLINE_IMAGE}" | grep -q .; then
  echo "Error: Docker image ${OUTLINE_IMAGE} not found."
  echo "Attempting to pull image again..."
  sudo docker pull "${OUTLINE_IMAGE}" > "${FILES_DIR}/docker_pull_output.txt" 2>&1 || {
    echo "Error: Failed to pull ${OUTLINE_IMAGE}."
    cat "${FILES_DIR}/docker_pull_output.txt"
    exit 1
  }
  rm -f "${FILES_DIR}/docker_pull_output.txt"
fi

# Verify ports are free
for port in "${DOCKER_PORT}" "${API_PORT}"; do
  if sudo netstat -tuln | grep ":${port}" > /dev/null; then
    echo "Error: Port ${port} is already in use."
    sudo netstat -tulnp | grep ":${port}" > "${FILES_DIR}/port_conflict.txt" 2>&1
    cat "${FILES_DIR}/port_conflict.txt"
    exit 1
  fi
done

# Verify volume directories exist and are writable
for dir in "${CONFIG_DIR}" "${PERSISTED_STATE_DIR}"; do
  if [ ! -d "${dir}" ] || [ ! -w "${dir}" ]; then
    echo "Error: Directory ${dir} does not exist or is not writable."
    exit 1
  fi
done

# Remove existing temporary container if it exists
if sudo docker ps -a --filter "name=^${TEMP_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${TEMP_CONTAINER_NAME}"; then
  echo "Removing existing temporary container ${TEMP_CONTAINER_NAME}..."
  sudo docker rm -f "${TEMP_CONTAINER_NAME}" || {
    echo "Error: Failed to remove existing temporary container."
    exit 1
  }
else
  echo "No existing ${TEMP_CONTAINER_NAME} container found."
fi

# Remove existing temporary container if it exists
if sudo docker ps -a --filter "name=^${TEMP_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${TEMP_CONTAINER_NAME}"; then
  echo "Removing existing temporary container ${TEMP_CONTAINER_NAME}..."
  sudo docker rm -f "${TEMP_CONTAINER_NAME}" || {
    echo "Error: Failed to remove existing temporary container."
    sudo docker inspect "${TEMP_CONTAINER_NAME}" | grep -i "error"
    exit 1
  }
else
  echo "No existing ${TEMP_CONTAINER_NAME} container found."
fi


# Run Outline container temporarily to generate initial config, certificate, and state
echo "Running temporary Outline container to initialize configuration and certificate..."
TEMP_CONTAINER_NAME="shadowbox_temp"
# Run Outline container temporarily to generate initial config, certificate, and state
echo "Running temporary Outline container to initialize configuration and certificate..."
sudo docker run -d --name "${TEMP_CONTAINER_NAME}" \
  -p "${DOCKER_PORT}:${DOCKER_PORT}" \
  -p "${API_PORT}:${API_PORT}" \
  -v "${CONFIG_DIR}:/opt/outline/config" \
  -v "${PERSISTED_STATE_DIR}:/root/shadowbox/persisted-state" \
  -e "SB_API_PORT=${API_PORT}" \
  -e "SB_PUBLIC_IP=${PUBLIC_IP}" \
  -e "SB_DEFAULT_SERVER_NAME=OutlineServer" \
  -e "SB_API_PREFIX=${API_PREFIX}" \
  "${OUTLINE_IMAGE}" > "${FILES_DIR}/docker_run_output.txt" 2>&1 || {
  echo "Error: Failed to start temporary Outline container. Check logs for details."
  cat "${FILES_DIR}/docker_run_output.txt"
  if sudo docker ps -a --filter "name=^${TEMP_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${TEMP_CONTAINER_NAME}"; then
    echo "Container was created but may have failed. Inspecting..."
    sudo docker logs "${TEMP_CONTAINER_NAME}" > "${FILES_DIR}/shadowbox_temp_logs.txt" 2>&1
    cat "${FILES_DIR}/shadowbox_temp_logs.txt"
    sudo docker inspect "${TEMP_CONTAINER_NAME}" > "${FILES_DIR}/shadowbox_temp_inspect.txt" 2>&1
    cat "${FILES_DIR}/shadowbox_temp_inspect.txt"
    sudo docker rm -f "${TEMP_CONTAINER_NAME}"
  fi
  exit 1
}
rm -f "${FILES_DIR}/docker_run_output.txt"

# Wait for container to initialize (up to 60 seconds)
echo "Waiting for temporary container to initialize..."
for i in {1..60}; do
  if sudo docker ps --filter "name=^${TEMP_CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "${TEMP_CONTAINER_NAME}"; then
    echo "Temporary container is running."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "Error: Temporary container failed to start within 60 seconds."
    sudo docker logs "${TEMP_CONTAINER_NAME}"
    sudo docker inspect "${TEMP_CONTAINER_NAME}" | grep -i "error"
    sudo docker rm -f "${TEMP_CONTAINER_NAME}"
    exit 1
  fi
  sleep 1
done

# Wait for config file to be generated
echo "Waiting for configuration file to be generated..."
CONFIG_GENERATED=false
for i in {1..30}; do
  if [ -f "${CONFIG_FILE}" ]; then
    echo "Configuration file generated: ${CONFIG_FILE}"
    CONFIG_GENERATED=true
    break
  fi
  sleep 1
done

if [ "$CONFIG_GENERATED" = false ]; then
  echo "Warning: Configuration file ${CONFIG_FILE} was not generated within 30 seconds."
  echo "Container logs:"
  sudo docker logs "${TEMP_CONTAINER_NAME}" > "${LOG_FILE}"
  cat "${LOG_FILE}"
  echo "Creating default configuration as fallback..."
  cat << EOF > "${CONFIG_FILE}"
{
  "apiUrl": "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}",
  "certSha256": "placeholder-cert-sha256",
  "hostname": "$(hostname)",
  "port": ${API_PORT}
}
EOF
  echo "Default configuration created."
fi

# Extract certificate from persisted state or generate fallback
echo "Extracting certificate from persisted state..."
CERT_GENERATED=false
for i in {1..30}; do
  CERT_PATH=$(find "${PERSISTED_STATE_DIR}" -type f -name "*.crt" -print -quit 2>/dev/null)
  if [ -n "$CERT_PATH" ]; then
    echo "Certificate found at ${CERT_PATH}"
    cp "${CERT_PATH}" "${CERT_FILE}"
    CERT_GENERATED=true
    break
  elif [ -f "${PERSISTED_STATE_DIR}/outline-ss-server/config.yml" ] && grep -q "cert:" "${PERSISTED_STATE_DIR}/outline-ss-server/config.yml"; then
    CERT_CONTENT=$(awk '/cert:/{flag=1; next} /key:/{flag=0} flag' "${PERSISTED_STATE_DIR}/outline-ss-server/config.yml" | sed 's/^[ \t]*//' | tr -d '\n')
    echo "${CERT_CONTENT}" | base64 -d > "${CERT_FILE}" 2>/dev/null || echo "${CERT_CONTENT}" > "${CERT_FILE}"
    if [ -s "${CERT_FILE}" ]; then
      echo "Certificate extracted from config.yml to ${CERT_FILE}"
      CERT_GENERATED=true
      break
    fi
  fi
  sleep 1
done

if [ "$CERT_GENERATED" = false ]; then
  echo "Warning: Certificate file not found in ${PERSISTED_STATE_DIR} within 30 seconds."
  echo "Container logs:"
  sudo docker logs "${TEMP_CONTAINER_NAME}" > "${LOG_FILE}"
  cat "${LOG_FILE}"
  echo "Generating fallback self-signed certificate..."
  mkdir -p "${CERT_DIR}"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=${PUBLIC_IP}" || {
    echo "Error: Failed to generate fallback certificate."
    exit 1
  }
  echo "Fallback certificate generated: ${CERT_FILE}"
  CERT_GENERATED=true
fi

# Compute certSha256
echo "Computing certSha256..."
CERT_SHA256=$(openssl x509 -in "${CERT_FILE}" -outform der | sha256sum | awk '{print $1}' || echo "error")
if [ "$CERT_SHA256" = "error" ] || [ -z "$CERT_SHA256" ]; then
  echo "Error: Failed to compute certSha256 from ${CERT_FILE}."
  cat "${CERT_FILE}"
  sudo docker logs "${TEMP_CONTAINER_NAME}" > "${LOG_FILE}"
  cat "${LOG_FILE}"
  sudo docker rm -f "${TEMP_CONTAINER_NAME}"
  exit 1
fi
echo "Computed certSha256: ${CERT_SHA256}"

# Update configuration with certSha256 if placeholder exists
if grep -q "placeholder-cert-sha256" "${CONFIG_FILE}"; then
  echo "Updating configuration with computed certSha256..."
  sed -i "s/\"certSha256\": \"placeholder-cert-sha256\"/\"certSha256\": \"${CERT_SHA256}\"/" "${CONFIG_FILE}" || {
    echo "Error: Failed to update ${CONFIG_FILE} with certSha256."
    exit 1
  }
fi

# Verify config file has required fields
echo "Validating configuration file..."
if ! grep -q "apiUrl" "${CONFIG_FILE}" || ! grep -q "certSha256" "${CONFIG_FILE}"; then
  echo "Error: Configuration file ${CONFIG_FILE} is missing required fields (apiUrl or certSha256)."
  cat "${CONFIG_FILE}"
  sudo docker logs "${TEMP_CONTAINER_NAME}" > "${LOG_FILE}"
  cat "${LOG_FILE}"
  sudo docker rm -f "${TEMP_CONTAINER_NAME}"
  exit 1
fi

# Save access information for Outline Manager
echo "Saving access information to ${ACCESS_FILE}..."
cat << EOF > "${ACCESS_FILE}"
{
  "apiUrl": "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}",
  "certSha256": "${CERT_SHA256}"
}
EOF
sudo chown $(whoami):$(whoami) "${ACCESS_FILE}"
echo "Access information saved to ${ACCESS_FILE}. Use this in Outline Manager to connect to the server."

# Secure permissions
sudo chmod -R 600 "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}"
[ -f "${KEY_FILE}" ] && sudo chmod 600 "${KEY_FILE}"
sudo chown $(whoami):$(whoami) "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}"
[ -f "${KEY_FILE}" ] && sudo chown $(whoami):$(whoami) "${KEY_FILE}"

# Stop and remove temporary container
echo "Stopping and removing temporary container..."
sudo docker stop "${TEMP_CONTAINER_NAME}" || {
  echo "Error: Failed to stop temporary container."
  exit 1
}
sudo docker rm "${TEMP_CONTAINER_NAME}" || {
  echo "Error: Failed to remove temporary container."
  exit 1
}

# Step 7: Verify Outline VPN container functionality
echo "Verifying Outline VPN container functionality..."
# Check for port conflicts
echo "Checking for port conflicts on ${API_PORT}..."
if sudo netstat -tuln | grep ":${API_PORT}" > /dev/null; then
  echo "Error: Port ${API_PORT} is already in use."
  sudo netstat -tulnp | grep ":${API_PORT}"
  exit 1
fi
echo "Port ${API_PORT} is free."

# Remove existing container
if sudo docker ps -a --filter "name=^${OUTLINE_CONTAINER_NAME}$" --format '{{.Names}}' | grep -q "${OUTLINE_CONTAINER_NAME}"; then
  echo "Removing existing container ${OUTLINE_CONTAINER_NAME}..."
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}" || {
    echo "Error: Failed to remove existing container."
    exit 1
  }
else
  echo "No existing ${OUTLINE_CONTAINER_NAME} container found."
fi

# Run new Outline container with certificate
echo "Starting new Outline VPN container..."
CERT_ENV=""
[ -f "${KEY_FILE}" ] && CERT_ENV="-e SB_PRIVATE_KEY_FILE=/opt/outline/shadowbox.key -v ${KEY_FILE}:/opt/outline/shadowbox.key"
sudo docker run -d --name "${OUTLINE_CONTAINER_NAME}" \
  -p "${DOCKER_PORT}:${DOCKER_PORT}" \
  -p "${API_PORT}:${API_PORT}" \
  -v "${CONFIG_FILE}:/opt/outline/shadowbox_config.json" \
  -v "${PERSISTED_STATE_DIR}:/root/shadowbox/persisted-state" \
  -v "${CERT_FILE}:/opt/outline/shadowbox.crt" \
  -e "SB_CERTIFICATE_FILE=/opt/outline/shadowbox.crt" \
  ${CERT_ENV} \
  "${OUTLINE_IMAGE}" || {
  echo "Error: Failed to start Outline container."
  exit 1
}

# Wait for container to start
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

# Check container logs
echo "Checking container logs for errors..."
sudo docker logs "${OUTLINE_CONTAINER_NAME}" > "${LOG_FILE}"
if grep -i "error" "${LOG_FILE}"; then
  echo "Error: Errors found in container logs. Full logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
echo "No errors found in logs."

# Verify API port
echo "Verifying API port ${API_PORT} is listening..."
if ! sudo netstat -tuln | grep ":${API_PORT}" > /dev/null; then
  echo "Error: API port ${API_PORT} is not listening."
  echo "Container logs saved to ${LOG_FILE}"
  cat "${LOG_FILE}"
  sudo docker rm -f "${OUTLINE_CONTAINER_NAME}"
  exit 1
fi
echo "API port ${API_PORT} is listening."

# Test API accessibility with retries
echo "Testing Outline API accessibility..."
sleep 10  # Extended wait for API initialization
for attempt in {1..3}; do
  echo "Testing HTTPS API (attempt ${attempt})..."
  HTTP_STATUS=$(curl -s --connect-timeout 5 --max-time 10 -k -o /dev/null -w "%{http_code}" "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys" || echo "curl_failed")
  if [ "$HTTP_STATUS" = "curl_failed" ]; then
    echo "Warning: curl command failed for https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys (attempt ${attempt})"
    curl -v --connect-timeout 5 --max-time 10 -k "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys" > "${FILES_DIR}/curl_http_output.txt" 2>&1
    echo "curl output saved to ${FILES_DIR}/curl_http_output.txt"
    cat "${FILES_DIR}/curl_http_output.txt"
  elif [ "$HTTP_STATUS" != "200" ]; then
    echo "Warning: Outline API returned non-200 status on port ${API_PORT} (HTTP: $HTTP_STATUS, attempt ${attempt})."
    curl -v --connect-timeout 5 --max-time 10 -k "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys" > "${FILES_DIR}/curl_http_output.txt" 2>&1
    echo "curl output saved to ${FILES_DIR}/curl_http_output.txt"
    cat "${FILES_DIR}/curl_http_output.txt"
  else
    echo "Outline API is accessible (HTTP: $HTTP_STATUS)."
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "Error: Outline API failed after 3 attempts."
    echo "Container logs saved to ${LOG_FILE}"
    cat "${LOG_FILE}"
    echo "Container will remain running for debugging. Inspect with 'sudo docker logs shadowbox' or 'sudo docker exec -it shadowbox /bin/sh'."
    exit 1
  fi
  sleep 5
done

# Verify management API
echo "Verifying Outline VPN management API..."
API_RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 -k "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys" || echo "curl_failed")
if [ "$API_RESPONSE" = "curl_failed" ]; then
  echo "Error: curl command failed for https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys"
  curl -v --connect-timeout 5 --max-time 10 -k "https://${PUBLIC_IP}:${API_PORT}/${API_PREFIX}/access-keys" > "${FILES_DIR}/curl_access_keys_output.txt" 2>&1
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

# Stop and remove test container
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

# Step 8: Export Docker image
echo "Exporting Docker image to tar file..."
sudo docker save -o "${OUTLINE_IMAGE_TAR}" "${OUTLINE_IMAGE}"
if [ ! -f "${OUTLINE_IMAGE_TAR}" ]; then
  echo "Error: Failed to create ${OUTLINE_IMAGE_TAR}"
  exit 1
fi
sudo chown $(whoami):$(whoami) "${OUTLINE_IMAGE_TAR}"  # Ensure user can read tar file

# Step 9: Download Docker offline installer packages
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

# Step 10: Zip Outline image, configuration, certificate, and access file
echo "Zipping Outline image, configuration, certificate, and Docker installer..."
# Verify all files exist
for file in "${OUTLINE_IMAGE_TAR}" "${CONFIG_FILE}" "${CERT_FILE}" "${ACCESS_FILE}" "${FILES_DIR}/${DOCKER_OFFLINE_TAR}"; do
  if [ ! -f "${file}" ]; then
    echo "Error: File ${file} does not exist"
    exit 1
  fi
  echo "Confirmed ${file} exists"
done
[ -f "${KEY_FILE}" ] && echo "Confirmed ${KEY_FILE} exists"

# Ensure zip command is available
if ! command -v zip &> /dev/null; then
  echo "Error: zip command not found. Please ensure zip is installed."
  exit 1
fi

# Change to FILES_DIR to simplify zip paths
cd "${FILES_DIR}"
ZIP_FILES="$(basename ${OUTLINE_IMAGE_TAR}) $(basename ${CONFIG_FILE}) $(basename ${CERT_FILE}) $(basename ${ACCESS_FILE}) ${DOCKER_OFFLINE_TAR}"
[ -f "${KEY_FILE}" ] && ZIP_FILES="${ZIP_FILES} $(basename ${KEY_FILE})"
zip -r "${ZIP_OUTPUT}" ${ZIP_FILES} || {
  echo "Error: Failed to create zip file ${ZIP_OUTPUT}"
  exit 1
}

# Verify zip file was created
if [ ! -f "${ZIP_OUTPUT}" ]; then
  echo "Error: Zip file ${ZIP_OUTPUT} was not created"
  exit 1
fi
echo "Zip file created successfully: ${ZIP_OUTPUT}"

# Step 11: Clean up
echo "Cleaning up temporary files..."
rm -f "${OUTLINE_IMAGE_TAR}"
# Comment out the next line if you want to keep docker_offline.tar.gz in FILES_DIR for separate upload
# rm -f "${FILES_DIR}/${DOCKER_OFFLINE_TAR}"

echo "Bundle created as ${ZIP_OUTPUT}"
echo "Transfer ${ZIP_OUTPUT} to https://bash.hiradnikoo.com/outline/files and extract docker_offline.tar.gz for separate upload."
echo "Use ${ACCESS_FILE} to connect Outline Manager to the server."
echo "You can now transfer the files to the second server and run deploy_outline_server.sh."
echo "On the second server (serverB), run the following command to fetch and execute bootstrap-deploy.sh:"
echo "wget -O bootstrap-deploy.sh https://bash.hiradnikoo.com/outline/bootstrap-deploy.sh && chmod +x bootstrap-deploy.sh && sudo ./bootstrap-deploy.sh"
