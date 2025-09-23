#!/bin/bash

set -e

export MSYS_NO_PATHCONV=1

# Parse arguments
doClean=false
doUpdate=false

for arg in "$@"; do
    case $arg in
        clean) doClean=true ;;
        update) doUpdate=true ;;
    esac
done

# Clean data folders if requested
if [ "$doClean" = true ]; then
    echo -e "\nCleaning contents of 'data-dvls' and 'data-sql' folders..."

    for folder in "data-dvls" "data-sql"; do
        if [ -d "$folder" ]; then
            find "$folder" -mindepth 1 ! -name ".gitkeep" -exec rm -rf {} +
        else
            echo "Info: '$folder' does not exist. Skipping."
        fi
    done
fi

# Adjust folder permissions
chown -R 10001:10001 ./data-sql # mssql user
chown -R 1000:1000 ./data-dvls # ubuntu user

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
load_env() {
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading/trailing whitespace
        line="$(echo "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

        # Skip comments or empty lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

        # Only process lines with '=' in them
        if [[ "$line" == *=* ]]; then
            name="${line%%=*}"
            value="${line#*=}"

            # Trim name and value
            name="$(echo "$name" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
            value="$(echo "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | sed -e 's/^"//' -e 's/"$//')"

            # Skip if key is empty (invalid)
            [[ -z "$name" ]] && continue

            export "$name=$value"
        fi
    done < .env
}
load_env


# Generate and embed certificate if required
if [[ "$DVLS_CERT_CONFIG" == "1" && "$DVLS_CERT_PFX_B64" == "TODO" ]]; then
    # Check if openssl is installed
    if ! command -v openssl &> /dev/null; then
        echo "❌ Error: OpenSSL is not installed. Please install it before running this script."
        exit 1
    else
        echo "✓ OpenSSL is installed."
    fi

    mkdir -p ./tmp/certificates

    openssl ecparam -name prime256v1 -genkey -noout -out ./tmp/certificates/ca.key
    openssl req -new -x509 -sha256 \
        -key ./tmp/certificates/ca.key \
        -out ./tmp/certificates/ca.crt \
        -subj "/C=CA/ST=QC/O=DVLS" \
        -days 1096

    openssl ecparam -name prime256v1 -genkey -noout -out ./tmp/certificates/server.key
    openssl req -new -sha256 \
        -key ./tmp/certificates/server.key \
        -out ./tmp/certificates/server.csr \
        -subj "/C=CA/ST=QC/O=DVLS/CN=localhost"
        
    openssl x509 -req -in ./tmp/certificates/server.csr -CA ./tmp/certificates/ca.crt -CAkey ./tmp/certificates/ca.key -CAcreateserial -out ./tmp/certificates/server.crt -days 1096 -sha256

    openssl pkcs12 -export -out ./tmp/certificates/server.pfx \
        -inkey ./tmp/certificates/server.key \
        -in ./tmp/certificates/server.crt \
        -passout pass:"$DVLS_CERT_PASSWORD"

    pfx_path="./tmp/certificates/server.pfx"
    if [[ ! -f "$pfx_path" ]]; then
        echo "❌ server.pfx was not created" >&2
        exit 1
    fi

    pfx_base64=$(base64 "$pfx_path" | tr -d '\n')

    # Replace CERT_PFX_B64 line in .env
    tmp_env=$(mktemp)
    while IFS= read -r line; do
        if [[ "$line" =~ ^DVLS_CERT_PFX_B64[[:space:]]*= ]]; then
            echo "DVLS_CERT_PFX_B64=\"$pfx_base64\"" >> "$tmp_env"
        else
            echo "$line" >> "$tmp_env"
        fi
    done < .env
    mv "$tmp_env" .env

    echo "✅ Certificate generated and base64 injected into .env"

    load_env
    echo "✓ Environment variables reloaded."
else
    echo "ℹ️ Skipping certificate generation. Either DVLS_CERT_CONFIG is not '1' or DVLS_CERT_PFX_B64 is already set."
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
