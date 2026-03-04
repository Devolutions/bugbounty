#!/bin/sh
SMB_CONF="/usr/local/samba/etc/smb.conf"
PRIVATE_DIR="/usr/local/samba/private"
SAM_LDB="$PRIVATE_DIR/sam.ldb"

# Fixed domain SID for consistent user SIDs across container recreations
FIXED_DOMAIN_SID="S-1-5-21-1000000000-2000000000-3000000000"

# Provision only if DB missing, using fixed domain SID
if [ ! -f "$SAM_LDB" ]; then
  echo "[entrypoint] sam.ldb missing -> provisioning with fixed domain SID: $FIXED_DOMAIN_SID"

  # Wait for network interface
  until ip a | grep BROADCAST >/dev/null 2>&1; do
    echo "[entrypoint] Waiting for network interface..."
    sleep 1
  done

  INTERFACE=$(ip a | grep BROADCAST | head -n1 | awk '{print $2}' | sed 's/://')

  samba-tool domain provision \
    --server-role=dc \
    --use-rfc2307 \
    --dns-backend=SAMBA_INTERNAL \
    --realm="${REALM}" \
    --domain="${DOMAIN}" \
    --adminpass="${ADMIN_PASS}" \
    --domain-sid="$FIXED_DOMAIN_SID" \
    --option="dns forwarder=${DNS_FORWARDER}" \
    --option="interfaces=lo ${INTERFACE}" \
    --option="bind interfaces only=no"

  echo "[entrypoint] Domain provisioned with fixed SID: $FIXED_DOMAIN_SID"
fi

# Ensure smb.conf exists
if [ ! -f "$SMB_CONF" ]; then
  echo "[entrypoint] ERROR: smb.conf not found at $SMB_CONF"
  exit 1
fi

# Force tools to use same config
export SAMBA_CONF_PATH="$SMB_CONF"

# (You insisted) add the line, idempotent
if ! grep -q '^ad dc functional level = 2016$' "$SMB_CONF" 2>/dev/null; then
  sed -i '/^\[global\]/a ad dc functional level = 2016' "$SMB_CONF" || true
  echo "[entrypoint] Inserted functional level line under [global]"
fi

# Fix interface binding to listen on all interfaces, not just localhost
if grep -q '^\s*bind interfaces only = Yes' "$SMB_CONF" 2>/dev/null; then
  sed -i 's/^\s*bind interfaces only = Yes/\tbind interfaces only = No/' "$SMB_CONF"
  echo "[entrypoint] Changed 'bind interfaces only' to No"
fi

echo "[entrypoint] Starting Samba..."
samba -i -M single -s "$SMB_CONF" &
SAMBA_PID=$!

# Forward signals so docker stop works nicely
trap 'kill -TERM "$SAMBA_PID" 2>/dev/null || true' INT TERM

echo "[entrypoint] Waiting for Samba AD to be ready..."
sleep 5

echo "[entrypoint] Raising level..."
samba-tool domain level raise --domain-level=2016 2>&1 || echo "[entrypoint] Domain level already at target"
samba-tool domain level raise --forest-level=2016 2>&1 || echo "[entrypoint] Forest level already at target"

# Fix entryTTL attribute to allow JIT elevation (remove constructed flag)
echo "[entrypoint] Fixing entryTTL attribute for JIT elevation support..."
ldbmodify -H /usr/local/samba/private/sam.ldb --option='dsdb:schema update allowed=true' << 'LDIF_EOF' 2>/dev/null && echo "[entrypoint] entryTTL attribute fixed (systemFlags: 20 -> 16)" || echo "[entrypoint] entryTTL already fixed"
dn: CN=Entry-TTL,CN=Schema,CN=Configuration,DC=ad,DC=lab
changetype: modify
replace: systemFlags
systemFlags: 16
LDIF_EOF

# Provision test users and groups for PAM testing with STATIC SIDs
echo "[entrypoint] Provisioning test users and groups with fixed SIDs..."

# Helper function to create user with fixed RID using LDIF
create_user_with_rid() {
  local username="$1"
  local firstname="$2"
  local lastname="$3"
  local rid="$4"
  local password_hash="$5"  # Pre-hashed password

  # Check if user already exists
  if ldbsearch -H /usr/local/samba/private/sam.ldb -b "DC=ad,DC=lab" "(sAMAccountName=$username)" dn 2>/dev/null | grep -q "^dn:"; then
    echo "[entrypoint] User $username already exists"
    return 1
  fi

  # Use samba-tool with --use-username-as-cn to have more control
  # Note: Samba auto-assigns RIDs sequentially, so we create in order to get consistent RIDs
  samba-tool user create "$username" "Admin@2024!" --given-name="$firstname" --surname="$lastname" --use-username-as-cn 2>/dev/null

  # Get the actual SID assigned
  USER_SID=$(ldbsearch -H /usr/local/samba/private/sam.ldb -b "DC=ad,DC=lab" "(sAMAccountName=$username)" objectSid 2>/dev/null | grep '^objectSid:' | awk '{print $2}')
  echo "[entrypoint] Created user: $username (SID: $USER_SID)"
}

# Create test groups (in order for consistent RIDs)
for group in IT_Staff Finance Developers HR; do
  samba-tool group add "$group" 2>/dev/null && echo "[entrypoint] Created group: $group" || echo "[entrypoint] Group $group already exists"
done

# Create administrator users (always create in same order for consistent RIDs)
declare -a ADMINS=(
  "john.smith:John:Smith"
  "sarah.jones:Sarah:Jones"
  "michael.brown:Michael:Brown"
)

for admin_entry in "${ADMINS[@]}"; do
  IFS=':' read -r username firstname lastname <<< "$admin_entry"
  create_user_with_rid "$username" "$firstname" "$lastname" "" ""
  samba-tool group addmembers "Domain Admins" "$username" 2>/dev/null && echo "[entrypoint] Added $username to Domain Admins"
done

# Create regular users (in order)
declare -a USERS=(
  "alice.johnson:Alice:Johnson:IT_Staff,Developers"
  "robert.williams:Robert:Williams:Finance"
  "emily.davis:Emily:Davis:HR"
)

for user_entry in "${USERS[@]}"; do
  IFS=':' read -r username firstname lastname groups <<< "$user_entry"
  create_user_with_rid "$username" "$firstname" "$lastname" "" ""

  # Add user to their groups
  IFS=',' read -ra GROUP_ARRAY <<< "$groups"
  for group in "${GROUP_ARRAY[@]}"; do
    samba-tool group addmembers "$group" "$username" 2>/dev/null && echo "[entrypoint] Added $username to $group"
  done
done

echo "[entrypoint] User and group provisioning complete!"

# Keep container running without restarting samba
wait "$SAMBA_PID"