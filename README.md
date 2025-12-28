# concordd

A Discord IPC daemon that exposes a JSON-RPC 2.0 interface over Unix domain sockets for external clients.

## Overview

**concordd** (formerly `discordo-daemon`) is a standalone daemon that:
- Maintains a persistent Discord connection via the Gateway API
- Exposes 12 API methods for reading/writing Discord data
- Broadcasts 7 real-time event types to all connected clients
- Caches messages for instant retrieval
- Provides a clean JSON-RPC 2.0 interface over Unix sockets

## Features

- ✅ **Complete Discord API**: 12 methods covering guilds, channels, messages, read state, members, and roles
- ✅ **Real-time events**: Push notifications for new messages, edits, deletes, and more
- ✅ **Message caching**: First fetch is slow, subsequent fetches are instant
- ✅ **Message pagination**: Load older messages with `before` parameter
- ✅ **Edit/delete messages**: Full CRUD operations for your own messages
- ✅ **Mention support**: Get guild members and roles for rendering @mentions
- ✅ **Multiple clients**: Support for concurrent client connections
- ✅ **Graceful shutdown**: Clean disconnection on SIGTERM/SIGINT

## Installation

### Build from source

```bash
cd concordd
go build -o concordd
```

### Dependencies

concordd references the parent `discordo` project for:
- HTTP client with browser-like headers (`internal/http`)
- Keyring integration for token storage (`internal/keyring`)
- Logger utilities (`internal/logger`)

This avoids code duplication while keeping the daemon separate.

## Usage

### Start the daemon

```bash
# Using token from environment
export DISCORDO_TOKEN="your_discord_token"
./concordd start

# Using token from keyring
./concordd start

# With custom options
./concordd start \
  --socket-path /tmp/concordd.sock \
  --history-size 200 \
  --log-level debug \
  --log-path ~/.local/share/concordd/logs.txt
```

### Command-line options

```
--socket-path PATH        Unix socket path (default: /tmp/concordd.sock)
--token TOKEN            Discord token (default: $DISCORDO_TOKEN or keyring)
--history-size N         Message cache size per channel (default: 100)
--log-level LEVEL        Log level: debug|info|warn|error (default: info)
--log-path PATH          Log file path (default: system cache dir)
```

## API

### Methods (Client → Daemon)

1. **ping** - Health check
2. **listGuilds** - Get all guilds
3. **listChannels** - Get channels in a guild
4. **getMessages** - Get message history (with pagination)
5. **sendMessage** - Send a message
6. **replyToMessage** - Reply to a message
7. **editMessage** - Edit your own message
8. **deleteMessage** - Delete your own message
9. **markAsRead** - Mark channel as read
10. **getReadState** - Get read state for a channel
11. **getGuildMembers** - Get guild members (for @mentions)
12. **getGuildRoles** - Get guild roles (for @role mentions)

### Events (Daemon → Client)

1. **messageCreated** - New message received
2. **messageUpdated** - Message edited
3. **messageDeleted** - Message deleted
4. **readStateUpdated** - Read state changed
5. **connectionStatusChanged** - Discord connection status
6. **guildCreated** - Joined a new guild
7. **channelCreated** - New channel created

See [ipc.org](./ipc.org) for complete API documentation with examples.

## Clients

### Emacs

A full-featured Emacs client is included:

```bash
# Copy discord.el to your Emacs load-path
cp discord.el ~/.emacs.d/lisp/

# Add to your init.el
(add-to-list 'load-path "~/.emacs.d/lisp")
(require 'discord)

# Connect to daemon
M-x discord-connect
```

See [discord.el](./discord.el) and [examples-discord-el.sh](./examples-discord-el.sh) for details.

### Testing

Test the daemon with the included scripts:

```bash
# Basic connectivity test
./test-ipc.sh /tmp/concordd.sock

# Full Discord integration test
./test-discord-ipc.sh /tmp/concordd.sock [guild_id] [channel_id]

# Pagination test
./test-pagination.sh /tmp/concordd.sock [channel_id]
```

Or use `socat` for manual testing:

```bash
# Connect to daemon
socat - UNIX-CONNECT:/tmp/concordd.sock

# Send JSON-RPC requests
{"jsonrpc":"2.0","id":1,"method":"ping"}
{"jsonrpc":"2.0","id":2,"method":"listGuilds"}
```

## Architecture

```
┌──────────────────────┐
│  Clients             │
│  - Emacs (discord.el)│
│  - Custom tools      │
└──────┬───────────────┘
       │ Unix Socket
       │ JSON-RPC 2.0
       │
┌──────▼─────────────────┐
│  concordd              │
│  ┌──────────────────┐  │
│  │ IPC Server       │  │
│  │ - Unix socket    │  │
│  │ - Client manager │  │
│  │ - Event dispatch │  │
│  └──────────────────┘  │
│  ┌──────────────────┐  │
│  │ Discord Client   │  │
│  │ - Gateway conn   │  │
│  │ - Message cache  │  │
│  │ - Event handlers │  │
│  └──────────────────┘  │
└────────┬───────────────┘
         │ Discord Gateway
         │ WebSocket
         │
┌────────▼───────────────┐
│  Discord API           │
└────────────────────────┘
```

## Project Structure

```
concordd/
├── main.go                 # Entry point
├── go.mod                  # Module definition (references discordo)
├── internal/
│   ├── server.go          # Unix socket server
│   ├── protocol.go        # JSON-RPC 2.0 protocol
│   ├── handler.go         # Method handlers
│   ├── dto.go             # Data transfer objects
│   └── discord.go         # Discord client wrapper
├── discord.el             # Emacs client
├── ipc.org                # Complete API documentation
├── test-*.sh              # Test scripts
└── examples-discord-el.sh # Emacs examples
```

## Why a Separate Project?

concordd was originally part of discordo (`cmd/tools/ipc/`) but is now standalone for:

1. **Independent versioning** - Daemon and TUI can evolve separately
2. **Clean separation** - Clear boundary between UI and daemon
3. **Better distribution** - Users can install daemon-only
4. **Multiple clients** - Other projects can use concordd as a service

However, concordd **still references** discordo for shared utilities:
- HTTP client configuration
- Keyring integration  
- Logger utilities

This avoids duplication while maintaining modularity.

## Performance

### Message Caching

- **First request**: 5-30 seconds (fetches from Discord API)
- **Subsequent requests**: <100ms (served from memory cache)
- **Real-time updates**: Push notifications keep cache in sync

### Benefits vs Standalone Tools

| Feature | Standalone CLI | concordd |
|---------|---------------|----------|
| Authentication | Every call | Once |
| Message fetch | 5-30s each | Instant (cached) |
| Real-time updates | Manual polling | Push notifications |
| Resource usage | High | Low |

## License

Same as discordo parent project.

## Links

- **Parent project**: [discordo](https://github.com/ayn2op/discordo)
- **API documentation**: [ipc.org](./ipc.org)
- **Emacs client**: [discord.el](./discord.el)
