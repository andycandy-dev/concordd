#!/usr/bin/env sh

set -e  # Exit on error

# Packages to sync from discordo
PACKAGES=("http" "keyring" "logger" "consts")

TEMP_DIR=../discordo
# echo "Cloning discordo to temporary directory..."
# git clone --depth 1 https://github.com/ayn2op/discordo "$TEMP_DIR"

# Sync each package
for package in "${PACKAGES[@]}"; do
    echo "Syncing internal/$package..."
    
    # Create directory if it doesn't exist
    mkdir -p "internal/$package"
    
    # Copy files (using rsync with --delete to remove files that no longer exist)
    rsync -av --delete "$TEMP_DIR/internal/$package/" "internal/$package/"
done

echo "Updating import paths..."
# Update import paths in all synced files
find internal/http internal/keyring internal/logger internal/consts -name "*.go" -type f -exec sed -i '' \
  's|github.com/ayn2op/ayn2op/internal|github.com/andycandy-dev/concordd/internal|g' {} + 2>/dev/null || \
find internal/http internal/keyring internal/logger internal/consts -name "*.go" -type f -exec sed -i \
  's|github.com/ayn2op/ayn2op/internal|github.com/andycandy-dev/concordd/internal|g' {} +

# Clean up
# rm -rf "$TEMP_DIR"

echo "✅ Synced packages: ${PACKAGES[*]}"
# echo ""
# echo "Staged files:"
# git add internal/http internal/keyring internal/logger internal/consts
# git status --short

# echo ""
# read -p "Commit changes? (y/n) " -n 1 -r
# echo
# if [[ $REPLY =~ ^[Yy]$ ]]; then
#     git commit -m "Sync internal packages from discordo: ${PACKAGES[*]}"
#     echo "✅ Changes committed"
# else
#     echo "Changes staged but not committed"
# fi

