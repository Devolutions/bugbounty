#!/bin/bash

# Clean data folders and Docker containers for DVLS Docker setup

# Set working directory to the script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

echo "🧹 Cleaning Docker containers and data folders..."

# Stop and remove Docker containers
echo ""
echo "🐳 Stopping and removing Docker containers..."
if docker compose down -v 2>&1; then
    echo "   ✅ Docker containers stopped and removed"
else
    EXIT_CODE=$?
    echo "   ⚠️ Docker compose down completed with warnings (exit code: $EXIT_CODE)"
fi

echo ""
echo "🧹 Cleaning data folders..."

# Clean data-sql folder
if [ -d "./data-sql" ]; then
    rm -rf "./data-sql"
    echo "   ✅ Removed data-sql folder"
fi

# Clean data-dvls folder
if [ -d "./data-dvls" ]; then
    rm -rf "./data-dvls"
    echo "   ✅ Removed data-dvls folder"
fi

# Recreate data folders
mkdir -p "./data-sql"
mkdir -p "./data-dvls"
echo "   ✅ Recreated data folders"

# Add .gitkeep files
touch "./data-dvls/.gitkeep"
touch "./data-sql/.gitkeep"
echo "   ✅ Added .gitkeep files"

echo "✅ Data folders cleaned successfully"
echo ""
