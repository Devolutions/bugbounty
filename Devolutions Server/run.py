#!/usr/bin/env python3
"""
Start the DVLS Docker environment.

Run install.py first to perform the initial setup (certs, CA trust, hosts file).
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

import install as _install
import logger

# Windows consoles default to cp1252 and cannot encode the status glyphs below. Importing install
# above already reconfigures both streams as a side effect, so this is currently redundant -- and
# that is exactly why it is here: the protection would vanish silently the day someone drops the
# `import install` (which exists only for _build_env / _inject_certificates on --update). Stating
# it locally makes this file's output safe on its own terms rather than by accident.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

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


def main() -> None:
    parser = argparse.ArgumentParser(description="Start the DVLS Docker environment")
    parser.add_argument("--update", action="store_true",
                        help="Pull latest container images before starting")
    args = parser.parse_args()

    os.chdir(SCRIPT_DIR)

    if args.update:
        # Rebuilding .env from env.template would reset PG_SUPERUSER_PASSWORD to the template
        # default while the existing pgdata volume still holds the password install.py
        # generated. Carry the live value across the regeneration.
        env_path = SCRIPT_DIR / ".env"
        preserved = ""
        if env_path.exists():
            # errors="replace": install.py writes .env in the platform default encoding, so a
            # strict decode fails on a Windows-generated file.
            for line in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("PG_SUPERUSER_PASSWORD="):
                    preserved = line.partition("=")[2].strip().strip(chr(34)).strip(chr(39))
                    break

        print("\nRegenerating .env...")
        _install._build_env(SCRIPT_DIR)
        if preserved:
            _install._update_env_value(env_path, "PG_SUPERUSER_PASSWORD", preserved)
            print("✓ Preserved existing cluster superuser password.")
        else:
            # NOT a no-op branch - this is the SQL Server upgrade path. A .env written before the
            # PostgreSQL migration has no PG_SUPERUSER_PASSWORD, so _build_env() has just written
            # env.template's committed default, which is public in the repo. Generating is safe
            # precisely because there is nothing to match: no pgdata volume exists yet. If one did,
            # its password would be in .env and we would be in the branch above.
            _install._update_env_value(
                env_path, "PG_SUPERUSER_PASSWORD", _install._generate_password())
            print("✓ Generated a cluster superuser password (none to preserve).")
        _install._inject_certificates(SCRIPT_DIR / ".env", CERT_DIR)
        print("✓ .env regenerated.")

        # Nothing to clear so the provisioner re-runs: dvls_seed carries no sentinel and
        # re-provisions on every start. The schema is not touched either -
        # DVLS_DATABASE_UPGRADE_ON_STARTUP handles migrations, and DVLS_INIT stays off because
        # re-initializing an existing database fails on the duplicate administrator.

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
    # --remove-orphans: the retired sqlserver_db is not in this compose file, so nothing else
    # removes it. It would keep running with its published ports and old credentials, and it holds
    # the address the new postgres_db needs.
    up_cmd = ["docker", "compose", "up", "-d", "--remove-orphans"]
    if args.update:
        up_cmd.append("--force-recreate")
    result = subprocess.run(up_cmd, cwd=SCRIPT_DIR)
    if result.returncode != 0:
        print("❌ Failed to start Docker Compose.")
        sys.exit(1)

    # AFTER `up -d`: this check used to sit in the --update branch, which runs before the
    # containers start, so it inspected the previous run's already-exited dvls_seed and tested
    # nothing. Unconditional, not just --update: dvls_seed re-provisions on every start, `up -d`
    # returns when the one-shot STARTS, and everything it writes is per-install - so a silent
    # failure leaves a stack that looks up and cannot authenticate through the Gateway.
    print("Waiting for the provisioner to finish...")
    seed_exit = _install._wait_for_seeder(SCRIPT_DIR)
    if seed_exit != 0:
        print(f"❌ dvls_seed exited {seed_exit}. The origin whitelist, trial licence, Gateway")
        print("   provisioner key or certificate thumbprint may be stale or missing.")
        print("   Check: docker compose logs dvls_seed")
        sys.exit(1)

    # Same reason install.py does it, and the reason this is shared rather than copied: on the
    # documented SQL Server upgrade path there is no pgdata volume yet, so dvls_server boots
    # against a freshly restored database with no Gateway keypair, generates its own, and keeps
    # signing with it after dvls_seed writes the right one. Every Gateway call then returns 401.
    if not _install.restart_for_keypair(SCRIPT_DIR):
        sys.exit(1)

    print("================================================")
    print("| Devolutions Server is now up and running!    |")
    print("| It can be accessed at https://localhost:5544 |")
    print("================================================")



if __name__ == "__main__":
    logger.setup(SCRIPT_DIR)
    try:
        main()
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        input("\nPress Enter to exit...")
        sys.exit(1)
