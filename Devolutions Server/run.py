#!/usr/bin/env python3
"""
Start the DVLS Docker environment.

Run install.py first to perform the initial setup (certs, CA trust, hosts file).
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent.resolve()
CERT_DIR = SCRIPT_DIR / "Certificates"


def _load_env() -> dict[str, str]:
    env: dict[str, str] = {}
    env_path = SCRIPT_DIR / ".env"
    if not env_path.exists():
        return env
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        env[key] = value
        os.environ[key] = value
    return env


def _sync_gateway_thumbprint(sql_password: str) -> None:
    gtw_cert = CERT_DIR / "gtw.crt"
    if not gtw_cert.exists():
        print("⚠️  gtw.crt not found — skipping Gateway thumbprint sync")
        return

    result = subprocess.run(
        ["openssl", "x509", "-in", str(gtw_cert), "-noout", "-fingerprint", "-sha1"],
        capture_output=True, text=True,
    )
    match = re.search(r'Fingerprint=([0-9A-Fa-f:]+)', result.stdout, re.IGNORECASE)
    if not match:
        print("⚠️  Could not read Gateway certificate fingerprint")
        return

    thumbprint = match.group(1).replace(":", "").upper()
    print(f"🔑 Syncing Gateway certificate thumbprint in database ({thumbprint})...")

    sql_result = subprocess.run([
        "docker", "compose", "exec", "-T", "sqlserver_db",
        "/opt/mssql-tools18/bin/sqlcmd",
        "-S", "localhost", "-U", "sa", "-P", sql_password,
        "-d", "dvls_docker",
        "-Q", f"UPDATE DevolutionsGateway SET CertificateThumbprint='{thumbprint}'",
        "-C",
    ], capture_output=True)

    if sql_result.returncode == 0:
        print("✅ Gateway certificate thumbprint updated")
    else:
        print("⚠️  Could not update Gateway thumbprint — Gateway connections may fail until certs match")


def main() -> None:
    parser = argparse.ArgumentParser(description="Start the DVLS Docker environment")
    parser.add_argument("--update", action="store_true",
                        help="Pull latest container images before starting")
    args = parser.parse_args()

    os.chdir(SCRIPT_DIR)

    env = _load_env()
    if not env:
        print("⚠️  .env not found — run install.py first")
        sys.exit(1)
        
    # Check Docker is in Linux containers mode
    os_type = subprocess.run(
        ["docker", "info", "--format", "{{.OSType}}"],
        capture_output=True, text=True,
    ).stdout.strip()
    if os_type != "linux":
        print(f"❌ Docker is not running in Linux Containers mode. (Detected: {os_type})")
        sys.exit(1)
    print("✓ Docker is running in Linux Containers mode.")

    if args.update:
        print("\nUpdating containers (docker compose pull)...")
        result = subprocess.run(["docker", "compose", "pull"], cwd=SCRIPT_DIR)
        if result.returncode != 0:
            print("❌ Failed to update containers.")
            sys.exit(1)
        print("✓ Containers updated successfully.")

    print("\nStarting Docker Compose...")
    result = subprocess.run(["docker", "compose", "up", "-d"], cwd=SCRIPT_DIR)
    if result.returncode != 0:
        print("❌ Failed to start Docker Compose.")
        sys.exit(1)

    print("================================================")
    print("| Devolutions Server is now up and running!    |")
    print("| It can be accessed at https://localhost:5544 |")
    print("================================================")

    _sync_gateway_thumbprint(env.get("SQL_MSSQL_PASSWORD", ""))


if __name__ == "__main__":
    main()
