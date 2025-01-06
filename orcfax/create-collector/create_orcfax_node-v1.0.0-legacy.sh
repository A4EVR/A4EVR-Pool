#!/bin/bash

# Orcfax Node Deployment Script by A4EVR

# Exit on error
set -e

# Step 1: Ensure the current user is in the Docker group
CURRENT_USER=$(whoami)
if ! groups $CURRENT_USER | grep -q "\bdocker\b"; then
    echo "Adding $CURRENT_USER to the Docker group..."
    sudo usermod -aG docker $CURRENT_USER
    echo "Docker group updated. Please log out and back in to refresh OR run 'newgrp docker' to apply changes." 
    echo "Then run this script again."
    exit 0  
fi

# Step 2: Ask user to create a node name
read -p "Choose a name for the orcfax node and enter it here (e.g. type node1). This will create a new directory at ~/orcfax/<node name>: " NODE_NAME

# Validate the node name using regex
if [[ ! "$NODE_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "ERROR: Invalid node name. Only alphanumeric characters and underscores are allowed."
    exit 1
fi

# Step 3: Ask the user for the keys directory
read -p "Enter the directory where your payment keys are stored (e.g. type ~/orcfax if keys are located here): " KEYS_DIR
# Expand ~ if used in KEYS_DIR and normalize with realpath
KEYS_DIR=$(realpath "${KEYS_DIR/#\~/$HOME}")

# Validate the keys directory and check if payment keys are present
if [ ! -d "$KEYS_DIR" ]; then
    echo "ERROR: The directory $KEYS_DIR does not exist. Please provide a valid directory containing the payment keys."
    exit 1
fi

if ! ls $KEYS_DIR/payment.* 1> /dev/null 2>&1; then
    echo "ERROR: No payment keys (payment.*) found in $KEYS_DIR. Please ensure the files are present."
    exit 1
fi

echo "Payment keys found in $KEYS_DIR."

# After user input, Define directories and Docker variables
NODE_DIR=~/orcfax/$NODE_NAME
DOCKER_IMAGE_NAME="orcfax-$NODE_NAME-image"  
DOCKER_CONTAINER_NAME="orcfax-$NODE_NAME"

# Orcfax URLs
COLLECTOR_WHL_URL="https://github.com/orcfax/collector-node/releases/download/2.0.1/collector_node-2.0.1rc1-py3-none-any.whl"
CER_FEEDS_URL="https://raw.githubusercontent.com/orcfax/cer-feeds/refs/tags/2024.10.30.0001/feeds/mainnet/cer-feeds.json"
GOFER_URL="https://github.com/orcfax/oracle-suite/releases/download/0.5.0/gofer_0.5.0_Linux_x86_64"

# Step 4: Install Dependencies (Docker, Git, Buildx)
echo "Checking for dependencies..."

# Check for Docker
if ! command -v docker &> /dev/null; then
    echo "Docker not found, installing..."
    sudo apt-get update
    sudo apt-get install -y docker.io
    
# Start and enable the Docker service
    echo "Starting and enabling Docker service..."
    sudo systemctl start docker
    sudo systemctl enable docker
fi

# Enable Docker Buildx if not already enabled
if ! docker buildx version &> /dev/null; then
    echo "Docker Buildx not found, enabling..."
    docker run --privileged --rm tonistiigi/binfmt --install all
    docker buildx create --use
fi

# Check for Git
if ! command -v git &> /dev/null; then
    echo "Git not found, installing..."
    sudo apt-get install -y git
fi

# Step 5: Set up Directories
if [ -d "$NODE_DIR" ]; then
    echo "The directory $NODE_DIR already exists."
    read -p "Do you want to overwrite it? (yes/no): " RESPONSE
    if [ "$RESPONSE" != "yes" ]; then
        echo "Exiting without making changes."
        exit 0
    else
        echo "Overwriting $NODE_DIR..."
        rm -rf "$NODE_DIR" || { echo "ERROR: Failed to remove $NODE_DIR. Please check permissions."; exit 1; }
    fi
fi

echo "Setting up directories..."
mkdir -p "$NODE_DIR" "$NODE_DIR/signing-key" "$NODE_DIR/gofer" || { echo "ERROR: Failed to create directories."; exit 1; }

# Validate that $NODE_DIR was created successfully
if [ ! -d "$NODE_DIR" ]; then
    echo "ERROR: Failed to create directory $NODE_DIR. Please check permissions and try again."
    exit 1
fi

echo "Directories successfully created at $NODE_DIR."

# Step 6: Download necessary files
echo "Downloading necessary files..."
echo "Downloading cer-feeds.json..."
if ! curl -L $CER_FEEDS_URL -o $NODE_DIR/cer-feeds.json; then
    echo "ERROR: Failed to download cer-feeds.json. Exiting."
    exit 1
fi

echo "Downloading collector_node wheel..."
if ! curl -L $COLLECTOR_WHL_URL -o $NODE_DIR/collector_node-2.0.1rc1-py3-none-any.whl; then
    echo "ERROR: Failed to download collector_node wheel. Exiting."
    exit 1
fi

echo "Downloading gofer binary..."
if ! curl -L $GOFER_URL -o $NODE_DIR/gofer/gofer; then
    echo "ERROR: Failed to download gofer binary. Exiting."
    exit 1
fi

# Step 7: Make gofer executable
chmod +x $NODE_DIR/gofer/gofer || { echo "ERROR: Failed to set executable permission on gofer binary."; exit 1; }

# Step 8: Copy Payment Keys to the signing-key Directory
echo "Copying payment keys..."
cp $KEYS_DIR/payment.* $NODE_DIR/signing-key/

# Step 9: Create dummy file notused.db
echo "Creating dummy file notused.db..."
touch $NODE_DIR/notused.db
chmod 644 $NODE_DIR/notused.db || { echo "ERROR: Failed to set permissions on notused.db"; exit 1; }

# Step 10: Generate node.env file 
echo "Creating node.env file in $NODE_DIR..."
cat > $NODE_DIR/node.env <<EOL
export ORCFAX_VALIDATOR=wss://itn.0.orcfax.io/ws/node
export NODE_IDENTITY_LOC=/tmp/.node-identity.json
export NODE_SIGNING_KEY=/orcfax/$NODE_NAME/signing-key/payment.skey
export GOFER=/orcfax/$NODE_NAME/gofer/gofer
export CNT_DB_NAME=/orcfax/$NODE_NAME/notused.db
export OGMIOS_URL=ws://example.com/ogmios
EOL

# Step 11: Generate start.sh for Docker container environment
echo "Creating start.sh script in $NODE_DIR..."
cat > $NODE_DIR/start.sh <<EOL
#!/bin/sh

# Source node.env to load environment variables
if [ -f /orcfax/$NODE_NAME/node.env ]; then
    echo "Sourcing node.env file..."
    . /orcfax/$NODE_NAME/node.env
else
    echo "node.env file not found! Ensure it exists in /orcfax/$NODE_NAME."
    exit 1
fi

# Check if .node-identity.json exists in /tmp
if [ ! -f /tmp/.node-identity.json ]; then
    echo "Creating .node-identity.json..."
    # Run gofer to generate the .node-identity.json if it doesn't exist
    /orcfax/$NODE_NAME/gofer/gofer data ADA/USD -o orcfax
else
    echo ".node-identity.json already exists."
fi

# Set permissions for cer-feeds.json if necessary
if [ -f /orcfax/$NODE_NAME/cer-feeds.json ]; then
    chmod 644 /orcfax/$NODE_NAME/cer-feeds.json
    echo "cer-feeds.json permissions set."
else
    echo "cer-feeds.json not found!"
    exit 1
fi

# Start cron and log tailing
echo "Starting cron..."
cron && tail -f /var/log/cron.log
EOL

# Step 12: Generate Dockerfile 
echo "Generating Dockerfile in $NODE_DIR..."
cat > $NODE_DIR/Dockerfile <<EOL
FROM python:3.10-slim

# Set working directory inside the container
WORKDIR /orcfax/$NODE_NAME

# Install required packages
RUN apt-get update && apt-get install -y \\
    wget \\
    jq \\
    cron \\
    procps \\
    rsyslog \\
    nano \\
    && rm -rf /var/lib/apt/lists/*

# Create a log file for cron
RUN touch /var/log/cron.log

# Configure rsyslog for orcfax_collector logs
RUN echo ':programname, isequal, "orcfax_collector" /var/log/collector_node.log' >> /etc/rsyslog.conf && \\
    echo '& stop' >> /etc/rsyslog.conf

# Copy all files to the container
COPY . .

# Ensure the Gofer binary is executable
RUN chmod +x /orcfax/$NODE_NAME/gofer/gofer

# Ensure Python symlink 
RUN ln -sf /usr/local/bin/python3 /usr/bin/python3

# Set up the Python virtual environment and install requirements
RUN python3 -m venv /orcfax/$NODE_NAME/collector/venv && \\
    /orcfax/$NODE_NAME/collector/venv/bin/python3 -m pip install --upgrade pip && \\
    /orcfax/$NODE_NAME/collector/venv/bin/pip install \\
        certifi==2024.7.4 \\
        pydantic==2.8.2 \\
        python-dotenv==1.0.1 \\
        websockets==13.0 \\
        simple-sign==0.0.1 && \\
    /orcfax/$NODE_NAME/collector/venv/bin/pip install /orcfax/$NODE_NAME/collector_node-2.0.1rc1-py3-none-any.whl

# Create the cron job for $NODE_NAME
RUN echo "* * * * * . /orcfax/$NODE_NAME/node.env && ORCFAX_VALIDATOR=\\\$ORCFAX_VALIDATOR NODE_IDENTITY_LOC=\\\$NODE_IDENTITY_LOC NODE_SIGNING_KEY=\\\$NODE_SIGNING_KEY GOFER=\\\$GOFER CNT_DB_NAME=\\\$CNT_DB_NAME OGMIOS_URL=\\\$OGMIOS_URL /orcfax/$NODE_NAME/collector/venv/bin/python3 /orcfax/$NODE_NAME/collector/venv/bin/collector-node --feeds /orcfax/$NODE_NAME/cer-feeds.json 2>&1 | logger -t orcfax_collector" > /etc/cron.d/orcfax_cron && \\
    chmod 0644 /etc/cron.d/orcfax_cron && \\
    crontab /etc/cron.d/orcfax_cron

# Copy the start.sh script and set executable permissions
COPY start.sh /orcfax/$NODE_NAME/start.sh
RUN chmod +x /orcfax/$NODE_NAME/start.sh

# Start rsyslog and cron in the entrypoint
CMD ["sh", "-c", "rsyslogd && /orcfax/$NODE_NAME/start.sh"]
EOL

# Step 13: Build the Docker image
echo "Building Docker image..."
cd "$NODE_DIR" || { echo "ERROR: Failed to navigate to $NODE_DIR. Directory might not exist."; exit 1; }

if ! docker buildx build --platform linux/amd64 -t "$DOCKER_IMAGE_NAME" .; then
    echo "ERROR: Docker image build failed. Exiting."
    exit 1
fi

echo "Docker image built successfully: $DOCKER_IMAGE_NAME"

# Step 14: Check for existing container and prompt user for confirmation
if docker ps -a --format '{{.Names}}' | grep -w $DOCKER_CONTAINER_NAME > /dev/null; then
    echo "A container with the name $DOCKER_CONTAINER_NAME already exists."

    # Prompt user for confirmation with validation
    while true; do
        read -p "Do you want to stop and remove it to deploy the new one? (yes/no): " USER_RESPONSE
        case $USER_RESPONSE in
            yes)
                echo "Stopping and removing the existing container..."
                if ! docker stop $DOCKER_CONTAINER_NAME; then
                    echo "ERROR: Failed to stop the existing container."
                    exit 1
                fi
                if ! docker rm $DOCKER_CONTAINER_NAME; then
                    echo "ERROR: Failed to remove the existing container."
                    exit 1
                fi
                break
                ;;
            no)
                echo "Exiting without making changes."
                exit 0
                ;;
            *)
                echo "Invalid response. Please answer yes or no."
                ;;
        esac
    done
fi

# Step 15: Run the Docker container
echo "Deploying the Docker container..."
if ! docker run -d --name $DOCKER_CONTAINER_NAME --restart unless-stopped $DOCKER_IMAGE_NAME; then
    echo "ERROR: Docker container deployment failed. Exiting."
    exit 1
fi
  
# Final checks and tips
echo "Deployment complete. Docker container is running with restart policy 'unless-stopped'."
echo
echo "You can try the following checks to ensure everything is working properly, allow ~1 minute for initialization:"
echo
echo "##Verify cron is running in the container"
echo "docker exec -it $DOCKER_CONTAINER_NAME ps aux | grep cron"
echo
echo "##Check cron log:"
echo "docker exec -it $DOCKER_CONTAINER_NAME tail -f /var/log/cron.log"
echo
echo "##Display collector log (tailing the log):"
echo "docker exec -it $DOCKER_CONTAINER_NAME tail -f /var/log/collector_node.log"
echo
echo "Happy collecting :)"

