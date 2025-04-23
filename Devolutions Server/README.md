# Requirements
- Docker with Windows containers.
- Windows version 24H2.

# Setup

> **Warning**
> We advise changing the variable values in the *.env* file or use any other way. It is your responsability to secure those variables.
> Do not use the default provided values.

# Run

Run this powershell script to start the Devolutions Server dockers.

```
.\run.ps1 [clean] [update]
```

### Optional arguments
- `clean` : Clears the container data for a fresh start
- `update` : Pulls the latest Docker images before starting.

To access the server go to https://localhost:5543

# Changelog
- 23/04/2025 - Updated containers to v2025.1.5.0
- 25/03/2025 - Updated containers to v2025.1.4.0
- 19/03/2025 - Updated containers to v2025.1.3.0
- Updated containers to v2023.3.8.0 & improved startup procedure.