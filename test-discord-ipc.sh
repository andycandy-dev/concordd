#!/usr/bin/env bash
# Test Discord integration with IPC daemon

SOCKET_PATH="${1:-/tmp/discordo-daemon.sock}"

if [ ! -S "$SOCKET_PATH" ]; then
    echo "Error: Socket not found at $SOCKET_PATH"
    echo "Make sure the daemon is running first:"
    echo "  nix run .#daemon -- start"
    exit 1
fi

echo "Testing Discord IPC at $SOCKET_PATH"
echo ""

# Test ping
echo "=== Testing ping ==="
echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | socat - "UNIX-CONNECT:$SOCKET_PATH"
echo ""

# Test listGuilds
echo "=== Testing listGuilds ==="
echo '{"jsonrpc":"2.0","id":2,"method":"listGuilds"}' | socat - "UNIX-CONNECT:$SOCKET_PATH"
echo ""

# Test listChannels (replace with your guild ID)
GUILD_ID="${2:-}"
if [ -n "$GUILD_ID" ]; then
    echo "=== Testing listChannels for guild $GUILD_ID ==="
    echo "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"listChannels\",\"params\":{\"guildId\":\"$GUILD_ID\"}}" | socat - "UNIX-CONNECT:$SOCKET_PATH"
    echo ""
fi

# Test getMessages (replace with your channel ID)
CHANNEL_ID="${3:-}"
if [ -n "$CHANNEL_ID" ]; then
    echo "=== Testing getMessages for channel $CHANNEL_ID ==="
    echo "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"getMessages\",\"params\":{\"channelId\":\"$CHANNEL_ID\",\"limit\":5}}" | socat - "UNIX-CONNECT:$SOCKET_PATH"
    echo ""
fi

echo "Done!"
echo ""
echo "Usage: $0 [socket_path] [guild_id] [channel_id]"
echo "Example: $0 /tmp/discordo-daemon.sock 1116381924856971375 1234567890"
