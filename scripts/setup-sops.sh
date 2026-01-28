#!/bin/bash
set -e

# Setup SOPS with age encryption for homelab
# Run this script on each MacBook that needs to encrypt/decrypt secrets

SOPS_AGE_DIR="$HOME/.config/sops/age"
SOPS_AGE_KEY_FILE="$SOPS_AGE_DIR/keys.txt"

echo "=== Homelab SOPS Setup ==="
echo ""

# Check if age is installed
if ! command -v age &> /dev/null; then
    echo "age is not installed. Installing via Homebrew..."
    brew install age
fi

# Check if sops is installed
if ! command -v sops &> /dev/null; then
    echo "sops is not installed. Installing via Homebrew..."
    brew install sops
fi

# Create age key directory
mkdir -p "$SOPS_AGE_DIR"

# Check if key already exists
if [ -f "$SOPS_AGE_KEY_FILE" ]; then
    echo "Age key already exists at: $SOPS_AGE_KEY_FILE"
    echo ""
    echo "Your public key is:"
    grep "public key:" "$SOPS_AGE_KEY_FILE" | sed 's/.*public key: //'
    echo ""
    echo "Add this public key to .sops.yaml in the repository."
else
    echo "Generating new age key..."
    age-keygen -o "$SOPS_AGE_KEY_FILE"
    chmod 600 "$SOPS_AGE_KEY_FILE"
    echo ""
    echo "Age key generated at: $SOPS_AGE_KEY_FILE"
    echo ""
    echo "Your public key is:"
    grep "public key:" "$SOPS_AGE_KEY_FILE" | sed 's/.*public key: //'
    echo ""
    echo "IMPORTANT: Add this public key to .sops.yaml in the repository."
    echo "Both MacBooks' public keys must be in .sops.yaml for shared access."
fi

echo ""
echo "=== Next Steps ==="
echo "1. Copy your public key above"
echo "2. Add it to .sops.yaml under the 'age:' section"
echo "3. Repeat on your other MacBook"
echo "4. Commit .sops.yaml with both public keys"
echo ""
echo "To encrypt a file:  sops -e input.yaml > output.enc.yaml"
echo "To decrypt a file:  sops -d input.enc.yaml > output.yaml"
echo "To edit in-place:   sops input.enc.yaml"
