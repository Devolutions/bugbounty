#!/bin/bash

# Parse command line arguments
SKIP_CA_VALIDATION=false
CLEAN=false
UPDATE= false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-ca-validation)
            SKIP_CA_VALIDATION=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --update)
            UPDATE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-ca-validation] [--clean] [--update]"
            exit 1
            ;;
    esac
done

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        return 1
    else
        return 0
    fi
}

# Check if running as root, if not, elevate
if ! check_root; then
    echo "⚠️ Not running as root. Requesting elevation..."

    # Build arguments to pass to elevated process
    args=""
    if [ "$SKIP_CA_VALIDATION" = true ]; then
        args="$args --skip-ca-validation"
    fi
    if [ "$CLEAN" = true ]; then
        args="$args --clean"
    fi
    if [ "$UPDATE" = true ]; then
        args="$args --update"
    fi
    # Try to re-run with sudo
    if command -v sudo &> /dev/null; then
        sudo "$0" $args
        exit $?
    else
        echo "❌ sudo not available. Please run this script as root"
        exit 1
    fi
fi

echo "✅ Running as root"

# Set working directory to the script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"
echo "📂 Script is running from: $SCRIPT_DIR"

# Clean data folders if requested
if [ "$CLEAN" = true ]; then
    bash "$SCRIPT_DIR/clean.sh"
fi

chown -R 10001:10001 ./data-sql # mssql user
chown -R 1000:1000 ./data-dvls # ubuntu user

# Clean .env if it exists, then create from .env.template
if [ -f ".env" ]; then
    rm -f ".env"
    echo "🧹 Removed existing .env"
fi

if [ -f "env.template" ]; then
    cp "env.template" ".env"
    echo "✅ Created .env from env.template"
else
    echo "❌ env.template not found. Cannot create .env."
    exit 1
fi

# Clean tmp folder
if [ -d "./tmp" ]; then
    rm -rf "./tmp"
    echo "🧹 Cleaned tmp folder"
fi

# Update containers if requested
if [ "$doUpdate" = true ]; then
    echo -e "\nUpdating containers (docker compose pull)..."
    if docker compose pull; then
        echo "✓ Containers updated successfully."
    else
        echo "Error: Failed to update containers."
        exit 1
    fi
fi

# Load environment variables from .env
import_dotenv() {
    local env_file="${1:-.env}"

    if [ ! -f "$env_file" ]; then
        echo "⚠️ File '$env_file' not found."
        return
    fi

    while IFS= read -r line; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip empty lines
        [[ -z "$line" ]] && continue

        # Split on first = sign
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            name="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            # Trim whitespace
            name=$(echo "$name" | xargs)
            value=$(echo "$value" | xargs)

            # Remove surrounding quotes
            value="${value#\"}"
            value="${value%\"}"
            value="${value#\'}"
            value="${value%\'}"

            export "$name=$value"
        fi
    done < "$env_file"

    echo "Environment variables loaded from $env_file"
}

import_dotenv ".env"

# Check if certificates exist in Certificates folder
TEST_CERTS_DVLS_CRT="$SCRIPT_DIR/Certificates/dvls.crt"
TEST_CERTS_DVLS_KEY="$SCRIPT_DIR/Certificates/dvls.key"
TEST_CERTS_GATEWAY_CRT="$SCRIPT_DIR/Certificates/gtw.crt"
TEST_CERTS_GATEWAY_KEY="$SCRIPT_DIR/Certificates/gtw.key"
TEST_CERTS_PROVISIONER_PUB="$SCRIPT_DIR/Certificates/gtw-provisioner.pem"
TEST_CERTS_PROVISIONER_PRIV="$SCRIPT_DIR/Certificates/gtw-provisioner.key"
TEST_CERTS_CA="$SCRIPT_DIR/Certificates/ca.crt"

USE_TEST_CERTIFICATES=true
[ ! -f "$TEST_CERTS_DVLS_CRT" ] && USE_TEST_CERTIFICATES=false
[ ! -f "$TEST_CERTS_DVLS_KEY" ] && USE_TEST_CERTIFICATES=false
[ ! -f "$TEST_CERTS_GATEWAY_CRT" ] && USE_TEST_CERTIFICATES=false
[ ! -f "$TEST_CERTS_GATEWAY_KEY" ] && USE_TEST_CERTIFICATES=false
[ ! -f "$TEST_CERTS_PROVISIONER_PUB" ] && USE_TEST_CERTIFICATES=false
[ ! -f "$TEST_CERTS_PROVISIONER_PRIV" ] && USE_TEST_CERTIFICATES=false
[ ! -f "$TEST_CERTS_CA" ] && USE_TEST_CERTIFICATES=false

# Function to convert file to base64
file_to_base64() {
    base64 -w 0 "$1"
}

# Function to update .env file with certificate
update_env_cert() {
    local key="$1"
    local value="$2"
    sed -i "s|^${key}\s*=.*|${key}=\"${value}\"|" .env
}

if [ "$USE_TEST_CERTIFICATES" = true ]; then
    echo "🔐 Found certificates in Certificates folder, using those..."

    # Convert certificates to base64
    DVLS_CRT_BASE64=$(file_to_base64 "$TEST_CERTS_DVLS_CRT")
    DVLS_KEY_BASE64=$(file_to_base64 "$TEST_CERTS_DVLS_KEY")
    GATEWAY_CRT_BASE64=$(file_to_base64 "$TEST_CERTS_GATEWAY_CRT")
    GATEWAY_KEY_BASE64=$(file_to_base64 "$TEST_CERTS_GATEWAY_KEY")
    PROVISIONER_PUB_BASE64=$(file_to_base64 "$TEST_CERTS_PROVISIONER_PUB")
    PROVISIONER_PRIV_BASE64=$(file_to_base64 "$TEST_CERTS_PROVISIONER_PRIV")
    CA_BASE64=$(file_to_base64 "$TEST_CERTS_CA")

    # Update .env file with all certificate values
    update_env_cert "DVLS_CERT_CRT_B64" "$DVLS_CRT_BASE64"
    update_env_cert "DVLS_CERT_KEY_B64" "$DVLS_KEY_BASE64"
    update_env_cert "DVLS_CA_CERT_B64" "$CA_BASE64"
    update_env_cert "GTW_TLS_CERTIFICATE_B64" "$GATEWAY_CRT_BASE64"
    update_env_cert "GTW_TLS_PRIVATE_KEY_B64" "$GATEWAY_KEY_BASE64"
    update_env_cert "GTW_PROVISIONER_PUBLIC_KEY_B64" "$PROVISIONER_PUB_BASE64"
    update_env_cert "GTW_PROVISIONER_PRIVATE_KEY_B64" "$PROVISIONER_PRIV_BASE64"

    echo "✅ Certificates from Certificates folder injected into .env"

    # Reload environment variables from updated .env
    import_dotenv ".env"

else
    echo "⚠️ Certificates not found in Certificates folder."
    echo "🔐 Generating certificates automatically..."

    GENERATE_SCRIPT="$SCRIPT_DIR/Generate-Certificates.sh"

    if [ -f "$GENERATE_SCRIPT" ]; then
        pushd "$SCRIPT_DIR" > /dev/null
        bash "$GENERATE_SCRIPT"
        EXIT_CODE=$?
        popd > /dev/null

        if [ $EXIT_CODE -ne 0 ]; then
            echo "❌ Failed to generate certificates with exit code $EXIT_CODE"
            exit 1
        fi
        echo "✅ Certificates generated successfully"

        # Re-check if certificates were created successfully
        USE_TEST_CERTIFICATES=true
        [ ! -f "$TEST_CERTS_DVLS_CRT" ] && USE_TEST_CERTIFICATES=false
        [ ! -f "$TEST_CERTS_DVLS_KEY" ] && USE_TEST_CERTIFICATES=false
        [ ! -f "$TEST_CERTS_GATEWAY_CRT" ] && USE_TEST_CERTIFICATES=false
        [ ! -f "$TEST_CERTS_GATEWAY_KEY" ] && USE_TEST_CERTIFICATES=false
        [ ! -f "$TEST_CERTS_PROVISIONER_PUB" ] && USE_TEST_CERTIFICATES=false
        [ ! -f "$TEST_CERTS_PROVISIONER_PRIV" ] && USE_TEST_CERTIFICATES=false
        [ ! -f "$TEST_CERTS_CA" ] && USE_TEST_CERTIFICATES=false

        if [ "$USE_TEST_CERTIFICATES" = false ]; then
            echo "❌ Certificates were not created successfully"
            exit 1
        fi

        # Convert and inject certificates
        DVLS_CRT_BASE64=$(file_to_base64 "$TEST_CERTS_DVLS_CRT")
        DVLS_KEY_BASE64=$(file_to_base64 "$TEST_CERTS_DVLS_KEY")
        GATEWAY_CRT_BASE64=$(file_to_base64 "$TEST_CERTS_GATEWAY_CRT")
        GATEWAY_KEY_BASE64=$(file_to_base64 "$TEST_CERTS_GATEWAY_KEY")
        PROVISIONER_PUB_BASE64=$(file_to_base64 "$TEST_CERTS_PROVISIONER_PUB")
        PROVISIONER_PRIV_BASE64=$(file_to_base64 "$TEST_CERTS_PROVISIONER_PRIV")
        CA_BASE64=$(file_to_base64 "$TEST_CERTS_CA")

        update_env_cert "DVLS_CERT_CRT_B64" "$DVLS_CRT_BASE64"
        update_env_cert "DVLS_CERT_KEY_B64" "$DVLS_KEY_BASE64"
        update_env_cert "DVLS_CA_CERT_B64" "$CA_BASE64"
        update_env_cert "GTW_TLS_CERTIFICATE_B64" "$GATEWAY_CRT_BASE64"
        update_env_cert "GTW_TLS_PRIVATE_KEY_B64" "$GATEWAY_KEY_BASE64"
        update_env_cert "GTW_PROVISIONER_PUBLIC_KEY_B64" "$PROVISIONER_PUB_BASE64"
        update_env_cert "GTW_PROVISIONER_PRIVATE_KEY_B64" "$PROVISIONER_PRIV_BASE64"

        echo "✅ Certificates from Certificates folder injected into .env"
        import_dotenv ".env"
    else
        echo "❌ Generate-Certificates.sh not found at $GENERATE_SCRIPT"
        exit 1
    fi
fi

# Check and import CA certificate if not trusted (Linux-specific)
if [ "$SKIP_CA_VALIDATION" = false ]; then
    CA_CERT_PATH="$SCRIPT_DIR/Certificates/ca.crt"
    if [ -f "$CA_CERT_PATH" ]; then
        # Get certificate info using openssl
        CA_SUBJECT=$(openssl x509 -in "$CA_CERT_PATH" -noout -subject 2>/dev/null | sed 's/subject=//')
        CA_FINGERPRINT=$(openssl x509 -in "$CA_CERT_PATH" -noout -fingerprint 2>/dev/null | sed 's/SHA1 Fingerprint=//')

        echo "📋 CA Certificate Info:"
        echo "   Subject: $CA_SUBJECT"
        echo "   Fingerprint: $CA_FINGERPRINT"

        # Check if CA is already trusted (Debian/Ubuntu)
        if [ -d "/usr/local/share/ca-certificates" ]; then
            CA_INSTALL_PATH="/usr/local/share/ca-certificates/devolutions-ca.crt"

            # Check if certificate already exists
            if [ -f "$CA_INSTALL_PATH" ]; then
                # Compare fingerprints
                EXISTING_FINGERPRINT=$(openssl x509 -in "$CA_INSTALL_PATH" -noout -fingerprint 2>/dev/null | sed 's/SHA1 Fingerprint=//')

                if [ "$EXISTING_FINGERPRINT" = "$CA_FINGERPRINT" ]; then
                    echo "✅ CA certificate is already trusted on this machine"
                else
                    echo "🔐 Updating CA certificate in system trust store..."
                    cp "$CA_CERT_PATH" "$CA_INSTALL_PATH"
                    update-ca-certificates
                    echo "✅ CA certificate updated successfully"
                fi
            else
                echo "🔐 Installing CA certificate to system trust store..."
                cp "$CA_CERT_PATH" "$CA_INSTALL_PATH"
                update-ca-certificates
                echo "✅ CA certificate installed successfully"
            fi
        # Check if CA is already trusted (RHEL/CentOS/Fedora)
        elif [ -d "/etc/pki/ca-trust/source/anchors" ]; then
            CA_INSTALL_PATH="/etc/pki/ca-trust/source/anchors/devolutions-ca.crt"

            if [ -f "$CA_INSTALL_PATH" ]; then
                EXISTING_FINGERPRINT=$(openssl x509 -in "$CA_INSTALL_PATH" -noout -fingerprint 2>/dev/null | sed 's/SHA1 Fingerprint=//')

                if [ "$EXISTING_FINGERPRINT" = "$CA_FINGERPRINT" ]; then
                    echo "✅ CA certificate is already trusted on this machine"
                else
                    echo "🔐 Updating CA certificate in system trust store..."
                    cp "$CA_CERT_PATH" "$CA_INSTALL_PATH"
                    update-ca-trust
                    echo "✅ CA certificate updated successfully"
                fi
            else
                echo "🔐 Installing CA certificate to system trust store..."
                cp "$CA_CERT_PATH" "$CA_INSTALL_PATH"
                update-ca-trust
                echo "✅ CA certificate installed successfully"
            fi
        else
            echo "⚠️ Unknown Linux distribution. Cannot automatically install CA certificate."
            echo "   Please manually add $CA_CERT_PATH to your system's trust store."
        fi
    else
        echo "❌ CA certificate not found at $CA_CERT_PATH"
        exit 1
    fi
else
    echo "⚠️ Skipping CA certificate validation (--skip-ca-validation flag set)"
fi

# Check and add gateway.loc to hosts file
HOSTS_PATH="/etc/hosts"
if [ -f "$HOSTS_PATH" ]; then
    if grep -qE '^\s*127\.0\.0\.1\s+.*gateway\.loc' "$HOSTS_PATH"; then
        echo "✅ gateway.loc is mapped to 127.0.0.1 in hosts file"
    else
        echo "⚠️ gateway.loc is NOT in hosts file. Adding it now..."
        echo "127.0.0.1 gateway.loc" >> "$HOSTS_PATH"
        echo "✅ Successfully added gateway.loc to hosts file"
    fi
else
    echo "❌ Hosts file not found at $HOSTS_PATH"
    exit 1
fi

# Check Docker OSType
osType=$(docker info --format '{{.OSType}}' 2>/dev/null || echo "unknown")

if [ "$osType" != "linux" ]; then
    echo "Error: Docker is not running in Linux Containers mode. (Detected: $osType)"
    exit 1
else
    echo "✓ Docker is running in Linux Containers mode."
fi

# Start Docker Compose
echo -e "\nStarting Docker Compose..."

if docker compose up -d; then
    echo "================================================"
    echo "| Devolutions Server is now up and running!    |"
    echo "| It can be accessed at https://localhost:5544 |"
    echo "================================================"
else
    echo "Error: Failed to start Docker Compose."
    exit 1
fi
