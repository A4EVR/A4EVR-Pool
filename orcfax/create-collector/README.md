# Orcfax Node Deployment Script

This script automates the setup and deployment of a containerized Orcfax ITN Phase 1 node. It downloads required components, generates and configures files/environment variables, and deploys the container node. 

From start to finish, the node should be operational in about 1-2 minutes.

## Features

- Downloads all required files (`collector-node`, `gofer`, `cer-feeds.json`).
- Generates `node.env` and dummy database file (`notused.db`).
- Generates a `Dockerfile` and an entrypoint script `start.sh`.
- Builds Docker container image, deploys, and starts the collector node.

## Prerequisites

- Payment keys (`payment.skey` and `payment.vkey`) must be pre-generated and accessible.

## Usage

1. Download the `create_orcfax_node` script:
    ```bash
    wget https://raw.githubusercontent.com/A4EVR/A4EVR-Pool/main/orcfax/create-collector/create_orcfax_node.sh
    ```

2. Make the script executable:
    ```bash
    chmod +x create_orcfax_node.sh
    ```

3. Run the script:
    ```bash
    ./create_orcfax_node.sh
    ```

4. Follow the terminal prompts to:

    Provide a unique node name (e.g., `node1`). This will make a directory `~/orcfax/<your-node-name>`.
    
    Specify the directory containing your payment keys. This will copy the keys to a newly created `signing-key` folder.


## Happy Collecting!
