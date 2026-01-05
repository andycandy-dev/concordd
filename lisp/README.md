# discord.el - Emacs Discord Client

An Emacs client for Discord that connects to `discordo-daemon` via Unix socket.

## Features

- 📋 List guilds and channels
- 💬 View message history with real-time updates
- ✉️ Send messages and replies
- 🔔 Real-time push notifications
- ✅ Mark channels as read
- 🎨 Simple, clean UI

## Installation

### Prerequisites

1. **Start the daemon** (in a terminal):
   ```bash
   # Using nix
   nix run .#daemon -- start --log-level info
   
   # Or build and run
   go build -o discordo-daemon ./cmd/tools/ipc
   ./discordo-daemon start
   ```

2. **Load in Emacs**:
   ```elisp
   ;; Add to your init.el
   (add-to-list 'load-path "/path/to/discordo")
   (require 'discord)
   ```

## Usage

### Quick Start

```elisp
;; Connect to daemon
(discord-connect)

;; Browse guilds and channels
(discord-browse)
```

### Interactive Commands

| Command | Description |
|---------|-------------|
| `M-x discord-connect` | Connect to the daemon |
| `M-x discord-disconnect` | Disconnect from the daemon |
| `M-x discord-browse` | Open guild/channel browser |
| `M-x discord-ping` | Test connection (shows timestamp) |

### In Channel Buffers

**Evil Mode (Normal State):**
- `n` - Compose new message
- `p` - Load more (older) messages
- `gr` - Reload messages
- `q` - Close buffer

**Standard Emacs:**
- `C-c C-n` - Compose message
- `C-c C-p` - Load more messages
- `C-c C-l` - Reload messages
- `q` - Close buffer

Messages appear in real-time as others send them.

### In Compose Buffer

- `C-c C-c` - Send message
- `C-c C-k` - Cancel

### Programmatic API

#### Connection Management

```elisp
;; Connect to daemon
(discord-connect)

;; Check connection status
(discord-connected-p)  ; => t or nil

;; Disconnect
(discord-disconnect)
```

#### Request/Response Methods

```elisp
;; List all guilds
(discord-list-guilds
 (lambda (result)
   (let ((guilds (plist-get result :guilds)))
     (message "Found %d guilds" (length guilds)))))

;; List channels in a guild
(discord-list-channels
 "123456789"  ; guild-id
 (lambda (result)
   (let ((channels (plist-get result :channels)))
     (dolist (ch channels)
       (message "Channel: #%s" (plist-get ch :name))))))

;; Get messages from a channel
(discord-get-messages
 "987654321"  ; channel-id
 (lambda (result)
   (let ((messages (plist-get result :messages)))
     (message "Loaded %d messages" (length messages))))
 50    ; limit (optional)
 nil)  ; before message-id (optional, for pagination)

;; Send a message
(discord-send-message
 "987654321"  ; channel-id
 "Hello from Emacs!"
 (lambda (result)
   (let ((msg (plist-get result :message)))
     (message "Sent: %s" (plist-get msg :id)))))

;; Reply to a message
(discord-reply-to-message
 "987654321"  ; channel-id
 "111111111"  ; message-id to reply to
 "This is a reply!"
 (lambda (result)
   (message "Reply sent!")))

;; Mark channel as read
(discord-mark-as-read
 "987654321"  ; channel-id
 "111111111"  ; message-id (mark as read up to this)
 (lambda (_result)
   (message "Marked as read")))

;; Get read state
(discord-get-read-state
 "987654321"
 (lambda (result)
   (let ((rs (plist-get result :readState)))
     (message "Last read: %s, mentions: %d"
              (plist-get rs :lastMessageId)
              (plist-get rs :mentionCount)))))
```

#### Event Handlers

Real-time push notifications from the daemon:

```elisp
;; Handle new messages
(discord-on 'messageCreated
  (lambda (params)
    (let* ((msg (plist-get params :message))
           (author (plist-get msg :author))
           (content (plist-get msg :content)))
      (message "New message from %s: %s"
               (plist-get author :username)
               content))))

;; Handle message edits
(discord-on 'messageUpdated
  (lambda (params)
    (let ((msg (plist-get params :message)))
      (message "Message edited: %s" (plist-get msg :id)))))

;; Handle message deletions
(discord-on 'messageDeleted
  (lambda (params)
    (message "Message deleted: %s" (plist-get params :messageId))))

;; Handle read state changes
(discord-on 'readStateUpdated
  (lambda (params)
    (message "Channel %s marked read" (plist-get params :channelId))))

;; Handle connection status
(discord-on 'connectionStatusChanged
  (lambda (params)
    (message "Discord status: %s" (plist-get params :status))))

;; Remove event handlers
(discord-off 'messageCreated)  ; Remove all handlers for this event
(discord-off 'messageCreated handler-fn)  ; Remove specific handler
```

## Configuration

```elisp
;; Customize socket path (default: /tmp/discordo-daemon.sock)
(setq discord-socket-path "/custom/path/to/daemon.sock")

;; Enable debug logging of JSON-RPC messages
(setq discord-log-messages t)
```

## Data Structures

### Guild
```elisp
'(:id "123456789"
  :name "My Server"
  :icon "abc123..."
  :ownerId "987654321")
```

### Channel
```elisp
'(:id "123456789"
  :guildId "987654321"
  :name "general"
  :type 0  ; 0=text, 2=voice, 4=category
  :position 1
  :parentId "555555555"
  :unread t
  :mentioned nil
  :mentionCount 0)
```

### Message
```elisp
'(:id "123456789"
  :channelId "987654321"
  :guildId "555555555"
  :author (:id "111111111"
           :username "john_doe"
           :discriminator "0001"
           :avatar "abc123..."
           :bot nil
           :roles ("role1" "role2"))
  :content "Hello, world!"
  :timestamp "2025-12-28T12:00:00Z"
  :editedTimestamp nil
  :attachments ["https://cdn.discord.com/..."]
  :embeds 0
  :reactions [(:emoji "👍" :count 5 :me t)]
  :referencedMessage "999999999")  ; Message ID if this is a reply
```

### ReadState
```elisp
'(:channelId "123456789"
  :lastMessageId "987654321"
  :mentionCount 2)
```

## UI Workflow

```
discord-browse
    │
    ├─→ *Discord Guilds* buffer
    │   - Shows list of guilds
    │   - Click guild → opens channel list
    │
    ├─→ *Discord Channels* buffer
    │   - Shows channels in selected guild
    │   - ● indicates unread
    │   - @ indicates mentions
    │   - Click channel → opens messages
    │
    └─→ *Discord: #channel-name* buffer
        - Shows message history
        - Type message at bottom
        - Press RET to send
        - Receives real-time updates
```

## Troubleshooting

### "Socket not found" error
- Make sure `discordo-daemon` is running
- Check socket path: `ls -la /tmp/discordo-daemon.sock`
- Verify `discord-socket-path` matches daemon's `--socket-path`

### "Not connected" error
- Run `(discord-connect)` first
- Check connection: `(discord-connected-p)`

### Messages not appearing
- Check event handlers are registered
- Enable debug logging: `(setq discord-log-messages t)`
- Check daemon logs: `discordo-daemon start --log-level debug`

### Enable debug logging
```elisp
(setq discord-log-messages t)
```

This will show all JSON-RPC messages in the `*Messages*` buffer.

## Architecture

```
Emacs (discord.el)
    │
    │ Unix Socket
    │ JSON-RPC 2.0
    │
discordo-daemon
    │
    │ WebSocket
    │
Discord Gateway
```

## Development Status

### ✅ Implemented
- Basic connection management
- All core RPC methods (ping, list*, get*, send*, mark*, reply*)
- Event handling system
- Simple UI (guild/channel/message browsers)
- Real-time message updates

### 🚧 TODO
- Message pagination (load more)
- Rich message rendering (embeds, attachments)
- User mentions and @-completion
- Emoji support
- Thread support
- Edit/delete own messages
- Reactions
- Typing indicators
- User presence
- Keybindings and navigation improvements
- More robust error handling

## Notification Tracking

The `concordd-notify` package provides intelligent notification tracking with modeline integration.

### Setup

```elisp
(require 'concordd-notify)

;; Track specific guild(s)
(setq concordd-notify-tracked-guilds '("1116381924856971375"))

;; Or track specific channels only
(setq concordd-notify-tracked-channels '("channel-id-1" "channel-id-2"))

;; Track direct messages (default: t)
(setq concordd-notify-track-dms t)

;; Only track mentions (default: nil)
(setq concordd-notify-mentions-only nil)

;; Enable notification tracking
(concordd-notify-mode 1)
```

### Features

- **Queue-based navigation**: Click modeline to open next unread channel
- **Smart counting**: Tracks multiple messages per channel correctly
- **Mention highlighting**: Shows mention count with `@` prefix in urgent color
- **Auto-clear**: Automatically clears notifications when you open a channel
- **Configurable tracking**: Track specific guilds, channels, or DMs

### Modeline Display

The modeline shows: `💬 @2 5` where:
- `💬` = Discord icon (configurable)
- `@2` = 2 mentions (shown in urgent/error color)
- `5` = 5 total unread messages

Click the modeline segment to navigate to the next unread channel.

### Commands

- `M-x concordd-notify-next-channel` - Open next unread channel
- `M-x concordd-notify-clear-all` - Clear all notifications
- `M-x concordd-notify-mode` - Toggle notification tracking

### Doom Modeline Integration

For Doom Emacs users, add the segment to your modeline:

```elisp
(after! doom-modeline
  (doom-modeline-def-modeline 'main
    '(bar workspace-name window-number modals matches buffer-info remote-host buffer-position word-count parrot selection-info concordd-notify)
    '(objed-state misc-info persp-name battery grip irc mu4e gnus github debug repl lsp minor-modes input-method indent-info buffer-encoding major-mode process vcs checker)))
```

### Example Configuration

```elisp
(use-package! concordd-notify
  :after concordd
  :config
  ;; Track my main guild and DMs
  (setq concordd-notify-tracked-guilds '("1116381924856971375")
        concordd-notify-track-dms t)
  
  ;; Enable tracking
  (concordd-notify-mode 1)
  
  ;; Bind quick navigation
  (map! :leader
        :desc "Next unread Discord" "dn" #'concordd-notify-next-channel
        :desc "Clear Discord notifications" "dx" #'concordd-notify-clear-all))
```

## License

Same as the discordo project.

## See Also

- [ipc.org](./ipc.org) - IPC protocol specification
- [cmd/tools/ipc/](./cmd/tools/ipc/) - Daemon implementation
