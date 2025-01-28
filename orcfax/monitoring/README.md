# Orcfax Exporter Setup Guide
## Orcfax Collector version 2.0.1-rc.1

This document covers:

- Prometheus & Grafana installation.
- Orcfax Exporter installation & systemd service config.
- Orcfax ITN Dashboard implementation.
    

## 1. Install Prometheus & Grafana

Install Prometheus

    sudo apt update
    sudo apt install -y prometheus


Once installed, Prometheus typically runs as a systemd service:
    /lib/systemd/system/prometheus.service

By default, it listens on port 9090.
Check status with:

    systemctl status prometheus


Install Grafana

    sudo apt update
    sudo apt install -y grafana

   
Start & enable it at boot:

    sudo systemctl enable grafana-server
    sudo systemctl start grafana-server


Check status:

    systemctl status grafana-server


## 2. Configure Prometheus

Prometheus stores its config in `/etc/prometheus/prometheus.yml`. 

    sudo nano /etc/prometheus/prometheus.yml

There is one scrape_configs section that lists all jobs. If a fresh install, you’ll see something like:

```bash
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
```

Add the Orcfax Exporter Job

If you already have other jobs, just add the new one under the same list.
Append (under the same scrape_configs: key) an additional job:

```bash
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'orcfax_exporter'
    static_configs:
      - targets: ['localhost:9101']
```


If your exporter will run on a remote machine, you can replace 'localhost:9101' with e.g. '192.168.1.10:9101'.

Restart Prometheus:

    sudo systemctl restart prometheus


## 3. Download & Configure the Orcfax Exporter

Download the Exporter Script

    mkdir -p ~/orcfax
    cd ~/orcfax
    wget https://raw.githubusercontent.com/A4EVR/A4EVR-Pool/refs/heads/main/orcfax/monitoring/orcfax_exporter.py
    chmod +x orcfax_exporter.py


Install Python

    sudo apt install -y python3 python3-venv python3-pip


Create Python Virtual Env

    python3 -m venv orcfax_env
    source orcfax_env/bin/activate
    pip install prometheus_client
    deactivate


## 4. Run Orcfax Exporter as a Systemd Service

Create systemd config file

    sudo nano /etc/systemd/system/orcfax_exporter.service


Copy below into the service file (replace <your_user> and license number <001>):

```bash
[Unit]
Description=Orcfax Exporter
After=network.target

[Service]
Type=simple
User=<your_user>
WorkingDirectory=/home/<your_user>
ExecStart=/home/<your_user>/orcfax_env/bin/python /home/<your_user>/orcfax/orcfax_exporter.py \
    --licenses <001> \
    --log-paths /var/log/syslog \
    --port 9101
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

- Flag format for 1 license and log path:

--licenses 001: Single license number.
--log-paths /var/log/syslog: Local logs.
    

- Format for multiple licenses on same local host (comma separate licenses and log paths):

--licenses 001,002
--log-paths /var/log/syslog,/var/log/syslog


- Or if one license is Docker-based:

--licenses 001,002
--log-paths /var/log/syslog,/var/log/docker/orcfax_<node_name>/collector_node.log


Enable & Start the Exporter

    sudo systemctl daemon-reload
    sudo systemctl enable orcfax_exporter
    sudo systemctl start orcfax_exporter


Check status:

    systemctl status orcfax_exporter


The exporter now listens on port 9101.


## 5. Configure & Use Grafana

Start Grafana & Add Prometheus Data Source

    sudo systemctl enable grafana-server
    sudo systemctl start grafana-server

Grafana listens on port 3000. Visit:
    
    http://localhost:3000

Default credentials: admin/admin.

Go to: Configuration > Data Sources > Add data source > Prometheus.
    


Get and Import the Orcfax ITN Dashboard

    cd ~/orcfax
    wget https://raw.githubusercontent.com/A4EVR/A4EVR-Pool/refs/heads/main/orcfax/monitoring/Orcfax-ITN-A4EVR.json


In Grafana, go to Dashboard > Import.
Upload or paste the JSON dashboard, select Prometheus data source.


## 6. Verification & Notes

Verifying Locally

Open `http://localhost:9090/targets` in Prometheus UI.
You should see orcfax_exporter as UP.
    
Metrics shown at `http://localhost:9101/metrics`.


Remote Machines & Secure Access

If you want to centralize data from multiple remote machines, each runs its own Orcfax Exporter.
Prometheus can scrape them all by adding each IP to static_configs.
Optionally secure it with a VPN or tunneling (e.g., WireGuard).

Docker-based Orcfax Node

If your collector node logs are in /var/log/docker/orcfax_<node_name>/collector_node.log, pass that path to --log-paths

Ensure your host or container is writing logs to that path and that it is mounted for exporter to parse.

## Conclusion

Prometheus (port 9090) + Grafana (port 3000) installed & running and services.
Orcfax Exporter (port 9101) running as a service.
Grafana uses Prometheus metrics data to visualize Orcfax metrics.


### Happy monitoring!