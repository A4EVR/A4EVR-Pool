# Orcfax Node Suite by A4EVR

The Orcfax Node Suite is a simple all-in-one solution designed to quickly deploy an Orcfax collector node along with its required backend services: `cardano-node` and `Ogmios`.

## Features

### Cardano-node
- Configures an existing `cardano-node` for Orcfax integration.
- Optionally deploys a new node using a combined cardano-node + Ogmios container. Supports fast database bootstrapping with `Mithril`.

### Ogmios
- Creates a new Ogmios container or configures an existing instance.

### Orcfax Collector
- Downloads required files (`collector-node`, `gofer`, `cer-feeds.json`).
- Generates `node.env` and dummy database file (`notused.db`).
- Generates a `Dockerfile` and an entrypoint script `start.sh`.
- Builds Docker container image.

### Deployment
- Uses Docker Compose to configure and link services:

`Cardano-node`

`Ogmios`

`Orcfax collector` 

- Deploys and starts all services.

### Estimated Completion Time
- Using an existing cardano-node: <5 minutes.
- Deploying a new cardano-node with Mithril bootstrapping: ~1 hour.

## Prerequisites

- Alias payment keys (`payment.skey` and `payment.vkey`) must be pre-generated and accessible.
- If deploying new cardano-node: 32GB RAM and 300GB free storage.

## Usage

1. Download the `orcfax_node_suite` script:
    ```bash
    wget https://raw.githubusercontent.com/A4EVR/A4EVR-Pool/main/orcfax/node-suite/orcfax_node_suite.sh
    ```

2. Make the script executable:
    ```bash
    chmod +x orcfax_node_suite
    ```

3. Run the script:
    ```bash
    ./orcfax_node_suite
    ```
    
4. Follow the terminal prompts to:
    
    Initial Setup:
    
    Provide a unique node name (e.g., `node1`). Choose base directory (e.g., `~/orcfax`). This will make a directory `~/orcfax/<your-node-name>`.

    Cardano-node Setup:
    
    Choose to configure an existing `cardano-node`. Select the detected `node.socket` path or enter an existing path.
    Or optionally deploy a new cardano-node using a `CARDANO_OGMIOS_CONTAINER`. Enter an existing `cardano db` path or use Mithril to fast bootstrap the database.
    
    Ogmios Setup:
    
    Choose to deploy a new `STANDALONE_OGMIOS_CONTAINER` or configure an existing instance.

    Orcfax Collector Node Setup:
    
    Specify the directory containing your alias keys. This will copy the keys to a newly created `signing-key` folder.

## Additional Notes

Upon completion, a summary config log and helpful commands are outputted in the node directory (e.g., ~/orcfax/<node-name>)

## Changelog

v1.0.0:
Initial release of Orcfax Node Suite script. Includes support for Cardano-node, Ogmios, and the Orcfax collector.


## Happy Collecting!
