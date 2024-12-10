# orcfax collector log metrics ITN1 - created by A4EVR

import re
import os
import subprocess
from datetime import datetime, timedelta

def ensure_log_file_exists():
    """Check for log file, and prompt user to enter a path or create a new one."""
    default_log_file = os.path.join(os.getcwd(), "orcfax_collector.log")
    
    if os.path.exists(default_log_file):
        print(f"Log file found: {default_log_file}")
        return default_log_file

    print("orcfax_collector.log does not exist in this directory.")
    user_choice = input("Enter the path to an existing log file or type 'new' to create a new log file: ").strip()

    # Expand ~ based on the invoking user's home directory
    invoking_user_home = os.path.expanduser("~" + os.getenv("SUDO_USER", ""))
    user_choice_expanded = os.path.expanduser(user_choice).replace("/root", invoking_user_home)

    if user_choice.lower() == 'new':
        log_dir = os.path.join(invoking_user_home, "orcfax")
        log_file_path = os.path.join(log_dir, "orcfax_collector.log")
        
        if not os.path.exists(log_dir):
            os.makedirs(log_dir)
            print(f"Created directory: {log_dir}")

        if not os.path.exists(log_file_path):
            print("Creating a new log file and starting log collection...")
            # Start log collection
            collection_command = f"nohup sudo tail -f /var/log/syslog | grep 'orcfax_collector' >> {log_file_path} &"
            subprocess.Popen(collection_command, shell=True)
            print(f"Started log collection. Logs will be saved to: {log_file_path}")
            print("The log is newly created. Allow some time for it to collect data before running this script again.")
            exit()
        else:
            print(f"Log file already exists: {log_file_path}")
        return log_file_path
    else:
        if not os.path.exists(user_choice_expanded):
            print(f"The specified log file does not exist: {user_choice_expanded}. Exiting.")
            exit()
        return user_choice_expanded

def process_log_file(log_file_path, hours=None):
    with open(log_file_path, 'r') as file:
        log_data = file.readlines()

    if not log_data:
        print("Log file is empty. Allow some time for the log to collect data and try again.")
        return

    # Extract timestamps from the log file
    timestamps = [re.search(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', line).group() for line in log_data if re.search(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', line)]
    if not timestamps:
        print("No valid log entries found. Allow more time for the log to collect data and try again.")
        return

    # Determine start and end times
    start_time = datetime.fromisoformat(timestamps[0])
    end_time = datetime.fromisoformat(timestamps[-1])
    total_hours = (end_time - start_time).total_seconds() // 3600

    # Filter log lines within the specified time range
    if hours is not None:
        start_time_limit = end_time - timedelta(hours=hours)
        log_data = [
            line for line in log_data
            if re.search(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', line) and
            datetime.fromisoformat(re.search(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', line).group()) >= start_time_limit
        ]
        print(f"Processing the last {hours} hours of the log file.")
    else:
        print("Processing the entire log file.")

    # Count total run attempts
    run_attempts = len([line for line in log_data if "acquiring collector node lock" in line])

    # Extract durations
    duration_lines = [line for line in log_data if "completed after:" in line]
    durations = [float(re.search(r"completed after: '([\d.]+)' seconds", line).group(1)) for line in duration_lines]

    # Calculate stats
    total_successful_runs = len(durations)
    success_rate = (total_successful_runs / run_attempts) * 100 if run_attempts else 0
    mean_duration = sum(durations) / total_successful_runs if total_successful_runs else 0
    median_duration = sorted(durations)[total_successful_runs // 2] if total_successful_runs % 2 == 1 else \
        (sorted(durations)[(total_successful_runs // 2) - 1] + sorted(durations)[total_successful_runs // 2]) / 2
    runs_under_15_seconds = len([duration for duration in durations if duration < 15])

    # Output results
    print(f"Log Start time: {start_time}")
    print(f"Log End time: {end_time}")
    print(f"Total hours in the log: {int(total_hours)}")
    print(f"Total run attempts (should be max 1/min): {run_attempts}")
    print(f"Total successful collection runs: {total_successful_runs}")
    print(f"Success rate: {success_rate:.2f}%")
    print(f"Mean collection duration: {mean_duration:.2f} seconds")
    print(f"Median collection duration: {median_duration:.2f} seconds")
    print(f"Number of runs under 15 seconds: {runs_under_15_seconds}")

if __name__ == "__main__":
    log_file_path = ensure_log_file_exists()

    # Calculate total hours in the log file
    with open(log_file_path, 'r') as file:
        log_data = file.readlines()

    if not log_data:
        print("Log file is empty. Allow some time for the log to collect data and try again.")
        exit()

    timestamps = [re.search(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', line).group() for line in log_data if re.search(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}', line)]
    if timestamps:
        start_time = datetime.fromisoformat(timestamps[0])
        end_time = datetime.fromisoformat(timestamps[-1])
        total_hours = (end_time - start_time).total_seconds() // 3600
        print(f"The log file covers approximately {int(total_hours)} hours.")
    else:
        print("No valid timestamps found in the log file. Allow some time for the log to collect data.")
        exit()

    # Prompt user for duration or "all"
    duration_input = input(f"Enter the number of hours to process (1-{int(total_hours)}) or type 'all' to process the entire log: ").strip().lower()
    if duration_input == "all":
        process_log_file(log_file_path)
    else:
        try:
            hours = int(duration_input)
            if 1 <= hours <= int(total_hours):
                process_log_file(log_file_path, hours=hours)
            else:
                print("Invalid number of hours. Exiting.")
        except ValueError:
            print("Invalid input. Exiting.")


