#!/usr/bin/env python3
"""
Install and start the DVLS Docker environment.

Performs a full clean setup: wipes existing data, generates certificates,
installs the CA into the system trust store, updates the hosts file,
then starts Docker Compose.

Subsequent starts (no reinstall): use run.py instead.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

import clean
import generate_certificates
import logger

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------
SYSTEM = platform.system()   # "Windows" | "Linux"
IS_WINDOWS = SYSTEM == "Windows"
IS_LINUX = SYSTEM == "Linux"


# ---------------------------------------------------------------------------
# Privileges
# ---------------------------------------------------------------------------

def _require_privileges() -> None:
    """Ensure admin/root rights; re-exec elevated on Windows, sudo on Linux."""
    if IS_WINDOWS:
        import ctypes
        if not ctypes.windll.shell32.IsUserAnAdmin():
            print("⚠️  Not running as Administrator. Requesting elevation via UAC...")
            params = " ".join(f'"{a}"' for a in sys.argv)
            ret = ctypes.windll.shell32.ShellExecuteW(
                None, "runas", sys.executable, params, None, 1
            )
            if ret <= 32:
                print(f"❌ UAC elevation failed (ShellExecute returned {ret}).")
                sys.exit(1)
            sys.exit(0)
        print("✅ Running as Administrator")
    elif IS_LINUX:
        if os.geteuid() != 0:
            print("⚠️  Not running as root. Requesting elevation via sudo...")
            os.execvp("sudo", ["sudo", sys.executable] + sys.argv)
        print("✅ Running as root")
    else:
        print(f"❌ Unsupported OS ({SYSTEM}). Only Windows and Linux are supported.")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

def _check_prerequisites() -> None:
    if not shutil.which("openssl"):
        print("❌ Missing required dependency: openssl")
        print("   Please install OpenSSL and make sure it is on your PATH.")
        sys.exit(1)
    print("✅ All prerequisites satisfied (openssl)")


# ---------------------------------------------------------------------------
# .env helpers
# ---------------------------------------------------------------------------

def _build_env(script_dir: Path) -> None:
    """Create .env from env.template, apply env.local overrides, add cert placeholders."""
    template = script_dir / "env.template"
    env_path = script_dir / ".env"

    if not template.exists():
        print("❌ env.template not found. Cannot create .env.")
        sys.exit(1)

    if env_path.exists():
        shutil.copy2(env_path, script_dir / ".env.backup")
        print("💾 Backed up existing .env to .env.backup")
        env_path.unlink()

    content = template.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n").decode()
    env_path.write_text(content)
    print("✅ Created .env from env.template")

    local = script_dir / "env.local"
    if local.exists():
        print("📝 Applying env.local overrides...")
        local_content = env_path.read_text()
        for line in local.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key = line.split("=", 1)[0].strip()
            pattern = re.compile(rf'^{re.escape(key)}\s*=.*$', re.MULTILINE)
            if pattern.search(local_content):
                local_content = pattern.sub(line, local_content)
            else:
                local_content += f"\n{line}"
        env_path.write_text(local_content)
        print("✅ env.local overrides applied")

    placeholders = (
        "\n# Certificate variables (auto-generated — do not edit manually)\n"
        'DVLS_CERT_CRT_B64=""\n'
        'DVLS_CERT_KEY_B64=""\n'
        'DVLS_CA_CERT_B64=""\n'
        'GTW_TLS_CERTIFICATE_B64=""\n'
        'GTW_TLS_PRIVATE_KEY_B64=""\n'
        'GTW_PROVISIONER_PUBLIC_KEY_B64=""\n'
        'GTW_PROVISIONER_PRIVATE_KEY_B64=""\n'
    )
    with env_path.open("a") as f:
        f.write(placeholders)
    print("✅ Certificate placeholder variables added to .env")


def _load_env(env_path: Path) -> dict[str, str]:
    """Parse a .env file, export into os.environ, and return the dict."""
    env: dict[str, str] = {}
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
    print(f"Environment variables loaded from {env_path.name}")
    return env


def _update_env_value(env_path: Path, key: str, value: str) -> None:
    content = env_path.read_text()
    pattern = re.compile(rf'^{re.escape(key)}\s*=.*$', re.MULTILINE)
    replacement = f'{key}="{value}"'
    if pattern.search(content):
        content = pattern.sub(replacement, content)
    else:
        content += f"\n{replacement}"
    env_path.write_text(content)


def _inject_certificates(env_path: Path, cert_dir: Path) -> None:
    mappings = {
        "DVLS_CERT_CRT_B64":               cert_dir / "dvls.crt",
        "DVLS_CERT_KEY_B64":               cert_dir / "dvls.key",
        "DVLS_CA_CERT_B64":                cert_dir / "ca.crt",
        "GTW_TLS_CERTIFICATE_B64":         cert_dir / "gtw.crt",
        "GTW_TLS_PRIVATE_KEY_B64":         cert_dir / "gtw.key",
        "GTW_PROVISIONER_PUBLIC_KEY_B64":  cert_dir / "gtw-provisioner.pem",
        "GTW_PROVISIONER_PRIVATE_KEY_B64": cert_dir / "gtw-provisioner.key",
    }
    for key, path in mappings.items():
        b64 = base64.b64encode(path.read_bytes()).decode("ascii")
        _update_env_value(env_path, key, b64)
    print("✅ Certificates injected into .env")


# ---------------------------------------------------------------------------
# Certificate detection
# ---------------------------------------------------------------------------

def _cert_state(cert_dir: Path) -> dict[str, bool]:
    ca   = (cert_dir / "ca.crt").exists()  and (cert_dir / "ca.key").exists()
    dvls = (cert_dir / "dvls.crt").exists() and (cert_dir / "dvls.key").exists()
    gtw  = (cert_dir / "gtw.crt").exists()  and (cert_dir / "gtw.key").exists()
    prov = (cert_dir / "gtw-provisioner.pem").exists() and (cert_dir / "gtw-provisioner.key").exists()
    return {
        "ca": ca, "dvls": dvls, "gateway": gtw, "provisioner": prov,
        "server": ca and dvls and gtw,
        "all": ca and dvls and gtw and prov,
    }


# ---------------------------------------------------------------------------
# CA trust store
# ---------------------------------------------------------------------------

def _ask_yes_no(prompt: str) -> bool:
    answer = input(f"{prompt} [Y/n]: ").strip().lower()
    return answer in ("", "y", "yes")


def _install_ca_windows(ca_cert: Path) -> None:
    print("🔐 Installing CA certificate to Windows Root store...")
    result = subprocess.run(
        ["certutil.exe", "-addstore", "Root", str(ca_cert)],
        capture_output=True,
    )
    if result.returncode == 0:
        print("✅ CA certificate installed successfully (Windows Root store)")
    else:
        print("⚠️  Failed to install CA certificate. Try running as Administrator.")


def _install_ca_linux_debian(ca_cert: Path) -> None:
    print("🔐 Installing CA certificate to system trust store (Debian/Ubuntu)...")
    shutil.copy2(ca_cert, "/usr/local/share/ca-certificates/devolutions-ca.crt")
    subprocess.run(["update-ca-certificates", "--fresh"], check=True)
    print("✅ CA certificate installed successfully")
    if _ask_yes_no("   Trust CA in Chrome (~/.pki/nssdb)?"):
        _configure_chrome_linux(ca_cert)
    if _ask_yes_no("   Trust CA in Firefox (enterprise policy)?"):
        _configure_firefox_linux(ca_cert)


def _install_ca_linux_rhel(ca_cert: Path) -> None:
    print("🔐 Installing CA certificate to system trust store (RHEL/CentOS/Fedora)...")
    shutil.copy2(ca_cert, "/etc/pki/ca-trust/source/anchors/devolutions-ca.crt")
    subprocess.run(["update-ca-trust"], check=True)
    print("✅ CA certificate installed successfully")
    if _ask_yes_no("   Trust CA in Chrome (~/.pki/nssdb)?"):
        _configure_chrome_linux(ca_cert)
    if _ask_yes_no("   Trust CA in Firefox (enterprise policy)?"):
        _configure_firefox_linux(ca_cert)


def _install_ca(ca_cert: Path) -> None:
    if IS_WINDOWS:
        _install_ca_windows(ca_cert)
    elif IS_LINUX:
        if Path("/usr/local/share/ca-certificates").is_dir():
            _install_ca_linux_debian(ca_cert)
        elif Path("/etc/pki/ca-trust/source/anchors").is_dir():
            _install_ca_linux_rhel(ca_cert)
        else:
            print("⚠️  Unknown Linux distribution. Cannot automatically install CA certificate.")
            print(f"   Please manually add {ca_cert} to your system's trust store.")


# ---------------------------------------------------------------------------
# Browser trust (Linux only)
# ---------------------------------------------------------------------------

def _configure_chrome_linux(ca_cert: Path) -> None:
    if not shutil.which("certutil"):
        print("⚠️  certutil not found — skipping Chrome NSS db update (install libnss3-tools to fix)")
        return

    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        import pwd
        pw = pwd.getpwnam(sudo_user)
        real_home = Path(pw.pw_dir)
        real_uid, real_gid = pw.pw_uid, pw.pw_gid
    else:
        real_home = Path.home()
        real_uid, real_gid = None, None

    nssdb = real_home / ".pki" / "nssdb"
    if not nssdb.exists():
        nssdb.mkdir(parents=True)
        subprocess.run(["certutil", "-N", "--empty-password", "-d", f"sql:{nssdb}"], check=True)
        if real_uid is not None:
            os.chown(nssdb, real_uid, real_gid)
            for child in nssdb.iterdir():
                os.chown(child, real_uid, real_gid)

    subprocess.run(
        ["certutil", "-D", "-n", "Devolutions CA", "-d", f"sql:{nssdb}"],
        capture_output=True,
    )
    result = subprocess.run(
        ["certutil", "-A", "-n", "Devolutions CA", "-t", "C,,", "-i", str(ca_cert), "-d", f"sql:{nssdb}"],
        capture_output=True,
    )
    if result.returncode == 0:
        print(f"✅ CA certificate installed to Chrome NSS db ({nssdb})")
    else:
        print("⚠️  Failed to install CA certificate to Chrome NSS db")


def _configure_firefox_linux(ca_cert: Path) -> None:
    firefox_dir = Path("/etc/firefox")
    policies_dir = firefox_dir / "policies"
    ca_dest = firefox_dir / "devolutions-ca.crt"

    policies_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ca_cert, ca_dest)

    policy = {
        "policies": {
            "Certificates": {
                "ImportEnterpriseRoots": True,
                "Install": ["/etc/firefox/devolutions-ca.crt"],
            }
        }
    }
    (policies_dir / "policies.json").write_text(json.dumps(policy, indent=2))
    print(f"✅ Firefox enterprise policy configured (Certificates.Install → {ca_dest})")


# ---------------------------------------------------------------------------
# Hosts file
# ---------------------------------------------------------------------------

def _hosts_path() -> Path:
    if IS_WINDOWS:
        return Path(os.environ.get("SYSTEMROOT", r"C:\Windows")) / "System32" / "drivers" / "etc" / "hosts"
    return Path("/etc/hosts")


def _ensure_hosts_entry(hostname: str) -> None:
    hosts = _hosts_path()
    if not hosts.exists():
        print(f"❌ Hosts file not found at {hosts}")
        sys.exit(1)
    content = hosts.read_text(errors="replace")
    if re.search(rf'^\s*127\.0\.0\.1\s+.*\b{re.escape(hostname)}\b', content, re.MULTILINE):
        print(f"✅ {hostname} is mapped to 127.0.0.1 in hosts file")
    else:
        print(f"⚠️  {hostname} is NOT in hosts file. Adding it now...")
        with hosts.open("a") as f:
            f.write(f"\n127.0.0.1 {hostname}\n")
        print(f"✅ Successfully added {hostname} to hosts file")


# ---------------------------------------------------------------------------
# Gateway thumbprint sync
# ---------------------------------------------------------------------------

def _sync_gateway_thumbprint(cert_dir: Path, sql_password: str) -> None:
    gtw_cert = cert_dir / "gtw.crt"
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


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Install and start the DVLS Docker environment (always performs a clean install)"
    )
    parser.add_argument("--no-cert-gen", action="store_true",
                        help="Use existing certificates; skip generation")
    parser.add_argument("--skip-ca-validation", action="store_true",
                        help="Skip CA certificate installation into the system trust store")
    args = parser.parse_args()

    _require_privileges()

    script_dir = Path(__file__).parent.resolve()
    os.chdir(script_dir)
    print(f"📂 Script is running from: {script_dir}")

    _check_prerequisites()

    # Build .env before anything else
    _build_env(script_dir)

    # Always clean on install
    print("\n🧹 Running clean install...")
    clean.run(script_dir)

    # Fix data folder ownership on Linux (mssql uid=10001, ubuntu uid=1000)
    if IS_LINUX:
        for folder, uid in [("data-sql", 10001), ("data-dvls", 1000)]:
            p = script_dir / folder
            if p.exists():
                os.chown(p, uid, uid)

    # Remove tmp folder
    tmp = script_dir / "tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
        print("🧹 Cleaned tmp folder")

    env = _load_env(script_dir / ".env")
    env_path = script_dir / ".env"
    cert_dir = script_dir / "Certificates"
    state = _cert_state(cert_dir)

    # Certificates
    if args.no_cert_gen:
        print("⚠️  Certificate generation disabled (--no-cert-gen flag)")
        if not state["server"]:
            print("❌ Server certificates not found. Remove --no-cert-gen or add the certs manually.")
            sys.exit(1)
        if not state["provisioner"]:
            print("❌ Provisioner keys not found. Remove --no-cert-gen or add the keys manually.")
            sys.exit(1)
        print("✅ Found all existing certificates")
    else:
        if not state["ca"] or not state["dvls"]:
            print("⚠️  CA or DVLS certificates missing — generating full certificate set...")
            generate_certificates.run(script_dir)
        elif not state["gateway"]:
            print("⚠️  Gateway certificates missing — generating Gateway certs only...")
            generate_certificates.run(script_dir, gateway_only=True)
        elif not state["provisioner"]:
            print("⚠️  Provisioner keys missing — generating provisioner keys only...")
            generate_certificates.run(script_dir, provisioner_only=True)
        else:
            print("🔐 Found all certificates in Certificates folder, using those...")

        if not _cert_state(cert_dir)["all"]:
            print("❌ Certificates were not created successfully")
            sys.exit(1)

    _inject_certificates(env_path, cert_dir)
    env = _load_env(env_path)

    # CA trust store
    if not args.skip_ca_validation:
        ca_cert = cert_dir / "ca.crt"
        if not ca_cert.exists():
            print(f"❌ CA certificate not found at {ca_cert}")
            sys.exit(1)
        result = subprocess.run(
            ["openssl", "x509", "-in", str(ca_cert), "-noout", "-subject", "-fingerprint", "-sha1"],
            capture_output=True, text=True,
        )
        subject = re.search(r'subject=(.*)', result.stdout)
        fingerprint = re.search(r'Fingerprint=([0-9A-Fa-f:]+)', result.stdout, re.IGNORECASE)
        subj_str = subject.group(1).strip() if subject else "unknown"
        fp_str = fingerprint.group(1) if fingerprint else "unknown"
        print(f"📋 CA Certificate: {subj_str} | {fp_str}")
        _install_ca(ca_cert)
    else:
        print("⚠️  Skipping CA certificate installation (--skip-ca-validation flag set)")

    # Hosts file
    gtw_hostname = env.get("GTW_HOSTNAME", "gateway.loc")
    _ensure_hosts_entry(gtw_hostname)

    # Docker OS check
    os_type = subprocess.run(
        ["docker", "info", "--format", "{{.OSType}}"],
        capture_output=True, text=True,
    ).stdout.strip()
    if os_type != "linux":
        print(f"❌ Docker is not running in Linux Containers mode. (Detected: {os_type})")
        sys.exit(1)
    print("✓ Docker is running in Linux Containers mode.")

    # Start Docker Compose
    print("\nStarting Docker Compose...")
    result = subprocess.run(["docker", "compose", "up", "-d"], cwd=script_dir)
    if result.returncode != 0:
        print("❌ Failed to start Docker Compose.")
        sys.exit(1)

    print("================================================")
    print("| Devolutions Server is now up and running!    |")
    print("| It can be accessed at https://localhost:5544 |")
    print("================================================")

    _sync_gateway_thumbprint(cert_dir, env.get("SQL_MSSQL_PASSWORD", ""))


if __name__ == "__main__":
    logger.setup(Path(__file__).parent.resolve())
    try:
        main()
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        input("\nPress Enter to exit...")
        sys.exit(1)
