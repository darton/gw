#!/usr/bin/env python3
import json
import subprocess
import logging
from collections import defaultdict

# --- logger configuration ---
logger = logging.getLogger("ip_accounting")
logger.setLevel(logging.DEBUG)  # capture all, handlers decide what to write

# log to file: only errors, append mode
fh = logging.FileHandler("/opt/gw/log/ip_accounting.log", mode="a")
fh.setLevel(logging.ERROR)
file_formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
fh.setFormatter(file_formatter)
logger.addHandler(fh)

def get_nft_json():
    """Run nft command and return parsed JSON output"""
    res = subprocess.run(
        ["nft", "-j", "list", "table", "ip", "mangle"],
        capture_output=True, text=True
    )
    if res.returncode != 0:
        logger.error("Failed to run nft command: %s", res.stderr.strip())
        return {}
    return json.loads(res.stdout)

def extract_ip_counters(nft_data):
    """Extract counters per IP from nftables JSON"""
    stats = defaultdict(lambda: [0, 0])  # [download, upload]

    for entry in nft_data.get("nftables", []):
        rule = entry.get("rule")
        if not rule:
            continue

        chain = rule.get("chain", "")
        if not (chain.startswith("COUNTERSIN_") or chain.startswith("COUNTERSOUT_")):
            continue

        ip = None
        bytes_count = 0

        for expr in rule.get("expr", []):
            if "match" in expr:
                right = expr["match"].get("right")
                if isinstance(right, str):
                    ip = right
            elif "counter" in expr:
                bytes_count = expr["counter"].get("bytes", 0)

        if not ip:
            continue

        if chain.startswith("COUNTERSIN_"):
            stats[ip][0] += bytes_count
        else:
            stats[ip][1] += bytes_count

    return stats

def reset_counters():
    """Reset nftables counters in the mangle table"""
    res = subprocess.run(["nft", "reset", "counters", "table", "ip", "mangle"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        logger.error("Failed to reset counters: %s", res.stderr.strip())

def print_stats(stats):
    """Print statistics to stdout in 'IP download upload' format"""
    for ip in sorted(stats.keys()):
        down, up = stats[ip]
        print(f"{ip} {down} {up}")

if __name__ == "__main__":
    nft_data = get_nft_json()
    if nft_data:
        stats = extract_ip_counters(nft_data)
        print_stats(stats)   # stdout only
        reset_counters()
