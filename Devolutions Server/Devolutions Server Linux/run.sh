#!/bin/bash

set -e

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
