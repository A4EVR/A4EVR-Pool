# Orcfax ITN1 Monitoring and Metrics Script

### orcfax_metrics_log.py

**Purpose** 

The script serves two functions:

1. Log Creation:
    Automatically creates a log file for the Orcfax ITN1 collector node if one does not already exist.
    Appends Orcfax collector data from /var/log/syslog to the new log file.
    
2. Performance Analysis- key metrics from the log including:
  - Total run attempts
  - Success rate
  - Mean and median durations
  - Allows users to process the entire log or the last n hours for targeted analysis.
    
**Log Behavior**

  - The script generates a log file by appending Orcfax collector data from `/var/log/syslog`.
  - The log file grows over time as new data is appended.
  - The script assumes the Orcfax collector is running and logging events to /var/log/syslog
  - If no log data is present initially, allow some time for the collector to generate data before running the script again
  - The script will generate the log file orcfax_collector.log in the ~/orcfax directory if it does not already exist.
  - The log file will grow continuously. Consider rotating or archiving the log periodically if it becomes too large.
  
### Recommended Setup
1. Download the script in the `~/orcfax` directory:
   ```bash
    mkdir -p ~/orcfax
    cd ~/orcfax
    wget https://github.com/A4EVR/A4EVR-Pool/blob/main/orcfax/monitoring/orcfax_metrics_log.py -O orcfax_metrics_log.py
2. Run the Script with Sudo:
   ```bash
    sudo python3 orcfax_metrics_log.py

