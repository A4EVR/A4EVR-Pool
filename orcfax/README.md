# Orcfax Node Deployment Script

This script automates the setup and deployment of a containerized Orcfax ITN Phase 1 node. It downloads required components, generates and configures files/environment variables, and deploys the container node. From start to finish, the node will be operational in about 1-2 minutes.

## Features

- Downloads all required files (collector-node, gofer, cer-feeds.json).
- Automatically generates the necessary `node.env` configuration file.
- Creates a dummy database file (`notused.db`).

## Prerequisites

- Payment keys (`payment.skey` and `payment.vkey`) already generated and accessible.

## Usage

1. Download the create_orcfax_node script:
    ```bash
   wget https://raw.githubusercontent.com/A4EVR/A4EVR-Pool/main/orcfax/create_orcfax_node.sh
   
2. Make the script executable: 
    ```bash
   chmod +x create_orcfax_node.sh
   
3. Run the script: 
 ```bash
   ./create_orcfax_node.sh
