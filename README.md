# concordd

A Discord IPC daemon that exposes a JSON-RPC 2.0 interface over Unix domain sockets for external clients.

## Overview

**concordd** (formerly `discordo-daemon`) is a standalone daemon that:
- Maintains a persistent Discord connection via the Gateway API
- Exposes 21 API methods for reading/writing Discord data
- Broadcasts 10 real-time event types to all connected clients
- Caches messages for instant retrieval
- Provides a clean JSON-RPC 2.0 interface over Unix sockets

## Features

- ✅ **Complete Discord API**: 21 methods covering guilds, channels, messages, threads, forums, read state, members, and roles
- ✅ **Real-time events**: 10 push notification types for messages, threads, and connection status
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

Core operations (21 total):
- **Connection**: ping, getCurrentUser
- **Discovery**: listGuilds, listChannels, listDMs
- **Messages**: getMessages, sendMessage, replyToMessage, editMessage, deleteMessage
- **Read State**: markAsRead, getReadState
- **Members/Roles**: getGuildMembers, requestGuildMembers, getGuildRoles
- **Threads**: listThreads, createThread, joinThread, leaveThread, archiveThread
- **Forums**: createForumPost, getForumTags

### Events (Daemon → Client)

Real-time notifications (10 total):
- **Messages**: messageCreated, messageUpdated, messageDeleted
- **Read State**: readStateUpdated
- **Guild/Channels**: guildCreated, channelCreated
- **Threads**: threadCreated, threadUpdated, threadDeleted
- **Connection**: connectionStatusChanged

See [ipc.org](./ipc.org) for complete API documentation with examples.

## Clients

### Emacs

A full-featured Emacs client is included in the `lisp/` directory with support for:
- Real-time message display with EWOC (incremental updates)
- Image/video attachment rendering with thumbnails
- Markdown formatting with syntax highlighting
- @mention resolution (users, roles, channels)
- Desktop notifications for DMs and mentions
- Consult integration for fuzzy searching

See the [Configuration](#configuration) section below for setup details.

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

## Configuration

### Emacs Client Setup

#### Basic Configuration (Managed Daemon)

Emacs automatically starts and manages the daemon:

```elisp
(use-package concordd
  :load-path "~/path/to/concordd/lisp"
  :config
  ;; Your Discord token
  (setq concordd-discord-token "YOUR_DISCORD_TOKEN"
        concordd-socket-path "/tmp/concordd.sock")

  ;; Connect (auto-starts daemon if needed)
  (concordd-connect))
```

#### External Daemon Mode

You manage the daemon separately (recommended for multiple Emacs sessions):

```bash
# Start daemon manually
concordd --token YOUR_TOKEN --socket /tmp/concordd.sock
```

```elisp
(use-package concordd
  :load-path "~/path/to/concordd/lisp"
  :config
  ;; Don't set concordd-discord-token - daemon is external
  (setq concordd-socket-path "/tmp/concordd.sock")
  (concordd-connect))
```

#### Binary Download Options

```elisp
;; Option 1: Use system PATH (default)
(setq concordd-binary-path nil)  ; Uses executable-find

;; Option 2: Local file path
(setq concordd-binary-path "/usr/local/bin/concordd")

;; Option 3: Download from GitHub releases
(setq concordd-binary-path
      "https://github.com/USER/concordd/releases/download/v0.1.0/concordd-darwin-aarch64")
```

See [docs/DAEMON_MANAGEMENT.md](./docs/DAEMON_MANAGEMENT.md) for detailed daemon setup options.

### Full Configuration Example

```elisp
(use-package concordd
  :config
  ;; Daemon connection
  (setq concordd-discord-token "YOUR_DISCORD_TOKEN"
        concordd-socket-path "/tmp/concordd.sock"

        ;; Image rendering (default: nil)
        concordd-message-show-images nil  ; Toggle with 'i'
        concordd-message-image-max-height 150
        concordd-message-image-max-width 300

        ;; External viewers for attachments
        concordd-message-external-viewer-command "xdg-open %u"     ; General files
        concordd-message-external-video-command "mpv %u")          ; Videos only

  ;; Keybindings
  (map! :after concordd
        :map concordd-ui-v2-channel-mode-map
        :localleader
        :desc "Compose"        "n"  #'concordd-ui-v2-compose
        :desc "Reply"          "r"  #'concordd-ui-v2-compose-reply
        :desc "Load older"     "p"  #'concordd-ui-v2-load-older
        :desc "Refresh"        "gr" #'concordd-ui-v2-refresh)

  (map! :leader
        (:prefix ("d" . "concordd")
         :desc "Connect"       "c" #'concordd-connect
         :desc "Disconnect"    "d" #'concordd-disconnect
         :desc "Browse"        "b" #'concordd-browse
         :desc "DMs"           "m" #'concordd-open-dm
         :desc "Toggle images" "i" #'concordd-message-toggle-images
         :desc "Preview"       "v" #'concordd-message-preview-image-at-point)))

;; Optional: Notifications
(use-package concordd-notify
  :after concordd
  :config
  (setq concordd-notify-tracked-guilds '("GUILD_ID_1" "GUILD_ID_2")
        concordd-notify-track-dms t)
  (concordd-notify-mode 1))
```

### Customization Options

#### Message Display

| Variable                            | Default  | Description                                 |
|-------------------------------------|----------|---------------------------------------------|
| `concordd-message-timestamp-align`  | `'right` | Timestamp alignment (`'left` or `'right`)   |
| `concordd-message-group-by-author`  | `t`      | Group consecutive messages from same author |
| `concordd-ui-v2-message-limit`      | `100`    | Max messages to keep in buffer              |
| `concordd-ui-v2-load-message-count` | `50`     | Messages to load per request                |

#### Image Rendering

| Variable                            | Default | Description                   |
|-------------------------------------|---------|-------------------------------|
| `concordd-message-show-images`      | `nil`   | Show inline image thumbnails  |
| `concordd-message-image-max-height` | `150`   | Max thumbnail height (pixels) |
| `concordd-message-image-max-width`  | `300`   | Max thumbnail width (pixels)  |

Toggle images: `M-x concordd-message-toggle-images` or bind to a key.

#### External Viewers

| Variable                                   | Default         | Description                                |
|--------------------------------------------|-----------------|--------------------------------------------|
| `concordd-message-external-viewer-command` | `"xdg-open %u"` | Command for opening attachments            |
| `concordd-message-external-video-command`  | `nil`           | Video-specific command (overrides general) |

**Placeholders:**
- `%u` - URL of the attachment
- `%f` - Filename of the attachment

**Examples:**
```elisp
;; Linux
(setq concordd-message-external-viewer-command "xdg-open %u"
      concordd-message-external-video-command "mpv %u")

;; macOS
(setq concordd-message-external-viewer-command "open %u"
      concordd-message-external-video-command "iina %u")

;; Windows
(setq concordd-message-external-viewer-command "start %u"
      concordd-message-external-video-command "mpv.exe %u")
```

Press `v` on any attachment (image/video/PDF) to open it:
- **Images**: Preview in Emacs buffer
- **Videos**: Opens with video-specific command (or falls back to general viewer)
- **Other files**: Opens with general viewer command

#### Notifications

| Variable                             | Default | Description                |
|--------------------------------------|---------|----------------------------|
| `concordd-notify-tracked-guilds`     | `nil`   | List of guild IDs to track |
| `concordd-notify-track-dms`          | `nil`   | Track DM notifications     |
| `concordd-notify-show-notifications` | `t`     | Show desktop notifications |
| `concordd-notify-play-sound`         | `nil`   | Play sound on notification |

### Security Best Practices

- **Never commit** `concordd-discord-token` to version control
- Use `auth-source` with encrypted files:
  ```elisp
  ;; In ~/.authinfo.gpg:
  ;; machine discord.com login YOUR_EMAIL password YOUR_TOKEN

  (setq concordd-discord-token
        (auth-source-pick-first-password :host "discord.com"))
  ```
- Consider external daemon mode (token not in Emacs config)
- Review [docs/DAEMON_MANAGEMENT.md](./docs/DAEMON_MANAGEMENT.md) for setup modes

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

| Feature           | Standalone CLI | concordd           |
|-------------------|----------------|--------------------|
| Authentication    | Every call     | Once               |
| Message fetch     | 5-30s each     | Instant (cached)   |
| Real-time updates | Manual polling | Push notifications |
| Resource usage    | High           | Low                |

## License

Same as discordo parent project.

## Links

- **Parent project**: [discordo](https://github.com/ayn2op/discordo)
- **API documentation**: [ipc.org](./ipc.org)
- **Emacs client**: [discord.el](./discord.el)
