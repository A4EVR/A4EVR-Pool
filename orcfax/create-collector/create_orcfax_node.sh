#!/bin/bash

#Orcfax Collector Node Deployment Script by A4EVR!
# Version: 1.1.0

# ---------------------------------------------
# Global Variables (Set Dynamically)
# ---------------------------------------------

BASE_DIR=""                    # User selects base directory for Orcfax files (e.g., ~/orcfax)
NODE_NAME=""                   # User selects name of the Orcfax node (e.g., node1)
NODE_DIR=""                    # Node directory
KEYS_DIR=""                    # User directory containing alias payment keys
ORCFAX_IMAGE_NAME=""           # Docker image name for the Orcfax node
ORCFAX_CONTAINER_NAME=""       # Orcfax node container name

# ---------------------------------------------
# Manual Static Variables
# ---------------------------------------------

COLLECTOR_WHL_URL="https://github.com/orcfax/collector-node/releases/download/2.0.1/collector_node-2.0.1rc1-py3-none-any.whl"
CER_FEEDS_URL="https://raw.githubusercontent.com/orcfax/cer-feeds/refs/tags/2024.10.30.0001/feeds/mainnet/cer-feeds.json"
GOFER_URL="https://github.com/orcfax/oracle-suite/releases/download/0.5.0/gofer_0.5.0_Linux_x86_64"
OGMIOS_URL="ws://example.com/ogmios"


# Table of Contents (Functions)
# -----------------
# 1. Unified Helper Functions
#    1.1. confirm
#    1.2. manage_container
#    1.3. manage_directory
#    1.4. deploy_container
#
# 2. Initialization Functions
#    2.1. welcome
#    2.2. check_docker_group
#    2.3. install_dependencies
#    2.4. get_node_choice_and_base_dir
#    2.5. setup_environment (Top-Level Function)
#
# 3. Orcfax Collector Setup Functions
#    3.1. get_keys_directory
#    3.2. setup_directories
#    3.3. get_orcfax_files
#    3.4. make_gofer_executable
#    3.5. copy_payment_keys
#    3.6. create_dummy_file
#    3.7. generate_node_env
#    3.8. generate_start_script
#    3.9. generate_orcfax_dockerfile
#    3.10. setup_orcfax_collector (Top-Level Function)
#
# 4. Final Deployment Functions
#    4.1. build_orcfax_image
#    4.2. final_deployment (Top-Level Function)


# ---------------------------------------------
# Helper Functions
# ---------------------------------------------

confirm() {
    local message=$1
    read -p "$message (yes/no): " response
    [[ "$response" == "yes" ]]
}

manage_container() {
    local container_name=$1
    local action=$2  # "check", "start", "stop", "remove", "running"

    case "$action" in
        check)
            echo "Checking if container $container_name exists..."
            docker ps -a --format '{{.Names}}' | grep -w "$container_name" > /dev/null
            ;;
        start)
            echo "Starting container $container_name..."
            docker start "$container_name" || { echo "ERROR: Failed to start $container_name."; exit 1; }
            echo "Container $container_name started successfully."
            ;;
        stop)
            echo "Stopping container $container_name..."
            docker stop "$container_name" || { echo "ERROR: Failed to stop $container_name."; exit 1; }
            echo "Container $container_name stopped successfully."
            ;;
        remove)
            if docker ps -a --format '{{.Names}}' | grep -w "$container_name" > /dev/null; then
                echo "Container $container_name exists and should be removed to avoid conflict."
                if confirm "Do you want to remove the container $container_name?"; then
                   docker stop "$container_name" && docker rm "$container_name" || {
                        echo "ERROR: Failed to remove $container_name. Please check Docker's status."
                        exit 1
                    }
                    echo "Container $container_name removed successfully."
                else
                    echo "Container removal cancelled."
                fi
            else
                echo "Container $container_name does not exist. No conflicts found, proceeding."
            fi
            ;;
        running)
            echo "Checking if container $container_name is running..."
            if docker ps --filter "name=^${container_name}$" --filter "status=running" --format '{{.Names}}' | grep -qw "$container_name"; then
                echo "Container $container_name is running."
                return 0  # Running
            else
                echo "Container $container_name is not running."
                return 1  # Not running
            fi
            ;;
        *)
            echo "ERROR: Invalid action for manage_container. Use 'check', 'start', 'stop', 'remove', or 'running'."
            exit 1
            ;;
    esac
}

manage_directory() {
    local dir_path=$1
    local action=${2:-create}   #Actions: "create", "overwrite", "check_empty"
    local owner=${3:-}         # Optional: Owner to set (e.g., "user:group")
    local permissions=${4:-}   # Optional: Permissions to set (e.g., "700")

    if [ -d "$dir_path" ]; then
        case "$action" in
            overwrite)
                if confirm "Warning! Directory $dir_path exists. Overwrite it?"; then
                    rm -rf "$dir_path"/* "$dir_path"/.[!.]* "$dir_path"/..?* 2>/dev/null || {
                        echo "ERROR: Failed to clear directory $dir_path."
                        exit 1
                    }
                    echo "Directory cleared: $dir_path"
                else
                    echo "Skipping overwrite."
                    exit 1
                fi
                ;;
            check_empty)
                if [ "$(ls -A "$dir_path" 2>/dev/null)" ]; then
                    echo "ERROR: Directory $dir_path is not empty. Please clear it first."
                    exit 1
                fi
                ;;
            create)
                # Default behavior: Leave the directory as-is if it exists
                echo "Directory $dir_path already exists. Proceeding."
                ;;
            *)
                echo "ERROR: Invalid action specified for manage_directory. Options are: create, overwrite, check_empty."
                exit 1
                ;;
        esac
    else
        mkdir -p "$dir_path" || {
            echo "ERROR: Failed to create directory $dir_path."
            exit 1
        }
        echo "Directory created: $dir_path"
    fi

    # Set ownership if specified
    if [[ -n "$owner" ]]; then
        echo "Setting ownership of $dir_path to $owner..."
        if ! /usr/bin/sudo /bin/chown "$owner" "$dir_path"; then
            echo "ERROR: Failed to set ownership of $dir_path to $owner."
            exit 1
        fi
    fi

    # Set permissions if specified
    if [[ -n "$permissions" ]]; then
        echo "Setting permissions of $dir_path to $permissions..."
        if ! /usr/bin/sudo /bin/chmod "$permissions" "$dir_path"; then
            echo "ERROR: Failed to set permissions of $dir_path to $permissions."
            exit 1
        fi
    fi
}

deploy_container() {
    local container_name=$1
    local image_name=$2
    local ports=$3
    local volumes=$4
    local additional_args=$5

    echo "Deploying container: $container_name with image: $image_name"
    docker run -d --name "$container_name" \
        --restart unless-stopped \
        $ports $volumes $additional_args \
        "$image_name" || {
            echo "ERROR: Failed to start container $container_name."
            exit 1
        }
    echo "Container $container_name deployed successfully."
}

# ---------------------------------------------
# Initial Setup Functions
# ---------------------------------------------

welcome() {
    echo
    echo "Welcome to the Orcfax Collector Node Deployment Script by A4EVR!"
    echo
    echo "This script automates the setup and deployment of a containerized Orcfax ITN Phase 1 node."
    echo
    echo "Deployment should complete in 1-2 minutes."
    echo

    # Wait for user confirmation
    if confirm "Ready to proceed?"; then
        echo
    else
        echo "Exiting."
        exit 0
    fi
}

check_docker_group() {
    CURRENT_USER=$(whoami)

    if ! groups "$CURRENT_USER" | grep -q "\bdocker\b"; then
	echo "The current user ($CURRENT_USER) is not in the Docker group."
	echo "Adding $CURRENT_USER to the Docker group..."
	sudo usermod -aG docker "$CURRENT_USER"
	echo "Please log out and back in to refresh group membership."
	echo "Alternatively, enter command 'newgrp docker' to apply changes immediately."
	exit 0
    fi
}

install_dependencies() {
    echo "Checking and installing required dependencies..."
    echo "Updating package list..."
    sudo apt-get update -y

    # Define dependencies
    local apt_dependencies=(curl git jq apt-transport-https ca-certificates software-properties-common docker-ce docker-ce-cli containerd.io docker-compose-plugin)

    # Check and install apt-based dependencies
    for package in "${apt_dependencies[@]}"; do
        if ! dpkg -l | grep -qw "$package"; then
            echo "$package not found. Installing..."
            sudo apt-get install -y "$package" || { echo "Failed to install $package. Exiting."; exit 1; }
        else
            echo "$package is already installed."
        fi
    done

    # Install Docker if not installed (special handling for repository setup)
    if ! command -v docker &> /dev/null; then
        echo "Docker not found. Installing Docker CE..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io || { echo "Failed to install Docker CE. Exiting."; exit 1; }
        sudo systemctl start docker
        sudo systemctl enable docker
    fi

    # Enable Buildx if not available
    if ! docker buildx version &> /dev/null; then
        echo "Enabling Buildx..."
        docker buildx create --use --name mybuilder || { echo "Failed to enable Buildx. Exiting."; exit 1; }
        docker buildx inspect mybuilder --bootstrap
    fi

    echo "All dependencies are installed and up-to-date."
    echo
}

get_node_choice_and_base_dir() {
    read -p "Use the default base directory ~/orcfax? (y/n): " BASE_RESPONSE
    if [[ "$BASE_RESPONSE" == "y" || -z "$BASE_RESPONSE" ]]; then
        BASE_DIR=~/orcfax
        manage_directory "$BASE_DIR" "create"
    else
        read -p "Enter the full path you want to use for the base directory: " USER_BASE_DIR
        BASE_DIR=$(realpath "${USER_BASE_DIR/#\~/$HOME}")
        manage_directory "$BASE_DIR" "create"
    fi

    read -p "Enter a name for the Orcfax node (e.g., node1): " NODE_NAME
    if [[ ! "$NODE_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        echo "ERROR: Invalid node name. Only alphanumeric characters and underscores (_) are allowed."
        exit 1
    fi
   
    # Define variables based on user input
    NODE_DIR="$BASE_DIR/$NODE_NAME"
    ORCFAX_IMAGE_NAME="orcfax_$NODE_NAME"
    ORCFAX_CONTAINER_NAME="orcfax_$NODE_NAME"
}

# Top-Level Function to set up initial environment
setup_environment() {
    welcome
    
    echo -e "\033[1;32m#### Initial setup ####\033[0m"
    echo

    check_docker_group
    install_dependencies
    get_node_choice_and_base_dir

    echo "Environment initialized successfully."
    echo
}

# ---------------------------------------------
# Functions for Orcfax Collector Setup
# ---------------------------------------------

# Copy Orcfax collector signing keys
get_keys_directory() {
	echo "Checking for alias payment keys required for Orcfax collector..."
	if ls "$BASE_DIR"/payment.* 1> /dev/null 2>&1; then
	echo "Payment keys found in the base directory: $BASE_DIR"
	echo
	KEYS_DIR="$BASE_DIR"
	else
	echo "Alias payment keys not found in the base directory."
	read -p "Enter the full path to the directory containing your alias payment keys: " KEYS_DIR
	KEYS_DIR=$(realpath "${KEYS_DIR/#\~/$HOME}")

	if [ ! -d "$KEYS_DIR" ] || ! ls "$KEYS_DIR"/payment.* 1> /dev/null 2>&1; then
		    echo "ERROR: Invalid directory or missing payment keys."
		    exit 1
	fi

	echo "Payment keys successfully located in: $KEYS_DIR"
	echo
	fi
}

setup_directories() {
    manage_directory "$NODE_DIR" "overwrite" # Explicit create and overwrite

    echo "Setting up subdirectories..."
    manage_directory "$NODE_DIR/signing-key" "create"
    manage_directory "$NODE_DIR/gofer" "create"

    echo "Directories successfully created at $NODE_DIR."
    echo
}

get_orcfax_files() {
    # Helper function to curl download file
    download_file() {
        local url=$1
        local output_path=$2

        echo "Downloading $(basename "$output_path")..."
        if ! curl -L "$url" -o "$output_path"; then
            echo "ERROR: Failed to download $(basename "$output_path") from $url. Exiting."
            exit 1
        fi
        echo "$(basename "$output_path") downloaded successfully."
    }

    echo "Downloading files for Orcfax collector setup..."

    # Download cer-feeds.json
    download_file "$CER_FEEDS_URL" "$NODE_DIR/cer-feeds.json"

    # Download collector_node wheel
    download_file "$COLLECTOR_WHL_URL" "$NODE_DIR/collector_node-2.0.1rc1-py3-none-any.whl"

    # Download gofer binary
    download_file "$GOFER_URL" "$NODE_DIR/gofer/gofer"

    echo "All files downloaded successfully."
}

make_gofer_executable() {
    echo "Setting executable permission for Gofer binary..."
    echo
    chmod +x $NODE_DIR/gofer/gofer || { echo "ERROR: Failed to set executable permission on gofer binary."; exit 1; }
}

copy_payment_keys() {
    echo "Copying payment keys from $KEYS_DIR to $NODE_DIR/signing-key..."
    cp "$KEYS_DIR"/payment.* "$NODE_DIR/signing-key/" || { echo "ERROR: Failed to copy payment keys."; exit 1; }
    echo "Payment keys successfully copied to $NODE_DIR/signing-key."
    echo
}

create_dummy_file() {
    echo "Creating dummy file notused.db..."
    echo
    touch $NODE_DIR/notused.db || { echo "ERROR: Failed to create dummy file."; exit 1; }
    chmod 644 $NODE_DIR/notused.db || { echo "ERROR: Failed to set permissions on dummy file."; exit 1; }
}

generate_node_env() {
    echo "Generating node.env file..."
    echo
    cat > $NODE_DIR/node.env <<EOL
export ORCFAX_VALIDATOR=wss://itn.0.orcfax.io/ws/node
export NODE_IDENTITY_LOC=/tmp/.node-identity.json
export NODE_SIGNING_KEY=/orcfax/$NODE_NAME/signing-key/payment.skey
export GOFER=/orcfax/$NODE_NAME/gofer/gofer
export CNT_DB_NAME=/orcfax/$NODE_NAME/notused.db
export OGMIOS_URL=${OGMIOS_URL}
EOL
}

generate_start_script() {
    echo "Creating start.sh script in $NODE_DIR..."
    echo
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

chmod +x $NODE_DIR/start.sh || { echo "ERROR: Failed to set executable permission on start.sh"; exit 1; }
}

generate_orcfax_dockerfile() {
    echo "Generating Dockerfile in $NODE_DIR..."
    echo
    cat > "$NODE_DIR/Dockerfile" <<EOL
FROM python:3.10-slim

# Set working directory inside the container
WORKDIR /orcfax/$NODE_NAME

# Install required packages, clean up, and set up logging configuration
RUN apt-get update && apt-get install -y \\
    wget \\
    jq \\
    cron \\
    procps \\
    rsyslog \\
    nano && \\
    apt-get clean && \\
    rm -rf /var/lib/apt/lists/* && \\
    touch /var/log/cron.log && \\
    echo ':programname, isequal, "orcfax_collector" /var/log/collector_node.log' >> /etc/rsyslog.conf && \\
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
RUN echo "* * * * * root . /orcfax/$NODE_NAME/node.env && ORCFAX_VALIDATOR=\\\$ORCFAX_VALIDATOR NODE_IDENTITY_LOC=\\\$NODE_IDENTITY_LOC NODE_SIGNING_KEY=\\\$NODE_SIGNING_KEY GOFER=\\\$GOFER CNT_DB_NAME=\\\$CNT_DB_NAME OGMIOS_URL=\\\$OGMIOS_URL /orcfax/$NODE_NAME/collector/venv/bin/python3 /orcfax/$NODE_NAME/collector/venv/bin/collector-node --feeds /orcfax/$NODE_NAME/cer-feeds.json 2>&1 | logger -t orcfax_collector" > /etc/cron.d/orcfax_cron && \\
    chmod 0644 /etc/cron.d/orcfax_cron && \\
    crontab /etc/cron.d/orcfax_cron

# Copy the start.sh script and set executable permissions
COPY start.sh /orcfax/$NODE_NAME/start.sh
RUN chmod +x /orcfax/$NODE_NAME/start.sh

# Add health check to ensure collector-node process is running and .node-identity.json exists
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \\
    CMD pgrep -f "collector-node" > /dev/null && \\
        [ -f /tmp/.node-identity.json ] || exit 1

# Start rsyslog and cron in the entrypoint
CMD ["sh", "-c", "rsyslogd && /orcfax/$NODE_NAME/start.sh"]
EOL
}

# Top-Level Function to configure and deploy new Orcfax collector node as a container
setup_orcfax_collector() {
    echo -e "\033[1;32m#### Orcfax Collector Setup ####\033[0m"
    echo

    # Handle conflicts with existing container
    manage_container "$ORCFAX_CONTAINER_NAME" "remove"

    # Proceed with creating the collector node
    get_keys_directory
    setup_directories
    get_orcfax_files
    make_gofer_executable
    copy_payment_keys
    create_dummy_file
    generate_node_env
    generate_start_script
    generate_orcfax_dockerfile

    echo "Orcfax collector setup completed successfully."
    echo
}

# ---------------------------------------------
# Final Deployment Functions
# ---------------------------------------------

build_orcfax_image() {
        echo "Building Docker image for $NODE_NAME..."

    cd "$NODE_DIR" || { echo "ERROR: Failed to navigate to $NODE_DIR. Directory might not exist."; exit 1; }

    echo "Building image: ${ORCFAX_IMAGE_NAME}"
    if ! docker buildx build --platform linux/amd64 -t "$ORCFAX_IMAGE_NAME" .; then
        echo "ERROR: Docker image build failed. Exiting."
        exit 1
    fi

    if ! docker images "$ORCFAX_IMAGE_NAME" | grep -q "$ORCFAX_IMAGE_NAME"; then
        echo "ERROR: Docker image ${ORCFAX_IMAGE_NAME} was not successfully created. Exiting."
        exit 1
    fi

    echo "Docker image ${ORCFAX_IMAGE_NAME} successfully built."
    echo
}

display_final_notes() {
    echo
    echo -e "\033[1;32m#### Deployment is now complete! ####\033[0m"
    echo
    echo "$ORCFAX_CONTAINER_NAME is running with restart policy 'unless-stopped'."
    echo
    echo "## Verify containers:"
    echo "docker ps -a"
    echo "docker stats"
    echo 
    echo "## Verify processes:"
    echo "docker exec -it $ORCFAX_CONTAINER_NAME ps aux"
    echo 
    echo "## Verify cron in the collector node ($ORCFAX_CONTAINER_NAME):"
    echo "docker exec -it $ORCFAX_CONTAINER_NAME ps aux | grep cron"
    echo "docker exec -it $ORCFAX_CONTAINER_NAME tail -f /var/log/cron.log"
    echo 
    echo "## Display collector log (tailing the log):"
    echo "docker exec -it $ORCFAX_CONTAINER_NAME tail -f /var/log/collector_node.log"
    echo 
    echo "Health check details for Orcfax collector container:"
    echo "  - Ensures the 'collector-node' process is running."
    echo "  - Confirms the '.node-identity.json' file exists in '/tmp'."
    echo 
    echo "Happy collecting :)"
    echo
}

# Top-Level Function to build and deploy node
final_deployment() {
    echo -e "\033[1;32m#### Final deployment ####\033[0m"
    echo

    build_orcfax_image

    # Deploy the container using helper function
    deploy_container "$ORCFAX_CONTAINER_NAME" "$ORCFAX_IMAGE_NAME" "" "-v $NODE_DIR:/orcfax/$NODE_NAME" ""

    display_final_notes
}



# ---------------------------------------------
# Main Script Execution
# ---------------------------------------------

setup_environment
setup_orcfax_collector
final_deployment

