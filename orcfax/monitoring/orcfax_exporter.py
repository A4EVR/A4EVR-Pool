# Orcfax Node Exporter by A4EVR
# Version 1.0.0 for collector 2.0.1-rc.1

import time
import re
import requests
import threading
import logging
import sys
import argparse
from prometheus_client import start_http_server, Counter, Gauge, Histogram

########################
# LOGGING CONFIG
########################

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)
logger = logging.getLogger(__name__)

########################
# PROMETHEUS METRICS
########################

orcfax_cycle_duration = Histogram(
    'orcfax_cycle_duration_seconds',
    'Collector cycle duration in seconds',
    ['license'],
    buckets=[10, 30, 60, 90, 120, 240, 480]
)
orcfax_last_cycle_duration = Gauge(
    'orcfax_last_cycle_duration_seconds',
    'Duration (in seconds) of the most recent completed cycle',
    ['license']
)
orcfax_signings_total = Counter(
    'orcfax_signings_total',
    'Number of signing operations performed during collection runs',
    ['license']
)

# -----------------------
# Exchange-level metrics: DISABLED
# (Logs do not contain per-exchange "response" lines.)
#
# orcfax_exchange_success_total = ...
# orcfax_exchange_failure_total = ...
# -----------------------

# 1) Feed Aggregation Success
# Track "send_to_ws() :: sending message 'FEED'" lines
orcfax_feed_aggregation_success_total = Counter(
    'orcfax_feed_aggregation_success_total',
    'Number of feeds successfully aggregated (implied by sending message line)',
    ['license', 'feed']
)

# 2) Feed Push Metrics
orcfax_feed_push_success_total = Counter(
    'orcfax_feed_push_success_total',
    'Number of aggregated feeds successfully accepted by the network',
    ['license', 'feed']
)
orcfax_feed_push_failure_total = Counter(
    'orcfax_feed_push_failure_total',
    'Number of aggregated feeds failing to send to the network',
    ['license', 'feed']
)
orcfax_feed_push_failure_timeout_total = Counter(
    'orcfax_feed_push_failure_timeout_total',
    'Number of feed push failures due to websocket timeouts',
    ['license', 'feed']
)
orcfax_feed_push_failure_error_total = Counter(
    'orcfax_feed_push_failure_error_total',
    'Number of feed push failures due to “ERROR:” responses',
    ['license', 'feed']
)

# Node activity & external data
orcfax_node_active = Gauge(
    'orcfax_node_active',
    '1 if node has been active within the last 10 minutes, else 0',
    ['license']
)
orcfax_validator_info = Gauge(
    'orcfax_validator_info',
    'Static info about this validator',
    ['license', 'stake_key', 'alias']
)
orcfax_validator_staked = Gauge(
    'orcfax_validator_staked',
    'Staked amount for this validator',
    ['license', 'stake_key', 'alias']
)
orcfax_external_collection_count = Counter(
    'orcfax_external_collection_count',
    'External collection count (cumulative)',
    ['license', 'stake_key']
)

########################
# GLOBALS
########################

license_log_paths = {}
last_signing_timestamp = {}
last_api_totals = {}

########################
# LOG PARSING
########################

def tail_collector_logs():
    threads = []
    for lic, log_path in license_log_paths.items():
        t = threading.Thread(target=tail_log, args=(lic, log_path))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()

def tail_log(license, log_path):
    try:
        with open(log_path, 'r') as f:
            f.seek(0, 2)
            logger.info(f"Started tailing log for license %s: %s", license, log_path)
            while True:
                line = f.readline()
                if not line:
                    time.sleep(0.3)
                    update_node_active(license)
                    continue
                parse_log_line(license, line)
                update_node_active(license)
    except FileNotFoundError:
        logger.error("Log not found for license %s: %s. Retrying in 60s...", license, log_path)
        time.sleep(60)
        tail_log(license, log_path)

def parse_log_line(license, line):
    # 1) Cycle Duration
    match_dur = re.search(r"completed after:\s*'([\d\.]+)' seconds", line)
    if match_dur:
        try:
            dur = float(match_dur.group(1))
            orcfax_cycle_duration.labels(license=license).observe(dur)
            orcfax_last_cycle_duration.labels(license=license).set(dur)
        except ValueError:
            pass

    # 2) Signings
    if "signing with addr:" in line:
        orcfax_signings_total.labels(license=license).inc()
        last_signing_timestamp[license] = time.time()

    # 3) Aggregation Implied by "sending message 'FEED'"
    #    If we are "sending message 'BTC-USD'", that means we have an aggregated price
    if "send_to_ws() :: sending message" in line or "collector_node.py:203:send_to_ws() :: sending message" in line:
        match_agg = re.search(r"sending message '([^']+)'", line)
        if match_agg:
            feed = match_agg.group(1)
            orcfax_feed_aggregation_success_total.labels(license=license, feed=feed).inc()

    # 4) Feed Push Outcomes

    # (A) Success => "websocket response: OK (FEED)"
    if "websocket response: OK" in line:
        match_ok = re.search(r"websocket response:\s*OK\s*\(([^)]+)\)", line)
        if match_ok:
            feed = match_ok.group(1)
            orcfax_feed_push_success_total.labels(license=license, feed=feed).inc()

    # (B) Error => "websocket response: ERROR: ... (FEED)"
    elif "websocket response: ERROR:" in line:
        match_err = re.search(r"websocket response:\s*ERROR:\s*\(.*?\)\s*\(([^)]+)\)", line)
        if match_err:
            feed = match_err.group(1)
        else:
            feed = "unknown"

        orcfax_feed_push_failure_total.labels(license=license, feed=feed).inc()
        orcfax_feed_push_failure_error_total.labels(license=license, feed=feed).inc()

    # (C) Timeout => "websocket wait_for resp timeout for feed 'FEED'"
    elif "websocket wait_for resp timeout for feed" in line:
        match_to = re.search(r"timeout for feed '([^']+)'", line)
        if match_to:
            feed = match_to.group(1)
        else:
            feed = "unknown"

        orcfax_feed_push_failure_total.labels(license=license, feed=feed).inc()
        orcfax_feed_push_failure_timeout_total.labels(license=license, feed=feed).inc()

def update_node_active(license):
    last_ts = last_signing_timestamp.get(license, 0)
    if (time.time() - last_ts) < 600:  # 10 minutes
        orcfax_node_active.labels(license=license).set(1)
    else:
        orcfax_node_active.labels(license=license).set(0)

########################
# EXTERNAL DATA FETCHING
########################

def fetch_orcfax_data(licenses, api_base="https://itn.0.orcfax.io/api", poll_interval=900):
    while True:
        for lic in licenses:
            try:
                stake_key, staked_val, alias_val = get_stake_key_by_license(
                    lic, f"{api_base}/itn_aliases_and_staking"
                )
                orcfax_validator_info.labels(
                    license=lic, stake_key=stake_key, alias=alias_val
                ).set(1)
                orcfax_validator_staked.labels(
                    license=lic, stake_key=stake_key, alias=alias_val
                ).set(staked_val)

                total_counts = parse_total_counts(f"{api_base}/get_participants_counts_total")
                update_local_counter(lic, stake_key, total_counts.get(stake_key, 0))
            except Exception as e:
                logger.error("Error fetching data for license %s: %s", lic, e)

        time.sleep(poll_interval)

def update_local_counter(license, stake_key, api_total):
    key = (license, stake_key)
    if key not in last_api_totals:
        last_api_totals[key] = api_total
        return

    old_total = last_api_totals[key]
    if api_total >= old_total:
        diff = api_total - old_total
        orcfax_external_collection_count.labels(
            license=license, stake_key=stake_key
        ).inc(diff)
        last_api_totals[key] = api_total
    else:
        logger.info("API total for %s dropped from %d to %d, resetting.",
                    key, old_total, api_total)
        last_api_totals[key] = api_total

def get_stake_key_by_license(license, url):
    try:
        resp = requests.get(url, timeout=10)
        resp.raise_for_status()
        data = resp.json()
        for entry in data:
            if f"Validator License #{license}" in entry.get("licenses", []):
                stake = entry.get("staking", "")
                staked_val = float(entry.get("staked", 0.0))
                alias_str = entry.get("alias", "")
                return stake, staked_val, alias_str
    except Exception as e:
        logger.error("Error retrieving stake key for license %s: %s", license, e)
    return "", 0.0, ""

def parse_total_counts(url):
    try:
        resp = requests.get(url, timeout=10)
        resp.raise_for_status()
        return {stake_key: int(num_str) for num_str, stake_key in resp.json().items()}
    except Exception as e:
        logger.error("Error parsing total counts: %s", e)
    return {}

########################
# MAIN
########################

def start_exporter(licenses, log_paths, port):
    global license_log_paths

    license_log_paths.update(log_paths)

    start_http_server(port)
    logger.info("Prometheus metrics available on port %d", port)

    # Tail logs in background
    t1 = threading.Thread(target=tail_collector_logs, daemon=True)
    t1.start()

    # External data fetch in background
    t2 = threading.Thread(target=fetch_orcfax_data, args=(licenses,), daemon=True)
    t2.start()

    # Keep main thread alive
    while True:
        time.sleep(1)

def parse_args():
    parser = argparse.ArgumentParser(description="Orcfax Feed-Level Exporter Using send_to_ws for Aggregation Success")
    parser.add_argument("--licenses", required=True,
                        help="Comma-separated list of licenses (e.g., 001,003)")
    parser.add_argument("--log-paths", required=True,
                        help="Comma-separated list of log paths for each license")
    parser.add_argument("--port", type=int, default=9101,
                        help="Port for Prometheus metrics")
    return parser.parse_args()

def main():
    args = parse_args()
    licenses = args.licenses.split(",")
    log_paths = dict(zip(licenses, args.log_paths.split(",")))
    start_exporter(licenses, log_paths, args.port)

if __name__ == "__main__":
    main()
