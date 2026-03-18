# Requirements

- Docker with Linux containers
- OpenSSL (for certificate generation)

# Setup

> **Warning**
> We advise changing the variable values in the `env.template` file before running. It is your responsibility to secure those variables.
> Do not use the default provided values.

Copy `env.template` to `env.local` if you want to override specific values without touching the template (see [env.local overrides](#envlocal-overrides)).

# Run

Run this bash script to start the Devolutions Server Linux containers.

**Linux:**
```bash
chmod +x run.sh alpine-ssh/startup.sh dc1.ad.lab/entrypoint.sh
sudo ./run.sh [--clean] [--update] [--skip-ca-validation] [--no-cert-gen]
```

**Windows (Git Bash / MSYS2 — run as Administrator):**
```bash
./run.sh [--clean] [--update] [--skip-ca-validation] [--no-cert-gen]
```

### Optional arguments

| Flag | Description |
|------|-------------|
| `--clean` | Stops containers, wipes `data-sql`/`data-dvls` for a fresh start |
| `--update` | Pulls the latest Docker images before starting |
| `--skip-ca-validation` | Skips installing the CA certificate into the system trust store |
| `--no-cert-gen` | Skips certificate generation entirely — existing certificates in `Certificates/` are used as-is |

To access the server go to https://localhost:5544

# Certificate management

Certificates are stored in the `Certificates/` folder (gitignored). The script automatically:

1. **Generates** a self-signed CA, DVLS server cert, Gateway server cert, and provisioner key pair on first run
2. **Reuses** existing certificates on subsequent runs (no regeneration unless files are missing)
3. **Partial regeneration** — if only some certificates are missing, only the missing ones are regenerated:
   - CA or DVLS missing → full regeneration
   - Only Gateway certs missing → `--gateway-only` (re-signs against existing CA)
   - Only provisioner keys missing → `--provisioner-only`
4. **Injects** all certificates into `.env` as Base64-encoded variables at runtime
5. **Installs** the CA certificate into the system trust store (Linux: `update-ca-certificates` / `update-ca-trust`, Windows: `certutil`)
6. **Configures Firefox** automatically on both Windows and Linux to trust the system CA store (no manual import needed)

To force a full certificate regeneration, delete the `Certificates/` folder and rerun.

# env.local overrides

Create an `env.local` file (gitignored) to override specific variables from `env.template` without modifying the template:

```bash
# env.local — personal overrides, never committed
SQL_MSSQL_PASSWORD=MyCustomPassword123
GTW_HOSTNAME=gateway.custom
```

Values in `env.local` take precedence over `env.template`. Certificate B64 variables are always injected automatically and should not be set manually.

# .env file documentation

The `.env` file is rebuilt from `env.template` (+ `env.local` overrides) on every run. **Do not edit `.env` directly** — changes will be overwritten.

### Configurable variables (in `env.template` / `env.local`)

| Variable | Description |
|----------|-------------|
| `SQL_MSSQL_USER` | SQL Server admin username |
| `SQL_MSSQL_PASSWORD` | SQL Server admin password (also used as SA password) |
| `SQL_DVLS_USER` | DVLS database username |
| `SQL_DVLS_PASSWORD` | DVLS database password |
| `SQL_WHITELISTED_ORIGINS` | DVLS origins whitelist (JSON array) |
| `DVLS_CONNECTION_STRING` | ADO.NET connection string for DVLS to reach the database |
| `DVLS_CERT_CONFIG` | Set to `0` to disable built-in TLS (use a reverse proxy instead) |
| `DVLS_DECRYPTED_ENCRYPTION_CONFIG_B64` | Base64-encoded decrypted `encryption.config` (DPAPI-unprotected) |
| `GTW_HOSTNAME` | Gateway hostname added to the hosts file (default: `gateway.loc`) |

### Auto-injected variables (do not set manually)

These are populated at runtime from files in `Certificates/`:

| Variable | Source file |
|----------|-------------|
| `DVLS_CERT_CRT_B64` | `Certificates/dvls.crt` |
| `DVLS_CERT_KEY_B64` | `Certificates/dvls.key` |
| `DVLS_CA_CERT_B64` | `Certificates/ca.crt` |
| `GTW_TLS_CERTIFICATE_B64` | `Certificates/gtw.crt` |
| `GTW_TLS_PRIVATE_KEY_B64` | `Certificates/gtw.key` |
| `GTW_PROVISIONER_PUBLIC_KEY_B64` | `Certificates/gtw-provisioner.pem` |
| `GTW_PROVISIONER_PRIVATE_KEY_B64` | `Certificates/gtw-provisioner.key` |

# Changelog

- 17/03/2026 - Improved .env management, certificate handling, and Windows compatibility
- 04/03/2026 - Updated containers to v2026.1.6.0
- 28/01/2026 - Updated containers to v2025.3.14.0
- 23/10/2025 - Updated containers to v2025.3.4.0
- 23/09/2025 - Updated containers to v2025.2.12.0
- 15/07/2025 - Updated containers to v2025.2.5.0
- 15/07/2025 - Updated containers to v2025.2.4.0
