# Orcfax ITN1 Monitoring and Metrics Script

### orcfax_metrics_log.py
**Purpose**: 
  - Automates the creation of a log file for the Orcfax ITN1 collector node if one does not exist. 
  - Analyzes the log file to provide performance metrics, such as:
    - Total run attempts
    - Success rate
    - Mean and median durations
    - Allows processing of the entire log or just the last `n` hours for performance analysis
**Log Behavior**:
  - The script generates a log file by appending Orcfax collector data from `/var/log/syslog`.
  - The log file grows over time as new data is appended.
  - The script assumes the Orcfax collector is running and logging events to /var/log/syslog
  - If no log data is present initially, allow some time for the collector to generate data before running the script again

### Recommended Setup
1. Place the script in the `~/orcfax` directory:
   ```bash
    mkdir -p ~/orcfax
    cd ~/orcfax
    wget https://github.com/A4EVR/A4EVR-Pool/blob/main/orcfax/monitoring/orcfax_metrics_log.py -O orcfax_metrics_log.py
2. Run the Script with Sudo:
   ```bash
    sudo python3 orcfax_metrics_log.py

