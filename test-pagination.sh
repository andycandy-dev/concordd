#!/usr/bin/env bash
# Test message pagination functionality

SOCKET="${1:-/tmp/discordo-daemon.sock}"
CHANNEL_ID="${2}"

if [ -z "$CHANNEL_ID" ]; then
    echo "Usage: $0 [socket_path] <channel_id>"
    echo "Example: $0 /tmp/discordo-daemon.sock 1450430001789927506"
    exit 1
fi

echo "Testing message pagination..."
echo

# Get initial messages
echo "1. Getting initial 5 messages..."
echo '{"jsonrpc":"2.0","id":1,"method":"getMessages","params":{"channelId":"'$CHANNEL_ID'","limit":5}}' | \
    socat - UNIX-CONNECT:$SOCKET | jq -r '.result.messages[] | "\(.id): \(.content)"'
echo

# Get the oldest message ID from first batch
OLDEST_ID=$(echo '{"jsonrpc":"2.0","id":2,"method":"getMessages","params":{"channelId":"'$CHANNEL_ID'","limit":5}}' | \
    socat - UNIX-CONNECT:$SOCKET | jq -r '.result.messages[0].id')

echo "2. Oldest message ID from first batch: $OLDEST_ID"
echo

# Get messages before that ID (pagination)
echo "3. Getting 5 messages before ID $OLDEST_ID..."
echo '{"jsonrpc":"2.0","id":3,"method":"getMessages","params":{"channelId":"'$CHANNEL_ID'","limit":5,"before":"'$OLDEST_ID'"}}' | \
    socat - UNIX-CONNECT:$SOCKET | jq -r '.result.messages[] | "\(.id): \(.content)"'
echo

echo "✅ Pagination test complete!"
echo
echo "If you see different messages in steps 1 and 3, pagination is working!"
