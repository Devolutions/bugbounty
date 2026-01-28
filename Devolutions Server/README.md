# Requirements
- Docker with Linux containers.
- Openssl to generate certificates

# Setup

> **Warning**
> We advise changing the variable values in the *.env* file or use any other way. It is your responsability to secure those variables.
> Do not use the default provided values.

# Run

Run this bash script to start the Devolutions Server Linux dockers.

```
chmod +x .\run.sh
chmod +x alpine-ssh/startup.sh
.\run.sh [clean] [update] [skip-ca-validation] [no-cert-gen]
```

### Optional arguments
- `clean` : Clears the container data for a fresh start
- `update` : Pulls the latest Docker images before starting.
- `skip-ca-validation` : Skips the validation of CA
- `no-cert-gen` : Does not generate certificate for DVLS and Gateway (LetsEncrypt certificates must be given) 
    - Configure your certificates via a symlink directly inside Certificates directory

To access the server go to https://localhost:5544

### .env file documentation

| Variable Name                          | Description                                                                                                                    |
|----------------------------------------|--------------------------------------------------------------------------------------------------------------------------------|
| `SQL_MSSQL_USER`                       | Database user to use.                                                                                                          |
| `SQL_MSSQL_PASSWORD`                   | Database user password to use.                                                                                                 |
| `SQL_DVLS_USER`                        | DVLS user to configure in the database.                                                                                        |
| `SQL_DVLS_PASSWORD`                    | DVLS user password to configure in the database.                                                                               |
| `SQL_WHITELISTED_ORIGINS`              | DVLS origins whitelist to configure in the database.                                                                           |
| `DVLS_CONNECTION_STRING`               | Connection string for DVLS to connect to the database.                                                                         |
| `DVLS_CERT_CONFIG`                     | If set to `0`, you must provide your own certificate through a reverse proxy like nginx.                                       |
| `DVLS_DECRYPTED_ENCRYPTION_CONFIG_B64` | Base64-encoded decrypted version of `encryption.config` (DPAPI unprotected).                                                   |
| `DVLS_CERT_CRT_B64`                    | Base64-encoded .crt file for DVLS                                                                                              |
| `DVLS_CERT_KEY_B64`                    | Base64-encoded .key file for DVLS                                                                                              |
| `DVLS_CA_CERT_B64`                     | Base64-encoded .ca file for DVLS and Gateway                                                                                   |
| `GTW_PROVISIONER_PUBLIC_KEY_B64`       | Base64-encoded .pem file for Gateway                                                                                           |
| `GTW_PROVISIONER_PRIVATE_KEY_B64`      | Base64-encoded .key file for Gateway                                                                                           |
| `GTW_TLS_CERTIFICATE_B64`              | Base64-encoded .crt file for Gateway                                                                                           |
| `GTW_TLS_PRIVATE_KEY_B64`              | Base64-encoded .key file for Gateway                                                                                           |
| `GTW_HOSTNAME`                         | Gateway name for host file                                                                                                     |



# Changelog
- 28/01/2026 - Updated containers to v2025.3.14.0
- 23/10/2025 - Updated containers to v2025.3.4.0
- 23/09/2025 - Updated containers to v2025.2.12.0
- 15/07/2025 - Updated containers to v2025.2.5.0
- 15/07/2025 - Updated containers to v2025.2.4.0
