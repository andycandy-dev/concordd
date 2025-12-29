#!/usr/bin/env bash
# Test the IPC daemon with simple ping command

SOCKET_PATH="${1:-/tmp/discordo-daemon.sock}"

if [ ! -S "$SOCKET_PATH" ]; then
    echo "Error: Socket not found at $SOCKET_PATH"
    echo "Make sure the daemon is running first:"
    echo "  nix run .#daemon -- start"
    exit 1
fi

echo "Testing IPC daemon at $SOCKET_PATH"
echo ""

# Test ping command
echo "Sending ping request..."
echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | socat - "UNIX-CONNECT:$SOCKET_PATH"

echo ""
echo "Done!"
