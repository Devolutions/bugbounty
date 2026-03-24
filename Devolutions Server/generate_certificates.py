#!/usr/bin/env python3
"""
Certificate generation script for DVLS Docker setup.

Generates a Certificate Authority and server certificates for DVLS and Gateway.
Cross-platform: works on Windows, Linux without shell path mangling.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

CA_DAYS = 10950       # ~30 years
SERVER_DAYS = 10950   # ~30 years
DVLS_HOSTNAME = "localhost"
GATEWAY_HOSTNAME = "gateway.loc"

_SAN_CNF_TEMPLATE = """\
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = {cn}
O = DVLS
ST = QC
C = CA

[v3_req]
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = {hostname}
DNS.2 = localhost
IP.1 = 127.0.0.1
"""


def _openssl(*args: str, cwd: Path | None = None) -> None:
    """Run an openssl command, exit on failure."""
    cmd = ["openssl", *args]
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"❌ OpenSSL error:\n{result.stderr.strip()}")
        sys.exit(1)


def _write_san_cnf(path: Path, cn: str, hostname: str) -> None:
    path.write_text(_SAN_CNF_TEMPLATE.format(cn=cn, hostname=hostname))


def _remove_files(cert_dir: Path, names: list[str]) -> None:
    for name in names:
        (cert_dir / name).unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Generation modes
# ---------------------------------------------------------------------------

def _generate_ca(cert_dir: Path) -> None:
    print("\n🔐 Generating Certificate Authority...")
    _openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(cert_dir / "ca.key"))
    print("✅ CA private key generated")

    _openssl(
        "req", "-new", "-x509", "-sha256",
        "-key", str(cert_dir / "ca.key"),
        "-out", str(cert_dir / "ca.crt"),
        "-subj", "/CN=DVLS Certificate Authority/O=DVLS/ST=QC/C=CA",
        "-days", str(CA_DAYS),
    )
    print(f"✅ CA certificate generated (valid for {CA_DAYS} days / ~{CA_DAYS / 365:.1f} years)")


def _generate_server_cert(
    cert_dir: Path,
    name: str,
    cn: str,
    hostname: str,
) -> None:
    """Generate a server key + CSR + signed cert + PFX for the given service name."""
    key = cert_dir / f"{name}-server.key"
    csr = cert_dir / f"{name}-server.csr"
    crt = cert_dir / f"{name}-server.crt"
    pfx = cert_dir / f"{name}-server.pfx"
    cnf = cert_dir / f"{name}-san.cnf"

    _openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key))
    print(f"✅ {name.upper()} server private key generated")

    _write_san_cnf(cnf, cn, hostname)

    _openssl("req", "-new", "-sha256", "-key", str(key), "-out", str(csr), "-config", str(cnf))
    print(f"✅ {name.upper()} server CSR generated with SAN")

    _openssl(
        "x509", "-req", "-in", str(csr),
        "-CA", str(cert_dir / "ca.crt"),
        "-CAkey", str(cert_dir / "ca.key"),
        "-CAcreateserial",
        "-out", str(crt),
        "-days", str(SERVER_DAYS), "-sha256",
        "-extensions", "v3_req", "-extfile", str(cnf),
    )
    print(f"✅ {name.upper()} server certificate signed with SAN "
          f"(valid for {SERVER_DAYS} days / ~{SERVER_DAYS / 365:.1f} years)")

    cnf.unlink(missing_ok=True)

    _openssl(
        "pkcs12", "-export",
        "-out", str(pfx),
        "-inkey", str(key),
        "-in", str(crt),
        "-certfile", str(cert_dir / "ca.crt"),
        "-passout", "pass:",
    )
    print(f"✅ {name.upper()} server certificate exported to PFX")


def _generate_provisioner_keys(cert_dir: Path) -> None:
    print("\n🔐 Generating Gateway Provisioner Key Pair...")
    prov_key = cert_dir / "provisioner.key"
    prov_pem = cert_dir / "provisioner.pem"

    _openssl("genrsa", "-traditional", "-out", str(prov_key), "2048")
    print("✅ Provisioner private key generated (PKCS#1 format)")

    _openssl("rsa", "-in", str(prov_key), "-pubout", "-out", str(prov_pem))
    print("✅ Provisioner public key extracted")

    shutil.move(str(prov_pem), str(cert_dir / "gtw-provisioner.pem"))
    print("✅ provisioner.pem → gtw-provisioner.pem")
    shutil.move(str(prov_key), str(cert_dir / "gtw-provisioner.key"))
    print("✅ provisioner.key → gtw-provisioner.key")

    _remove_files(cert_dir, ["provisioner.pem.b64", "provisioner.key.b64"])


def _rename_and_cleanup_full(cert_dir: Path) -> None:
    print("\n🔄 Renaming certificates to match naming convention...")
    renames = [
        ("dvls-server.crt", "dvls.crt"),
        ("dvls-server.key", "dvls.key"),
        ("gateway-server.crt", "gtw.crt"),
        ("gateway-server.key", "gtw.key"),
    ]
    for src, dst in renames:
        src_path = cert_dir / src
        if src_path.exists():
            shutil.move(str(src_path), str(cert_dir / dst))
            print(f"✅ {src} → {dst}")

    print("\n🧹 Removing unused certificate files...")
    unused = [
        "ca.srl",
        "dvls-server.csr", "dvls-server.pfx", "dvls-server.pfx.b64",
        "gateway-server.csr", "gateway-server.pfx", "gateway-server.pfx.b64",
        "provisioner.key.b64", "provisioner.pem.b64",
    ]
    for name in unused:
        p = cert_dir / name
        if p.exists():
            p.unlink()
            print(f"🗑️  Removed {name}")


# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

def generate_full(cert_dir: Path) -> None:
    _generate_ca(cert_dir)

    print("\n🔐 Generating DVLS Server Certificate...")
    _generate_server_cert(cert_dir, "dvls", DVLS_HOSTNAME, DVLS_HOSTNAME)

    print("\n🔐 Generating Gateway Server Certificate...")
    _generate_server_cert(cert_dir, "gateway", GATEWAY_HOSTNAME, GATEWAY_HOSTNAME)

    _generate_provisioner_keys(cert_dir)
    _rename_and_cleanup_full(cert_dir)

    print(f"\n✅ All certificates generated successfully!")
    print(f"\n📁 Final certificate files in {cert_dir}:")
    print("   - ca.crt             (CA certificate)")
    print("   - ca.key             (CA private key)")
    print("   - dvls.crt / dvls.key")
    print("   - gtw.crt  / gtw.key")
    print("   - gtw-provisioner.pem / gtw-provisioner.key")


def generate_gateway_only(cert_dir: Path) -> None:
    print("\n🔐 Generating Gateway Server Certificate (using existing CA)...")

    if not (cert_dir / "ca.crt").exists() or not (cert_dir / "ca.key").exists():
        print(f"❌ ca.crt / ca.key not found in {cert_dir} — cannot sign Gateway certificate")
        sys.exit(1)

    _generate_server_cert(cert_dir, "gateway", GATEWAY_HOSTNAME, GATEWAY_HOSTNAME)

    shutil.move(str(cert_dir / "gateway-server.crt"), str(cert_dir / "gtw.crt"))
    print("✅ gateway-server.crt → gtw.crt")
    shutil.move(str(cert_dir / "gateway-server.key"), str(cert_dir / "gtw.key"))
    print("✅ gateway-server.key → gtw.key")

    _remove_files(cert_dir, ["gateway-server.csr", "gateway-server.pfx", "gateway-server.pfx.b64"])

    print(f"\n✅ Gateway certificate generated successfully!")
    print(f"\n📁 Final gateway certificate files in {cert_dir}:")
    print("   - gtw.crt (Gateway server certificate)")
    print("   - gtw.key (Gateway server private key)")


def generate_provisioner_only(cert_dir: Path) -> None:
    _generate_provisioner_keys(cert_dir)
    print("\n✅ Provisioner key pair generated successfully!")
    print(f"\n📁 Final provisioner files in {cert_dir}:")
    print("   - gtw-provisioner.pem (Gateway provisioner public key)")
    print("   - gtw-provisioner.key (Gateway provisioner private key)")


def run(script_dir: Path, gateway_only: bool = False, provisioner_only: bool = False) -> None:
    cert_dir = script_dir / "Certificates"
    cert_dir.mkdir(parents=True, exist_ok=True)
    print(f"📂 Certificates will be generated in: {cert_dir}")

    # Remove files that will be regenerated
    if provisioner_only:
        clean_files = [
            "provisioner.key", "provisioner.pem",
            "provisioner.key.b64", "provisioner.pem.b64",
            "gtw-provisioner.key", "gtw-provisioner.pem",
        ]
        print("🧹 Cleaning existing provisioner key files (provisioner-only mode)...")
    elif gateway_only:
        clean_files = [
            "gateway-server.key", "gateway-server.csr", "gateway-server.crt",
            "gateway-server.pfx", "gateway-server.pfx.b64",
            "gtw.key", "gtw.crt",
        ]
        print("🧹 Cleaning existing Gateway certificate files (gateway-only mode)...")
    else:
        clean_files = [
            "ca.key", "ca.crt", "ca.srl",
            "dvls-server.key", "dvls-server.csr", "dvls-server.crt",
            "dvls-server.pfx", "dvls-server.pfx.b64",
            "dvls.key", "dvls.crt",
            "gateway-server.key", "gateway-server.csr", "gateway-server.crt",
            "gateway-server.pfx", "gateway-server.pfx.b64",
            "gtw.key", "gtw.crt",
            "provisioner.key", "provisioner.pem",
            "provisioner.key.b64", "provisioner.pem.b64",
            "gtw-provisioner.key", "gtw-provisioner.pem",
            "dvls-ca.crt",
        ]
        print("🧹 Cleaning existing certificate and key files...")

    _remove_files(cert_dir, clean_files)
    print("✅ Cleaned existing files")

    if gateway_only:
        generate_gateway_only(cert_dir)
    elif provisioner_only:
        generate_provisioner_only(cert_dir)
    else:
        generate_full(cert_dir)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate certificates for DVLS Docker setup")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--provisioner-only", action="store_true",
                       help="Generate only the Gateway provisioner key pair")
    group.add_argument("--gateway-only", action="store_true",
                       help="Generate only the Gateway certificate (requires existing CA)")
    args = parser.parse_args()

    run(
        Path(__file__).parent.resolve(),
        gateway_only=args.gateway_only,
        provisioner_only=args.provisioner_only,
    )
