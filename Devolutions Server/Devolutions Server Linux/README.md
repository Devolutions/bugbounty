# Requirements
- Docker with Linux containers.

# Setup

> **Warning**
> We advise changing the variable values in the *.env* file or use any other way. It is your responsability to secure those variables.
> Do not use the default provided values.

# Run

Run this bash script to start the Devolutions Server Linux dockers.

```
.\run.sh [clean] [update]
```

### Optional arguments
- `clean` : Clears the container data for a fresh start
- `update` : Pulls the latest Docker images before starting.

To access the server go to https://localhost:5544

# Changelog
- 15/07/2025 - Updated containers to v2025.2.4.0
