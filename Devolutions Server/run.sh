#!/bin/bash

# Parse command line arguments
SKIP_CA_VALIDATION=false
CLEAN=false
UPDATE=false
GEN_CERTS=true

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
        --no-cert-gen)
            GEN_CERTS=false
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-ca-validation] [--clean] [--update] [--no-cert-gen]"
            exit 1
            ;;
    esac
done

# Detect OS
IS_WINDOWS=false
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || -n "$MSYSTEM" ]]; then
    IS_WINDOWS=true
fi

# Check prerequisites
check_prerequisites() {
    local missing=()

    if ! command -v openssl &> /dev/null; then
        missing+=("openssl")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "❌ Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo "   - $dep"
        done
        echo ""
        echo "Please install the missing dependencies and try again."
        exit 1
    fi

    echo "✅ All prerequisites satisfied (openssl)"
}

check_prerequisites

# Check for required privileges
if [ "$IS_WINDOWS" = true ]; then
    # On Windows: check if running as Administrator
    if ! net.exe session > /dev/null 2>&1; then
        echo "❌ This script must be run as Administrator on Windows."
        echo "   Right-click your terminal and select 'Run as administrator', then try again."
        exit 1
    fi
    echo "✅ Running as Administrator"
else
    # On Linux: check if running as root, escalate via sudo if needed
    if [ "$EUID" -ne 0 ]; then
        echo "⚠️ Not running as root. Requesting elevation..."
        args=""
        [ "$SKIP_CA_VALIDATION" = true ] && args="$args --skip-ca-validation"
        [ "$CLEAN" = true ]             && args="$args --clean"
        [ "$UPDATE" = true ]            && args="$args --update"
        [ "$GEN_CERTS" = false ]        && args="$args --no-cert-gen"
        if command -v sudo &> /dev/null; then
            sudo "$0" $args
            exit $?
        else
            echo "❌ sudo not available. Please run this script as root."
            exit 1
        fi
    fi
    echo "✅ Running as root"
fi

# Set working directory to the script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"
echo "📂 Script is running from: $SCRIPT_DIR"

# Build .env first so docker compose commands always have variables available
# Backup .env if it exists, then remove it
if [ -f ".env" ]; then
    cp ".env" ".env.backup"
    echo "💾 Backed up existing .env to .env.backup"
    rm -f ".env"
    echo "🧹 Removed existing .env"
fi

# Build .env from env.template
if [ ! -f "env.template" ]; then
    echo "❌ env.template not found. Cannot create .env."
    exit 1
fi

cp "env.template" ".env"
sed -i 's/\r//' ".env"  # strip CRLF in case env.template has Windows line endings
echo "✅ Created .env from env.template"

# Apply env.local overrides if it exists (user-specific configuration, not tracked in git)
if [ -f "env.local" ]; then
    echo "📝 Applying env.local overrides..."
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            key=$(echo "$key" | xargs)
            if grep -q "^${key}=" ".env"; then
                sed -i "s|^${key}=.*|${line}|" ".env"
            else
                echo "$line" >> ".env"
            fi
        fi
    done < "env.local"
    echo "✅ env.local overrides applied"
fi

# Append certificate placeholder variables (auto-injected later by certificate logic)
cat >> ".env" << 'EOF'

# Certificate variables (auto-generated — do not edit manually)
DVLS_CERT_CRT_B64=""
DVLS_CERT_KEY_B64=""
DVLS_CA_CERT_B64=""
GTW_TLS_CERTIFICATE_B64=""
GTW_TLS_PRIVATE_KEY_B64=""
GTW_PROVISIONER_PUBLIC_KEY_B64=""
GTW_PROVISIONER_PRIVATE_KEY_B64=""
EOF
echo "✅ Certificate placeholder variables added to .env"

# Clean data folders if requested (after .env is ready so docker compose has variables)
if [ "$CLEAN" = true ]; then
    bash "$SCRIPT_DIR/clean.sh"
fi

if [ "$IS_WINDOWS" = false ]; then
    chown -R 10001:10001 ./data-sql # mssql user
    chown -R 1000:1000 ./data-dvls # ubuntu user
fi

# Clean tmp folder
if [ -d "./tmp" ]; then
    rm -rf "./tmp"
    echo "🧹 Cleaned tmp folder"
fi

# Update containers if requested
if [ "$UPDATE" = true ]; then
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
TEST_CERTS_CA_KEY="$SCRIPT_DIR/Certificates/ca.key"

# Check which certificates exist individually
USE_CA_CERT=true
USE_DVLS_CERTS=true
USE_GATEWAY_CERTS=true
USE_PROVISIONER_KEYS=true

[ ! -f "$TEST_CERTS_CA" ]               && USE_CA_CERT=false
[ ! -f "$TEST_CERTS_CA_KEY" ]           && USE_CA_CERT=false  # ca.key needed to sign new certs
[ ! -f "$TEST_CERTS_DVLS_CRT" ]         && USE_DVLS_CERTS=false
[ ! -f "$TEST_CERTS_DVLS_KEY" ]         && USE_DVLS_CERTS=false
[ ! -f "$TEST_CERTS_GATEWAY_CRT" ]      && USE_GATEWAY_CERTS=false
[ ! -f "$TEST_CERTS_GATEWAY_KEY" ]      && USE_GATEWAY_CERTS=false
[ ! -f "$TEST_CERTS_PROVISIONER_PUB" ]  && USE_PROVISIONER_KEYS=false
[ ! -f "$TEST_CERTS_PROVISIONER_PRIV" ] && USE_PROVISIONER_KEYS=false

# Derived: server certs = CA + DVLS + Gateway all present
USE_SERVER_CERTIFICATES=true
[ "$USE_CA_CERT" = false ]       && USE_SERVER_CERTIFICATES=false
[ "$USE_DVLS_CERTS" = false ]    && USE_SERVER_CERTIFICATES=false
[ "$USE_GATEWAY_CERTS" = false ] && USE_SERVER_CERTIFICATES=false

# All certificates exist if server certs and provisioner keys are all present
USE_TEST_CERTIFICATES=true
[ "$USE_SERVER_CERTIFICATES" = false ] && USE_TEST_CERTIFICATES=false
[ "$USE_PROVISIONER_KEYS" = false ]    && USE_TEST_CERTIFICATES=false

# Function to convert file to base64
file_to_base64() {
    base64 -w 0 "$1"
}

# Function to update .env file with a key=value pair
update_env_cert() {
    local key="$1"
    local value="$2"
    sed -i "s|^${key}\s*=.*|${key}=\"${value}\"|" .env
}

# Function to inject all certificates from Certificates/ into .env
inject_certificates() {
    local dvls_crt_b64 dvls_key_b64 gateway_crt_b64 gateway_key_b64
    local provisioner_pub_b64 provisioner_priv_b64 ca_b64

    dvls_crt_b64=$(file_to_base64 "$TEST_CERTS_DVLS_CRT")
    dvls_key_b64=$(file_to_base64 "$TEST_CERTS_DVLS_KEY")
    gateway_crt_b64=$(file_to_base64 "$TEST_CERTS_GATEWAY_CRT")
    gateway_key_b64=$(file_to_base64 "$TEST_CERTS_GATEWAY_KEY")
    provisioner_pub_b64=$(file_to_base64 "$TEST_CERTS_PROVISIONER_PUB")
    provisioner_priv_b64=$(file_to_base64 "$TEST_CERTS_PROVISIONER_PRIV")
    ca_b64=$(file_to_base64 "$TEST_CERTS_CA")

    update_env_cert "DVLS_CERT_CRT_B64" "$dvls_crt_b64"
    update_env_cert "DVLS_CERT_KEY_B64" "$dvls_key_b64"
    update_env_cert "DVLS_CA_CERT_B64" "$ca_b64"
    update_env_cert "GTW_TLS_CERTIFICATE_B64" "$gateway_crt_b64"
    update_env_cert "GTW_TLS_PRIVATE_KEY_B64" "$gateway_key_b64"
    update_env_cert "GTW_PROVISIONER_PUBLIC_KEY_B64" "$provisioner_pub_b64"
    update_env_cert "GTW_PROVISIONER_PRIVATE_KEY_B64" "$provisioner_priv_b64"

    echo "✅ Certificates injected into .env"
}

GENERATE_SCRIPT="$SCRIPT_DIR/Generate-Certificates.sh"

if [ "$GEN_CERTS" = false ]; then
    # --no-cert-gen mode: Use existing certificates only, no generation at all
    echo "⚠️ Certificate generation disabled (--no-cert-gen flag)"

    if [ "$USE_SERVER_CERTIFICATES" = false ]; then
        echo "❌ Server certificates (DVLS, Gateway, CA) not found in Certificates folder"
        echo "   Cannot run with --no-cert-gen flag without existing server certificates"
        echo "   Either:"
        echo "   1. Remove the --no-cert-gen flag to generate all certificates, or"
        echo "   2. Place existing server certificates in the Certificates folder"
        exit 1
    fi

    echo "✅ Found server certificates in Certificates folder"

    if [ "$USE_PROVISIONER_KEYS" = false ]; then
        echo "❌ Provisioner keys not found in Certificates folder"
        echo "   Cannot run with --no-cert-gen flag without existing provisioner keys"
        echo "   Either:"
        echo "   1. Remove the --no-cert-gen flag to generate all certificates and keys, or"
        echo "   2. Place existing provisioner keys in the Certificates folder"
        exit 1
    fi

    echo "✅ Found provisioner keys in Certificates folder"

    inject_certificates
    import_dotenv ".env"

elif [ "$USE_TEST_CERTIFICATES" = true ]; then
    # GEN_CERTS is true and all certificates already exist — reuse them
    echo "🔐 Found all certificates in Certificates folder, using those..."
    inject_certificates
    import_dotenv ".env"

else
    # GEN_CERTS is true and some certificates are missing — generate only what's needed
    if [ ! -f "$GENERATE_SCRIPT" ]; then
        echo "❌ Generate-Certificates.sh not found at $GENERATE_SCRIPT"
        exit 1
    fi

    run_generate() {
        local flags="$1"
        pushd "$SCRIPT_DIR" > /dev/null
        bash "$GENERATE_SCRIPT" $flags
        local exit_code=$?
        popd > /dev/null
        if [ $exit_code -ne 0 ]; then
            echo "❌ Generate-Certificates.sh failed with exit code $exit_code"
            exit 1
        fi
    }

    if [ "$USE_CA_CERT" = false ] || [ "$USE_DVLS_CERTS" = false ]; then
        # CA or DVLS missing — must regenerate full set (CA + DVLS + GTW)
        echo "⚠️ CA or DVLS certificates missing — generating full certificate set..."
        run_generate ""
        echo "✅ All certificates generated successfully"

    elif [ "$USE_GATEWAY_CERTS" = false ]; then
        # Only Gateway certs missing — preserve existing CA + DVLS
        echo "⚠️ Gateway certificates missing — generating Gateway certs only..."
        run_generate "--gateway-only"
        echo "✅ Gateway certificates generated successfully"

    elif [ "$USE_PROVISIONER_KEYS" = false ]; then
        # Only provisioner keys missing
        echo "⚠️ Provisioner keys missing — generating provisioner keys only..."
        run_generate "--provisioner-only"
        echo "✅ Provisioner keys generated successfully"
    fi

    # Verify all certificates are now present
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

    inject_certificates
    import_dotenv ".env"
fi

# Check and import CA certificate if not trusted
if [ "$SKIP_CA_VALIDATION" = false ]; then
    CA_CERT_PATH="$SCRIPT_DIR/Certificates/ca.crt"
    if [ -f "$CA_CERT_PATH" ]; then
        # Get certificate info using openssl
        CA_SUBJECT=$(openssl x509 -in "$CA_CERT_PATH" -noout -subject 2>/dev/null | sed 's/subject=//')
        CA_FINGERPRINT=$(openssl x509 -in "$CA_CERT_PATH" -noout -fingerprint 2>/dev/null | sed 's/SHA1 Fingerprint=//')

        echo "📋 CA Certificate Info:"
        echo "   Subject: $CA_SUBJECT"
        echo "   Fingerprint: $CA_FINGERPRINT"

        if [ "$IS_WINDOWS" = true ]; then
            # Windows: use certutil to install into the Root store
            CA_CERT_WIN=$(cygpath -w "$CA_CERT_PATH")
            EXISTING=$(certutil.exe -store Root 2>/dev/null | grep -i "${CA_FINGERPRINT//:}" || true)
            if [ -n "$EXISTING" ]; then
                echo "✅ CA certificate is already trusted on this machine"
            else
                echo "🔐 Installing CA certificate to Windows Root store..."
                if certutil.exe -addstore Root "$CA_CERT_WIN" > /dev/null 2>&1; then
                    echo "✅ CA certificate installed successfully (Windows Root store)"
                    echo "   ℹ️  Chrome/Edge will trust it automatically."
                    echo "   ℹ️  Firefox: go to about:config and set security.enterprise_roots.enabled=true"
                    echo "   ℹ️  Or import $CA_CERT_WIN manually in Firefox → Settings → View Certificates → Authorities"
                else
                    echo "⚠️ Failed to install CA certificate. Try running as Administrator."
                fi
            fi
        # Check if CA is already trusted (Debian/Ubuntu)
        elif [ -d "/usr/local/share/ca-certificates" ]; then
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

# Check and add gateway hostname to hosts file
HOSTS_PATH="/etc/hosts"
if [ -f "$HOSTS_PATH" ]; then
    if grep -qE "^\s*127\.0\.0\.1\s+.*${GTW_HOSTNAME}" "$HOSTS_PATH"; then
        echo "✅ ${GTW_HOSTNAME} is mapped to 127.0.0.1 in hosts file"
    else
        echo "⚠️ ${GTW_HOSTNAME} is NOT in hosts file. Adding it now..."
        echo "127.0.0.1 ${GTW_HOSTNAME}" >> "$HOSTS_PATH"
        echo "✅ Successfully added ${GTW_HOSTNAME} to hosts file"
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

# Sync the Gateway certificate thumbprint in the database.
# The pre-seeded SQL image has a fixed thumbprint; every cert regeneration produces a new one.
# We update the DB after startup so DVLS can verify the Gateway's TLS cert.
GTW_THUMBPRINT=$(openssl x509 -in "$TEST_CERTS_GATEWAY_CRT" -noout -fingerprint -sha1 2>/dev/null \
    | sed 's/.*=//' | tr -d ':' | tr 'a-f' 'A-F')

if [ -n "$GTW_THUMBPRINT" ]; then
    echo "🔑 Syncing Gateway certificate thumbprint in database ($GTW_THUMBPRINT)..."
    # By the time docker compose up -d returns, sqlserver_db is healthy (DVLS depends_on it).
    # Use the DVLS SQL user (least-privilege) if available, otherwise SA.
    if docker compose exec -T sqlserver_db \
        /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "$SQL_MSSQL_PASSWORD" \
        -d dvls_docker \
        -Q "UPDATE DevolutionsGateway SET CertificateThumbprint='$GTW_THUMBPRINT'" \
        -C > /dev/null 2>&1; then
        echo "✅ Gateway certificate thumbprint updated"
    else
        echo "⚠️ Could not update Gateway thumbprint — Gateway connections may fail until certs match"
    fi
fi
