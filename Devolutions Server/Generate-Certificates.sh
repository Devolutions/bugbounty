#!/bin/bash

# Certificate Generation Script
# Generates a Certificate Authority and two server certificates (DVLS + Gateway)

# Set working directory to Certificates folder
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
CERT_OUTPUT_DIR="$SCRIPT_DIR/Certificates"

# Create Certificates folder if it doesn't exist
if [ ! -d "$CERT_OUTPUT_DIR" ]; then
    mkdir -p "$CERT_OUTPUT_DIR"
fi

cd "$CERT_OUTPUT_DIR"
echo "📂 Certificates will be generated in: $CERT_OUTPUT_DIR"

# Configuration
CA_DAYS=10950  # ~30 years (maximum practical lifespan)
SERVER_DAYS=10950  # ~30 years
DVLS_HOSTNAME="localhost"
GATEWAY_HOSTNAME="gateway.loc"

# Clean existing certificate files (both old and new naming conventions)
CERT_FILES=(
    "ca.key" "ca.crt" "ca.srl"
    "dvls-server.key" "dvls-server.csr" "dvls-server.crt" "dvls-server.pfx" "dvls-server.pfx.b64"
    "dvls.key" "dvls.crt"
    "gateway-server.key" "gateway-server.csr" "gateway-server.crt" "gateway-server.pfx" "gateway-server.pfx.b64"
    "gtw.key" "gtw.crt"
    "provisioner.key" "provisioner.pem" "provisioner.key.b64" "provisioner.pem.b64"
    "gtw-provisioner.key" "gtw-provisioner.pem"
    "dvls-ca.crt"
)

for file in "${CERT_FILES[@]}"; do
    if [ -f "./$file" ]; then
        rm -f "./$file"
    fi
done
echo "🧹 Cleaned existing certificate and key files"

echo ""
echo "🔐 Generating Certificate Authority..."

# Generate CA private key
openssl ecparam -name prime256v1 -genkey -noout -out ./ca.key
echo "✅ CA private key generated"

# Generate CA certificate (self-signed)
openssl req -new -x509 -sha256 -key ./ca.key -out ./ca.crt \
    -subj "/CN=DVLS Certificate Authority/O=DVLS/ST=QC/C=CA" \
    -days $CA_DAYS
CA_YEARS=$(awk "BEGIN {printf \"%.1f\", $CA_DAYS/365}")
echo "✅ CA certificate generated (valid for $CA_DAYS days / ~$CA_YEARS years)"

echo ""
echo "🔐 Generating DVLS Server Certificate..."

# Generate DVLS server private key
openssl ecparam -name prime256v1 -genkey -noout -out ./dvls-server.key
echo "✅ DVLS server private key generated"

# Create OpenSSL config for DVLS SAN
cat > ./dvls-san.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $DVLS_HOSTNAME
O = DVLS
ST = QC
C = CA

[v3_req]
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DVLS_HOSTNAME
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

# Generate DVLS server CSR with SAN
openssl req -new -sha256 -key ./dvls-server.key -out ./dvls-server.csr \
    -config ./dvls-san.cnf
echo "✅ DVLS server CSR generated with SAN"

# Sign DVLS server certificate with CA and include SAN extensions
openssl x509 -req -in ./dvls-server.csr \
    -CA ./ca.crt -CAkey ./ca.key -CAcreateserial \
    -out ./dvls-server.crt \
    -days $SERVER_DAYS -sha256 \
    -extensions v3_req -extfile ./dvls-san.cnf
SERVER_YEARS=$(awk "BEGIN {printf \"%.1f\", $SERVER_DAYS/365}")
echo "✅ DVLS server certificate signed with SAN (valid for $SERVER_DAYS days / ~$SERVER_YEARS years)"

# Clean up config file
rm -f ./dvls-san.cnf

# Export DVLS certificate to PFX (without password)
openssl pkcs12 -export -out ./dvls-server.pfx \
    -inkey ./dvls-server.key -in ./dvls-server.crt \
    -certfile ./ca.crt \
    -passout pass:
echo "✅ DVLS server certificate exported to PFX"

echo ""
echo "🔐 Generating Gateway Server Certificate..."

# Generate Gateway server private key
openssl ecparam -name prime256v1 -genkey -noout -out ./gateway-server.key
echo "✅ Gateway server private key generated"

# Create OpenSSL config for Gateway SAN
cat > ./gateway-san.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $GATEWAY_HOSTNAME
O = DVLS
ST = QC
C = CA

[v3_req]
keyUsage = digitalSignature, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $GATEWAY_HOSTNAME
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

# Generate Gateway server CSR with SAN
openssl req -new -sha256 -key ./gateway-server.key -out ./gateway-server.csr \
    -config ./gateway-san.cnf
echo "✅ Gateway server CSR generated with SAN"

# Sign Gateway server certificate with CA and include SAN extensions
openssl x509 -req -in ./gateway-server.csr \
    -CA ./ca.crt -CAkey ./ca.key -CAcreateserial \
    -out ./gateway-server.crt \
    -days $SERVER_DAYS -sha256 \
    -extensions v3_req -extfile ./gateway-san.cnf
echo "✅ Gateway server certificate signed with SAN (valid for $SERVER_DAYS days / ~$SERVER_YEARS years)"

# Clean up config file
rm -f ./gateway-san.cnf

# Export Gateway certificate to PFX (without password)
openssl pkcs12 -export -out ./gateway-server.pfx \
    -inkey ./gateway-server.key -in ./gateway-server.crt \
    -certfile ./ca.crt \
    -passout pass:
echo "✅ Gateway server certificate exported to PFX"

echo ""
echo "🔐 Generating Gateway Provisioner Key Pair..."

# Generate provisioner private key (RSA 2048-bit) in PKCS#1 format
openssl genrsa -traditional -out ./provisioner.key 2048 2>/dev/null
echo "✅ Provisioner private key generated (PKCS#1 format)"

# Extract public key from private key
openssl rsa -in ./provisioner.key -pubout -out ./provisioner.pem 2>/dev/null
echo "✅ Provisioner public key extracted"

echo ""
echo "📊 Certificate Generation Summary:"
echo "=================================="
echo "Certificate Authority:"
echo "  - CA Certificate: ca.crt"
echo "  - Validity: $CA_DAYS days (~$CA_YEARS years)"
echo ""
echo "DVLS Server Certificate:"
echo "  - Hostname: $DVLS_HOSTNAME"
echo "  - Certificate: dvls.crt"
echo "  - Private Key: dvls.key"
echo "  - Validity: $SERVER_DAYS days (~$SERVER_YEARS years)"
echo ""
echo "Gateway Server Certificate:"
echo "  - Hostname: $GATEWAY_HOSTNAME"
echo "  - Certificate: gtw.crt"
echo "  - Private Key: gtw.key"
echo "  - Validity: $SERVER_DAYS days (~$SERVER_YEARS years)"
echo ""
echo "Gateway Provisioner Key Pair:"
echo "  - Public Key: gtw-provisioner.pem"
echo "  - Private Key: gtw-provisioner.key"
echo ""
echo "⚠️  IMPORTANT: Install the CA certificate (ca.crt) in your trusted root store"
echo "⚠️  Add '$GATEWAY_HOSTNAME' to your hosts file pointing to 127.0.0.1"
echo ""
echo "✅ All certificates generated successfully!"

# Optional: Convert PFX to base64 for easy embedding
echo ""
echo "📝 Base64 Encoded Certificates:"
echo "=================================="

DVLS_PFX_BASE64=$(base64 -w 0 "$CERT_OUTPUT_DIR/dvls-server.pfx")
echo ""
echo "DVLS Server PFX (Base64):"
echo "$DVLS_PFX_BASE64"

GATEWAY_PFX_BASE64=$(base64 -w 0 "$CERT_OUTPUT_DIR/gateway-server.pfx")
echo ""
echo "Gateway Server PFX (Base64):"
echo "$GATEWAY_PFX_BASE64"

PROVISIONER_PUB_BASE64=$(base64 -w 0 "$CERT_OUTPUT_DIR/provisioner.pem")
echo ""
echo "Provisioner Public Key (Base64):"
echo "$PROVISIONER_PUB_BASE64"

PROVISIONER_PRIV_BASE64=$(base64 -w 0 "$CERT_OUTPUT_DIR/provisioner.key")
echo ""
echo "Provisioner Private Key (Base64):"
echo "$PROVISIONER_PRIV_BASE64"

# Save base64 to files for easy reference
echo "$DVLS_PFX_BASE64" > ./dvls-server.pfx.b64
echo "$GATEWAY_PFX_BASE64" > ./gateway-server.pfx.b64
echo "$PROVISIONER_PUB_BASE64" > ./provisioner.pem.b64
echo "$PROVISIONER_PRIV_BASE64" > ./provisioner.key.b64
echo ""
echo "✅ Base64 encoded certificates and keys saved to .b64 files"

echo ""
echo "🔄 Renaming certificates to match .env naming convention..."

# CA certificate stays as ca.crt (used by both DVLS and Gateway)

# Rename DVLS server certificate and key
if [ -f ./dvls-server.crt ]; then
    mv -f ./dvls-server.crt ./dvls.crt
    echo "✅ dvls-server.crt → dvls.crt"
fi
if [ -f ./dvls-server.key ]; then
    mv -f ./dvls-server.key ./dvls.key
    echo "✅ dvls-server.key → dvls.key"
fi

# Rename Gateway server certificate and key
if [ -f ./gateway-server.crt ]; then
    mv -f ./gateway-server.crt ./gtw.crt
    echo "✅ gateway-server.crt → gtw.crt"
fi
if [ -f ./gateway-server.key ]; then
    mv -f ./gateway-server.key ./gtw.key
    echo "✅ gateway-server.key → gtw.key"
fi

# Rename provisioner key pair
if [ -f ./provisioner.pem ]; then
    mv -f ./provisioner.pem ./gtw-provisioner.pem
    echo "✅ provisioner.pem → gtw-provisioner.pem"
fi
if [ -f ./provisioner.key ]; then
    mv -f ./provisioner.key ./gtw-provisioner.key
    echo "✅ provisioner.key → gtw-provisioner.key"
fi

echo ""
echo "🧹 Removing unused certificate files..."

# Remove unused files (CSR, PFX, base64 files, CA private key and serial)
UNUSED_FILES=(
    "ca.key"                   # CA private key (not needed for deployment)
    "ca.srl"                   # CA serial number file (not needed for deployment)
    "dvls-server.csr"          # Certificate signing request (not needed after signing)
    "gateway-server.csr"       # Certificate signing request (not needed after signing)
    "gateway-server.pfx"       # PFX bundle (not used)
    "gateway-server.pfx.b64"   # Base64 PFX (not used)
    "provisioner.key.b64"      # Base64 provisioner private key (not used)
    "provisioner.pem.b64"      # Base64 provisioner public key (not used)
)

for file in "${UNUSED_FILES[@]}"; do
    if [ -f "./$file" ]; then
        rm -f "./$file"
        echo "🗑️  Removed $file"
    fi
done

echo ""
echo "✅ Certificate files renamed and cleaned up successfully!"
echo ""
echo "📁 Final certificate files in ${CERT_OUTPUT_DIR}:"
echo "   - ca.crt (CA certificate - used by both DVLS and Gateway)"
echo "   - dvls.crt (DVLS server certificate)"
echo "   - dvls.key (DVLS server private key)"
echo "   - gtw.crt (Gateway server certificate)"
echo "   - gtw.key (Gateway server private key)"
echo "   - gtw-provisioner.pem (Gateway provisioner public key)"
echo "   - gtw-provisioner.key (Gateway provisioner private key)"
