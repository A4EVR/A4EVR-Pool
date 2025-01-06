#!/bin/bash

# Orcfax Node Suite Script by A4EVR
# Version: 1.0.0

# ---------------------------------------------
# Global Variables Set Dynamically
# ---------------------------------------------

CARDANO_NODE_CHOICE=""         # User selects to build a new cardano-node or use an existing one
BASE_DIR=""                    # User selects base directory for Orcfax files (e.g., ~/orcfax)
NODE_NAME=""                   # User selects name of the Orcfax node (e.g., node1)
NODE_DIR=""                    # Node directory
KEYS_DIR=""                    # User enters directory containing their alias payment keys
SOCKET_PATH=""                 # Path to cardano-node node.socket (local or shared volume), detected by script or user defined
ORCFAX_IMAGE_NAME=""           # Docker image name for Orcfax collector
ORCFAX_CONTAINER_NAME=""       # Collector container name
STANDALONE_OGMIOS_CONTAINER=""       # Name for new standalone Ogmios instance, otherwise null (used for deployment logic)
OGMIOS_URL=""		       # Ogmios endpoint, dynamically set by script or user defined
CARDANO_OGMIOS_CONTAINER=""    # Combined Cardano-node + Ogmios container name (for new cardano-node)
MITHRIL_CONTAINER_NAME=""      # Used to bootstrap the shared DB if new cardano-node is selected
ACTIVE_OGMIOS_CONTAINER=""     # Tracks the active Ogmios container, either existing or newly deployed, null if custom endpoint (used for deployment logic)
CARDANO_DB_DIR=""              # Directory for the Cardano blockchain database (shared volume or local directory), detected by script or user defined
OGMIOS_PORT=""                 # Ogmios WebSocket port
COMPOSE_FILE=""                # Path to docker-compose.yml

# -----------------------
# Manual Static Variables
# -----------------------

#Cardano-node (new instance)
CARDANO_IPC_DIR="/opt/cardano/ipc" # IPC directory for the node.socket (used for shared volumes) when creating new cardano-node
# Orcfax
COLLECTOR_WHL_URL="https://github.com/orcfax/collector-node/releases/download/2.0.1/collector_node-2.0.1rc1-py3-none-any.whl"
CER_FEEDS_URL="https://raw.githubusercontent.com/orcfax/cer-feeds/refs/tags/2024.10.30.0001/feeds/mainnet/cer-feeds.json"
GOFER_URL="https://github.com/orcfax/oracle-suite/releases/download/0.5.0/gofer_0.5.0_Linux_x86_64"
# Ogmios
STANDALONE_OGMIOS_IMAGE="cardanosolutions/ogmios:latest"
CARDANO_OGMIOS_IMAGE="cardanosolutions/cardano-node-ogmios:latest"
# Mithril
MITHRIL_DOCKER_IMAGE="ghcr.io/input-output-hk/mithril-client:latest"
AGGREGATOR_ENDPOINT="https://aggregator.release-mainnet.api.mithril.network/aggregator"
GENESIS_KEY_URL="https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-mainnet/genesis.vkey"

# Table of Contents (functions)
# -----------------
# 1. Unified Helper Functions
#    1.1. confirm
#    1.2. detect_node_socket
#    1.3. manage_port
#    1.4. manage_container
#    1.5. manage_directory
#    1.6. deploy_container
# 2. Initialization Functions
#    2.1. welcome
#    2.2. check_docker_group
#    2.3. get_node_choice_and_base_dir
#    2.4. install_dependencies
#    2.5. setup_environment (Top-Level Function)
# 3. Cardano-node Setup Functions
#    3.1. setup_cardano_db
#    3.2. setup_mithril
#    3.3. run_cardano_ogmios_container
#    3.4. wait_for_socket
#    3.5. deploy_cardano_ogmios_container
#    3.6. setup_cardano_node (Top-Level Function)
# 4. Ogmios Setup Functions
#    4.1. handle_ogmios_containers
#    4.2. deploy_or_reuse_instance
#    4.3. prompt_custom_endpoint
#    4.4. prepare_standalone_ogmios
#    4.5. display_containers
#    4.6. setup_ogmios (Top-Level Function)
# 5. Orcfax Collector Setup Functions
#    5.1. setup_directories
#    5.2. get_keys_directory
#    5.3. get_orcfax_files
#    5.4. make_gofer_executable
#    5.5. copy_payment_keys
#    5.6. create_dummy_file
#    5.7. generate_node_env
#    5.8. generate_start_script
#    5.9. generate_orcfax_dockerfile
#    5.10. setup_orcfax_collector (Top-Level Function)
# 6. Deployment Functions
#    6.1. generate_docker_compose
#    6.2. build_orcfax_image
#    6.3. run_docker_compose
#    6.4. final_deployment (Top-Level Function)
# 7. Final Logging and Notes Functions
#    7.1. write_log_file
#    7.2. display_final_notes
#    7.3. final_logging (Top-Level Function)

# Exit on error
set -e

# ------------------------
# Unified Helper Functions
# ------------------------

confirm() {
    local message=$1
    read -p "$message (yes/no): " response
    [[ "$response" == "yes" ]]
}

# Determine cardano-node node.socket
detect_node_socket() {
    echo "Detecting node.socket for the Cardano-node..."

    # Define common directories to search
    SEARCH_DIRS=("/home" "/tmp" "/var/run" "/mnt" "/opt" "/etc" "/ipc")
    SOCKET_NAME="node.socket"
    FOUND_PATHS=()

    # Search for node.socket in each directory
    for DIR in "${SEARCH_DIRS[@]}"; do
        if [[ -d "$DIR" ]]; then
            FIND_OUTPUT=$(find "$DIR" -maxdepth 4 -type s -name "$SOCKET_NAME" 2>/dev/null || true)
            if [[ -n "$FIND_OUTPUT" ]]; then
                while IFS= read -r LINE; do
                    FOUND_PATHS+=("$LINE")
                done <<< "$FIND_OUTPUT"
            fi
        fi
    done

    # Remove duplicates and clean up
    UNIQUE_PATHS=$(printf "%s\n" "${FOUND_PATHS[@]}" | sort -u | sed '/^$/d')

    # Handle cases based on the number of paths found
    if [[ -z "$UNIQUE_PATHS" ]]; then
        echo "No node.socket file detected in common directories."
        echo "If using a containerized Cardano-node, ensure the node.socket is accessible as a shared/mounted path."
        read -p "Enter the full path to your node.socket: " CUSTOM_PATH
        if [[ -S "$CUSTOM_PATH" ]]; then
            SOCKET_PATH="$CUSTOM_PATH"
            echo "Using custom node.socket path: $SOCKET_PATH"
            echo
        else
            echo "ERROR: The specified path is not a valid socket file. Please verify and try again."
            exit 1
        fi
        return
    fi

    # Single path found
    if [[ $(echo "$UNIQUE_PATHS" | wc -l) -eq 1 ]]; then
        SOCKET_PATH=$(echo "$UNIQUE_PATHS")
        echo "Found node.socket at: $SOCKET_PATH"
        read -p "Do you want to use this socket? (y/n): " RESPONSE
        if [[ "$RESPONSE" != "y" ]]; then
            read -p "Enter the full path to your node.socket: " CUSTOM_PATH
            if [[ -S "$CUSTOM_PATH" ]]; then
                SOCKET_PATH="$CUSTOM_PATH"
                echo "Using custom node.socket path: $SOCKET_PATH"
                echo
            else
                echo "ERROR: The specified path is not a valid socket file. Please verify and try again."
                exit 1
            fi
        fi
        echo "Using node.socket at: $SOCKET_PATH"
        return
    fi

    # Multiple paths found
    PS3="Select the correct node.socket path or specify a custom one: "
    OPTIONS=($(echo "$UNIQUE_PATHS") "Specify custom path")
    echo "Multiple node.socket files detected. Please select one from the list below:"
    select CHOICE in "${OPTIONS[@]}"; do
        case $CHOICE in
            "Specify custom path")
                read -p "Enter the full path to your node.socket: " CUSTOM_PATH
                if [[ -S "$CUSTOM_PATH" ]]; then
                    SOCKET_PATH="$CUSTOM_PATH"
                    echo "Using custom node.socket path: $SOCKET_PATH"
                    echo
                else
                    echo "ERROR: The specified path is not a valid socket file. Please verify and try again."
                    exit 1
                fi
                break
                ;;
            *)
                if [[ -n "$CHOICE" ]]; then
                    SOCKET_PATH="$CHOICE"
                    echo "Using node.socket at: $SOCKET_PATH"
                    echo
                else
                    echo "Invalid selection. Exiting."
                    exit 1
                fi
                break
                ;;
        esac
    done
}

# Port Management Function
manage_port() {
    local action=$1  # "check", "find", or "container" actions
    local port_range_start=$2
    local port_range_end=$3
    local specific_port=$4
    local container_name=$5

    case "$action" in
        check)
            # Check if a specific port is in use
            if [[ -z "$specific_port" ]]; then
                echo "ERROR: 'check' action requires a specific port." >&2
                exit 1
            fi
            if ss -tuln | grep -q ":$specific_port" || docker ps --format '{{.Ports}}' | grep -q ":$specific_port->"; then
                echo "true"
            else
                echo "false"
            fi
            ;;
        find)
            # Find the first available port in the given range
            if [[ -z "$port_range_start" || -z "$port_range_end" ]]; then
                echo "ERROR: 'find' action requires a port range." >&2
                exit 1
            fi
            for ((port=port_range_start; port<=port_range_end; port++)); do
                if [[ $(manage_port "check" "" "" "$port") == "false" ]]; then
                    echo "$port"
                    return
                fi
            done
            echo "ERROR: No available ports found in range $port_range_start-$port_range_end." >&2
            exit 1
            ;;
        container)
            # Retrieve the host port mapped to a container's internal port
            if [[ -z "$container_name" ]]; then
                echo "ERROR: Container name is required for 'container' action." >&2
                exit 1
            fi
            local mapped_port=$(docker inspect "$container_name" \
                --format "{{(index .NetworkSettings.Ports \"1337/tcp\" 0).HostPort}}" 2>/dev/null)
            if [[ -n "$mapped_port" ]]; then
                echo "$mapped_port"
            else
                echo "ERROR: Could not determine a valid port for container $container_name." >&2
                exit 1
            fi
            ;;
        *)
            echo "ERROR: Invalid action for manage_port. Use 'check', 'find', or 'container'." >&2
            exit 1
            ;;
    esac
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

# ------------------------
# Initialization Functions
# ------------------------

# Initialization Helper Functions (welcome, check_docker_group, get_node_choice_and_base_dir, install_dependencies)
welcome() {
    echo "Welcome to the Orcfax Node Suite by A4EVR!"
    echo
    echo "This script builds and deploys an Orcfax collector node, along with deploying and configuring cardano-node and Ogmios."
    echo
    echo "Steps include auto-detection and recommended defaults to streamline the process."
    echo
    echo "**Cardano-node Setup**"
    echo "   - Configures an existing cardano-node for Orcfax integration."
    echo "   - Optionally deploys a new node using a combined cardano-node + Ogmios container."
    echo "   - Provides an option to quickly bootstrap the database with Mithril."
    echo
    echo "**Ogmios Setup**"
    echo "   - Deploys a new Ogmios container or configures an existing instance."
    echo
    echo "**Orcfax Collector Node Setup**"
    echo "   - Automates the configuration and building of the Orcfax collector node as a container."
    echo
    echo "**Final Deployment**"
    echo "   - Generates and applies Docker Compose configurations to deploy all required containers."
    echo
    echo "**Estimated Completion Time**"
    echo "   - Using an existing cardano-node: <5 minutes."
    echo "   - Deploying a new cardano-node with Mithril bootstrapping: ~1 hour."
    echo
    echo "Please follow the prompts carefully. You can exit the script anytime by pressing Ctrl+C."
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

# Ask user to set cardano-node choice, set base directory, and create a node name
get_node_choice_and_base_dir() {
    echo "Choose your cardano-node setup:"
    echo "1. Use an existing cardano-node (local installation or container)."
    echo "2. Deploy a new cardano-node along with Ogmios as a combined container (cardano-ogmios)."
    read -p "Enter your choice (1/2): " NODE_CHOICE
    case "$NODE_CHOICE" in
        1)
            CARDANO_NODE_CHOICE="existing"
            echo "You have chosen to use an existing cardano-node setup."
            ;;
        2)
            CARDANO_NODE_CHOICE="new"
            echo "You have chosen to deploy a new cardano-node and Ogmios combined container."
            ;;
        *)
            echo "ERROR: Invalid choice. Please restart and select a valid option."
            exit 1
            ;;
    esac

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
    CARDANO_OGMIOS_CONTAINER="cardano_ogmios_$NODE_NAME"
    COMPOSE_FILE="$NODE_DIR/docker-compose.yml"
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

# ------------------------
# Cardano-node Setup Functions
# ------------------------

# Cardano-node setup helper functions
setup_cardano_db() {
    echo "Setting up Cardano database directory for the new node..."

    # Recommend a default shared volume path
    DEFAULT_DIR="/home/$USER/cardano-db"
    read -p "Use default directory for Cardano db ($DEFAULT_DIR)? (y/n): " DB_RESPONSE
    if [[ "$DB_RESPONSE" == "y" || -z "$DB_RESPONSE" ]]; then
        CARDANO_DB_DIR="$DEFAULT_DIR"
    else
        read -p "Enter your desired directory for the Cardano DB: " CUSTOM_DB_DIR
        CARDANO_DB_DIR=$(realpath "${CUSTOM_DB_DIR/#\~/$HOME}")
    fi

    # Check if the directory exists and is non-empty
    if [ -d "$CARDANO_DB_DIR" ] && [ "$(ls -A "$CARDANO_DB_DIR" 2>/dev/null)" ]; then
        echo "The directory $CARDANO_DB_DIR already exists and contains data."
        read -p "Do you want to use the existing database in this directory? (y/n): " USE_EXISTING_DB
        if [[ "$USE_EXISTING_DB" == "y" ]]; then
            echo "Using existing Cardano DB directory: $CARDANO_DB_DIR"
            return
        else
            manage_directory "$CARDANO_DB_DIR" "overwrite" "$USER:$USER" "700"
        fi
    else
        manage_directory "$CARDANO_DB_DIR" "create" "$USER:$USER" "700"
    fi

    # Check available disk space
    REQUIRED_SPACE=$((300 * 1024 * 1024)) # 300GB in kilobytes
    AVAILABLE_SPACE=$(/bin/df "$CARDANO_DB_DIR" --output=avail 2>/dev/null | /usr/bin/tail -n 1)

    if [[ -z "$AVAILABLE_SPACE" || "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]]; then
        echo "ERROR: Insufficient disk space. At least 300GB is required."
        echo "Available space: $((AVAILABLE_SPACE / 1024)) MB"
        exit 1
    fi

    echo "Cardano DB directory has been set up at $CARDANO_DB_DIR with ownership and permissions configured."
    echo
}

setup_mithril() {
    echo "Setting up Mithril container for fast Cardano database bootstrapping..."

    if ! confirm "Do you want to proceed with Mithril?"; then
        echo "Skipping Mithril."
        echo
        return
    fi

    # Fetch Genesis Verification Key
    GENESIS_VERIFICATION_KEY=$(wget -q -O - "$GENESIS_KEY_URL")
    if [[ -z "$GENESIS_VERIFICATION_KEY" ]]; then
        echo "ERROR: Failed to fetch Genesis Verification Key from $GENESIS_KEY_URL."
        exit 1
    fi

    # Check if the DB directory contains data
    if [ "$(ls -A "$CARDANO_DB_DIR" 2>/dev/null)" ]; then
        CURRENT_DB_SIZE_MB=$(du -sm "$CARDANO_DB_DIR" | awk '{print $1}' || echo 0)
        if [[ "$CURRENT_DB_SIZE_MB" -ge 100000 ]]; then
            echo "DB appears to have significant data already (size: $((CURRENT_DB_SIZE_MB / 1024)) GB). Skipping Mithril."
            echo
            return
        else
            echo "DB directory has data but is less than 100GB. Preparing for Mithril unpacking..."

            # Define Mithril container name here since process will proceed
            MITHRIL_CONTAINER_NAME="mithril-client"

            # Check and clean up existing Mithril client
            manage_container "$MITHRIL_CONTAINER_NAME" "remove"

            # Clear the directory to prepare for Mithril unpacking
            manage_directory "$CARDANO_DB_DIR" "overwrite"
        fi
    else
        echo "DB directory is empty. Proceeding with Mithril setup..."
    fi

    # Fetch snapshot list and select the latest snapshot
    echo "Fetching the latest snapshot list from the Mithril Aggregator..."
    RAW_OUTPUT=$(docker run --rm \
        -e AGGREGATOR_ENDPOINT="$AGGREGATOR_ENDPOINT" \
        "$MITHRIL_DOCKER_IMAGE" cardano-db snapshot list)

    local LATEST_SNAPSHOT
    LATEST_SNAPSHOT=$(echo "$RAW_OUTPUT" | tr -d '\r' | grep -oE '[0-9a-f]{64}' | head -n 1)

    if [[ -z "$LATEST_SNAPSHOT" ]]; then
        echo "ERROR: Unable to extract snapshot digest. Check raw output for details."
        echo "Raw output: $RAW_OUTPUT"
        exit 1
    fi

    echo "Latest Snapshot Digest: $LATEST_SNAPSHOT"

    if ! confirm "Do you want to proceed with this snapshot?"; then
        echo "Aborted by user. Exiting."
        exit 0
    fi

    echo "Starting the snapshot download and then unpacking, this may take a while..."
    deploy_container "$MITHRIL_CONTAINER_NAME" "$MITHRIL_DOCKER_IMAGE" \
        "" \
        "-v $CARDANO_DB_DIR:/app/db" \
        "-e GENESIS_VERIFICATION_KEY=$GENESIS_VERIFICATION_KEY -e AGGREGATOR_ENDPOINT=$AGGREGATOR_ENDPOINT"

    # Monitor progress and wait for the container to stop
    echo
    TOTAL_DB_SIZE_MB=$((205 * 1024)) # 205 GB aribtrary value used to estimate/display progress of Mithril

    while docker ps --format '{{.Names}}' | grep -q "$MITHRIL_CONTAINER_NAME"; do
        CURRENT_SIZE_MB=$(du -sm "$CARDANO_DB_DIR" | awk '{print $1}' || echo 0)

        # Calculate percentage
        PERCENTAGE=$((CURRENT_SIZE_MB * 100 / TOTAL_DB_SIZE_MB))
        PERCENTAGE=$((PERCENTAGE > 100 ? 100 : PERCENTAGE)) # Clamp to 0-100

        # Display approximate progress
        printf "\r*Approximate* Progress: %3d%%" "$PERCENTAGE"

        sleep 5
    done
    echo

    # Validate container logs for success
    if docker logs "$MITHRIL_CONTAINER_NAME" | grep -q "successfully checked against Mithril multi-signature"; then
        echo "Mithril snapshot successfully downloaded, verified, and applied."
        echo
    else
        echo "ERROR: Mithril snapshot process failed or did not complete as expected."
        docker logs "$MITHRIL_CONTAINER_NAME"
        exit 1
    fi
}

# Helper Functions for cardano-ogmios container deployment
run_cardano_ogmios_container() {
    local container_name=$1
    local relay_port=$2
    local db_volume=$3
    local ipc_dir=$4
    local ekg_port=$5
    local prometheus_port=$6

    # Ensure all variables are set
    if [[ -z "$container_name" || -z "$relay_port" || -z "$OGMIOS_PORT" || -z "$db_volume" || -z "$ipc_dir" || -z "$ekg_port" || -z "$prometheus_port" ]]; then
        echo "ERROR: One or more required variables are unset. Exiting."
        exit 1
    fi

    # Prepare IPC directory for cardano db so it persists on container restarts
    manage_directory "$ipc_dir" "create" "$(id -u):$(id -g)" "700"

    # Pull the latest Cardano-Ogmios image
    echo "Pulling the latest Cardano-Ogmios image ($CARDANO_OGMIOS_IMAGE)..."
    if ! docker pull "$CARDANO_OGMIOS_IMAGE"; then
        echo "ERROR: Failed to pull the latest Cardano-Ogmios image. Exiting."
        exit 1
    fi

    # Clean up existing socket for new cardano-node instance
    if [ -e "$ipc_dir/node.socket" ]; then
        echo "Cleaning up existing node.socket..."
        sudo rm -rf "$ipc_dir/node.socket"
    fi

    # Deploy container
    deploy_container "$container_name" "$CARDANO_OGMIOS_IMAGE" \
        "-p $OGMIOS_PORT:1337 -p $relay_port:3000 -p $ekg_port:12788 -p $prometheus_port:12798" \
        "-v $db_volume:/db -v $ipc_dir:/ipc" ""

    # Verify container is running
    if ! manage_container "$container_name" "running"; then
        echo "ERROR: Failed to start container $container_name. Exiting."
        exit 1
    fi
}

wait_for_socket() {
    local socket_path=$1
    local timeout=$2

    echo "Waiting for socket $socket_path to be created, this may take a few minutes..."
    local elapsed=0

    while [ ! -S "$socket_path" ]; do
	sleep 10
	elapsed=$((elapsed + 10))
	if [ "$elapsed" -ge "$timeout" ]; then
	    echo "ERROR: Timeout waiting for $socket_path."
	    exit 1
	fi
	echo "Still waiting for socket..."
    done

    echo "$socket_path is ready."
    echo
}

# Main Cardano-ogmios Container Deployment Function
deploy_cardano_ogmios_container() {
    echo "Deploying a new Cardano-node + Ogmios combined container..."

    # Construct a unique container name and set variable
    if [[ -z "$CARDANO_OGMIOS_CONTAINER" ]]; then
        CARDANO_OGMIOS_CONTAINER="cardano_ogmios_$NODE_NAME"
    fi

    # Ensure variables are set
    if [[ -z "$CARDANO_DB_VOLUME" ]]; then
        CARDANO_DB_VOLUME=$(basename "$CARDANO_DB_DIR")
    fi

    if [[ -z "$CARDANO_IPC_DIR" ]]; then
        CARDANO_IPC_DIR="$CARDANO_DB_DIR/ipc"
    fi

    # Find available ports
    local relay_port
    local ekg_port
    local prometheus_port

    relay_port=$(manage_port "find" 3000 3100)
    OGMIOS_PORT=$(manage_port "find" 1337 1350)  # Set the global OGMIOS_PORT variable
    ekg_port=$(manage_port "find" 12788 12800)
    prometheus_port=$(manage_port "find" 12798 12810)

    # Handle container conflicts
    manage_container "$CARDANO_OGMIOS_CONTAINER" "remove"

    # Delegate to run_cardano_ogmios_container
    run_cardano_ogmios_container "$CARDANO_OGMIOS_CONTAINER" "$relay_port" "$CARDANO_DB_VOLUME" "$CARDANO_IPC_DIR" "$ekg_port" "$prometheus_port"

    # Set this container as the active Ogmios container
    ACTIVE_OGMIOS_CONTAINER="$CARDANO_OGMIOS_CONTAINER"

    # Wait for the socket to be ready
    wait_for_socket "$CARDANO_IPC_DIR/node.socket" 600

    # Set the global SOCKET_PATH variable
    SOCKET_PATH="$CARDANO_IPC_DIR/node.socket"
}

#Top-Level Function for cardano-node setup (configure existing node or deploy new cardano-node/ogmios container)
setup_cardano_node() {
    echo -e "\033[1;32m#### Cardano-node setup ####\033[0m"
    echo

    if [[ "$CARDANO_NODE_CHOICE" == "existing" ]]; then
        detect_node_socket
        echo "Existing cardano-node configured successfully."
        echo
    else
        setup_cardano_db
        setup_mithril
        deploy_cardano_ogmios_container
        echo "New $CARDANO_OGMIOS_CONTAINER container successfully deployed."
        echo
    fi
}

# ------------------------
# Ogmios Setup Functions
# ------------------------

# Helper Functions for Ogmios setup
handle_ogmios_containers() {
    local ogmios_containers=("$@")

    echo "Detected the following Ogmios container(s):"
    display_containers "${ogmios_containers[@]}"

    PS3="Choose an action: "
    options=("Re-use an existing Ogmios instance" "Deploy a new standalone Ogmios instance" "Specify a custom Ogmios endpoint")
    select opt in "${options[@]}"; do
        case $opt in
            "Re-use an existing Ogmios instance")
                deploy_or_reuse_instance "${ogmios_containers[@]}"
                return
                ;;
            "Deploy a new standalone Ogmios instance")
                prepare_standalone_ogmios
                return
                ;;
            "Specify a custom Ogmios endpoint")
                prompt_custom_endpoint
                return
                ;;
            *)
                echo "Invalid option. Please try again."
                ;;
        esac
    done
}

deploy_or_reuse_instance() {
    local ogmios_containers=("$@")

    PS3="Select the container to use (e.g., 1): "
    select container in "${ogmios_containers[@]}"; do
        if [[ -n "$container" ]]; then
            ACTIVE_OGMIOS_CONTAINER="$container"
            OGMIOS_PORT=$(manage_port container "" "" "" "$ACTIVE_OGMIOS_CONTAINER")
            OGMIOS_URL="ws://localhost:${OGMIOS_PORT}"
            echo "Using existing Ogmios container: $ACTIVE_OGMIOS_CONTAINER on $OGMIOS_URL."
            echo
            return
        else
            echo "Invalid selection. Try again."
        fi
    done
}

prompt_custom_endpoint() {
    read -p "Enter the full Ogmios endpoint (e.g., ws://localhost:1337): " OGMIOS_URL
    echo "Using custom Ogmios endpoint: $OGMIOS_URL and skipping container setup."
    echo
    ACTIVE_OGMIOS_CONTAINER=""
}

prepare_standalone_ogmios() {
    STANDALONE_OGMIOS_CONTAINER="ogmios_$NODE_NAME"

    # Handle container conflicts
    manage_container "$STANDALONE_OGMIOS_CONTAINER" "remove"

    # Assign an available port for the new Ogmios instance
    OGMIOS_PORT=$(manage_port find 1337 1350)
    OGMIOS_URL="ws://localhost:${OGMIOS_PORT}"

    echo "Standalone Ogmios container will be created in final deployment."
    ACTIVE_OGMIOS_CONTAINER="$STANDALONE_OGMIOS_CONTAINER"
    echo
}

display_containers() {
    local containers=("$@")
    for i in "${!containers[@]}"; do
        if [[ -n "${containers[i]}" ]]; then
            echo "$((i + 1))) ${containers[i]}"
        fi
    done
    echo
}

# Top-Level Function (configure existing Ogmios instance or create a new instance)
setup_ogmios() {
    echo -e "\033[1;32m#### Ogmios Setup ####\033[0m"
    echo

    if [[ "$CARDANO_NODE_CHOICE" == "new" ]]; then
        echo "New Cardano-Ogmios container will be deployed. Skipping Ogmios setup."
        ACTIVE_OGMIOS_CONTAINER="$CARDANO_OGMIOS_CONTAINER"
        OGMIOS_PORT=$(manage_port container "" "" "" "$ACTIVE_OGMIOS_CONTAINER")
        OGMIOS_URL="ws://localhost:${OGMIOS_PORT}"
        echo "Using Ogmios instance within $ACTIVE_OGMIOS_CONTAINER on $OGMIOS_URL."
        echo
        return
    fi

    # Detect existing Ogmios containers
    local ogmios_containers
    ogmios_containers=($(docker ps --filter "name=ogmios" --format "{{.Names}}" | sed '/^$/d'))

    if [[ ${#ogmios_containers[@]} -eq 0 ]]; then
        echo "No Ogmios containers found. You can create a new instance or enter a custom endpoint."
        if confirm "Do you want to deploy a new standalone Ogmios instance?"; then
            prepare_standalone_ogmios
        else
            prompt_custom_endpoint
        fi
    else
        handle_ogmios_containers "${ogmios_containers[@]}"
    fi
}

# ------------------------
# Orcfax Collector Setup Functions
# ------------------------

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
}

# ------------------------
# Final Deployment Functions
# -----------------------

generate_docker_compose() {
    echo "Creating docker-compose.yml for $NODE_NAME..."

    # Generate configuration based on Ogmios setup
    if [[ -z "$STANDALONE_OGMIOS_CONTAINER" ]]; then
        # No standalone Ogmios service included (custom endpoint or existing container reused)
        cat > "$COMPOSE_FILE" <<EOL
services:
  orcfax_collector:
    build:
      context: ${NODE_DIR}
    image: ${ORCFAX_IMAGE_NAME}
    container_name: ${ORCFAX_CONTAINER_NAME}
    environment:
      - OGMIOS_URL=${OGMIOS_URL}
    restart: unless-stopped
EOL
    else
        # Include standalone Ogmios service in the Docker Compose file
        SOCKET_BINDING="$SOCKET_PATH:/ipc/node.socket"
        cat > "$COMPOSE_FILE" <<EOL
services:
  ogmios:
    image: ${STANDALONE_OGMIOS_IMAGE}
    container_name: ${STANDALONE_OGMIOS_CONTAINER}
    ports:
      - "${OGMIOS_PORT}:1337"
    volumes:
      - ${SOCKET_BINDING}
    command:
        - --node-socket=/ipc/node.socket
        - --node-config=/config/mainnet/cardano-node/config.json
        - --host=0.0.0.0
        - --port=${OGMIOS_PORT}
    restart: unless-stopped

  orcfax_collector:
    build:
      context: ${NODE_DIR}
    image: ${ORCFAX_IMAGE_NAME}
    container_name: ${ORCFAX_CONTAINER_NAME}
    depends_on:
      - ogmios
    environment:
      - OGMIOS_URL=${OGMIOS_URL}
    restart: unless-stopped
EOL
    fi

    echo "docker-compose.yml successfully created at $COMPOSE_FILE."
    echo
}

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

run_docker_compose() {
    echo "Starting containers using Docker Compose..."

    # Start the Docker Compose process
    if ! docker compose -f "$COMPOSE_FILE" up -d; then
        echo "ERROR: Failed to start Docker containers with Docker Compose. Exiting."
        exit 1
    fi

    echo "Docker Compose started successfully. Verifying containers..."
    local CONTAINERS=("${ORCFAX_CONTAINER_NAME}")

    # Add Ogmios container only if it's a standalone deployment managed by the script
    if [[ -n "$STANDALONE_OGMIOS_CONTAINER" ]]; then
        CONTAINERS+=("${STANDALONE_OGMIOS_CONTAINER}")
    fi

    # Verify that all required containers are running
    for CONTAINER in "${CONTAINERS[@]}"; do
        if ! manage_container "$CONTAINER" "running"; then
            echo "ERROR: Container $CONTAINER is not running or failed to start. Check logs."
            exit 1
        fi
    done

    echo "Container verification completed."
    echo
}

# Top-Level Function to deploy containers and finalize the setup
final_deployment() {
    echo -e "\033[1;32m#### Final orchestration and deployment ####\033[0m"
    echo
    generate_docker_compose
    build_orcfax_image
    run_docker_compose
}

# ------------------------
# Final Logging and Notes Functions
# -----------------------

write_log_file() {
    LOG_FILE="$BASE_DIR/$NODE_NAME-config.log"

    {
        echo "# Orcfax Node Deployment Configuration Log"
        echo "# This log file was generated automatically by the Orcfax Node Deployment script."
        echo ""

        echo "# Configuration Variables:"
        for var in CARDANO_NODE_CHOICE BASE_DIR NODE_NAME NODE_DIR KEYS_DIR SOCKET_PATH \
                   ORCFAX_IMAGE_NAME ORCFAX_CONTAINER_NAME STANDALONE_OGMIOS_CONTAINER \
                   OGMIOS_URL CARDANO_OGMIOS_CONTAINER ACTIVE_OGMIOS_CONTAINER \
                   CARDANO_DB_DIR CARDANO_IPC_DIR OGMIOS_PORT COMPOSE_FILE \
                   COLLECTOR_WHL_URL CER_FEEDS_URL GOFER_URL \
                   STANDALONE_OGMIOS_IMAGE CARDANO_OGMIOS_IMAGE MITHRIL_DOCKER_IMAGE \
                   AGGREGATOR_ENDPOINT GENESIS_KEY_URL; do
            echo "$var=\"${!var}\""
        done

        echo ""
        echo "# Useful Commands"
        echo "## Verify containers:"
        echo "docker ps -a"
        echo "docker stats"
        echo ""
        echo "## Verify processes:"
        echo "docker exec -it $ORCFAX_CONTAINER_NAME ps aux"
        echo "docker top $ACTIVE_OGMIOS_CONTAINER"
        echo ""
        echo "## Verify cron in the collector node ($ORCFAX_CONTAINER_NAME):"
        echo "docker exec -it $ORCFAX_CONTAINER_NAME ps aux | grep cron"
        echo "docker exec -it $ORCFAX_CONTAINER_NAME tail -f /var/log/cron.log"
        echo ""
        echo "## Display collector log (tailing the log):"
        echo "docker exec -it $ORCFAX_CONTAINER_NAME tail -f /var/log/collector_node.log"
        echo ""
        echo "Health check details for Orcfax collector container:"
        echo "  - Ensures the 'collector-node' process is running."
        echo "  - Confirms the '.node-identity.json' file exists in '/tmp'."
        echo ""
        echo "## Verify Ogmios is active and connected to cardano-node:"
        echo "curl -H 'Accept: application/json' $OGMIOS_URL/health | jq"
        echo "View in browser: $OGMIOS_URL"
        echo ""
        echo "## Review and remove unused Docker images"
        echo "docker images"
        echo "docker image prune -a"
        echo ""

        if [[ "$CARDANO_NODE_CHOICE" == "new" ]]; then
            echo "## Cardano-node System Commands:"
            echo "docker logs -f $ACTIVE_OGMIOS_CONTAINER"
        fi
    } > "$LOG_FILE"

    # Check if the log file was created
    if [ -f "$LOG_FILE" ]; then
        echo "Deployment config log successfully created."
        echo
    else
        echo "ERROR: Failed to create log file at $LOG_FILE."
        exit 1
    fi
}

display_final_notes() {
    echo -e "\033[1;32m#### Full deployment is now complete! ####\033[0m"
    echo
    echo "Docker containers $ACTIVE_OGMIOS_CONTAINER -- $ORCFAX_CONTAINER_NAME are running with restart policy 'unless-stopped'."
    echo
    echo "Summary config log created at $LOG_FILE."
    echo
    echo "You can try the following checks to ensure everything is working properly, allow ~1 minute for initialization:"
    echo
    sed -n '/## Verify containers:/,$p' "$LOG_FILE"
    echo
    echo "Happy collecting!"
    echo
}

# Top-Level Function for for final config log and notes
final_logging() {
    echo -e "\033[1;32m#### Generating deployment logs and final notes ####\033[0m"
    echo
    write_log_file
    display_final_notes
}


# ------------------------
# Main Execution
# ------------------------

# Step 1: Set up the environment and check dependencies
setup_environment

# Step 2: Set up cardano-node (configure existing node or deploy new cardano-node/ogmios container)
setup_cardano_node

# Step 3: Set up Ogmios interface (configure existing instance or deploy new standalone container)
setup_ogmios

# Step 4: Prepare and configure the Orcfax collector node
setup_orcfax_collector

# Step 5: Deploy containers and finalize the setup
final_deployment

# Step 6: Generate logs and display deployment notes
final_logging


