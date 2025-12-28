package internal

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/andycandy-dev/concordd/internal/http"
	"github.com/diamondburned/arikawa/v3/discord"
	"github.com/diamondburned/arikawa/v3/gateway"
	"github.com/diamondburned/arikawa/v3/session"
	"github.com/diamondburned/arikawa/v3/state"
	"github.com/diamondburned/arikawa/v3/state/store/defaultstore"
	"github.com/diamondburned/arikawa/v3/utils/handler"
	"github.com/diamondburned/ningen/v3"
	"github.com/diamondburned/ningen/v3/states/read"
)

// DiscordClient wraps the Discord state and provides IPC-friendly methods
type DiscordClient struct {
	state       *ningen.State
	server      *Server
	historySize int
	connected   bool
	mu          sync.RWMutex
}

// NewDiscordClient creates a new Discord client
func NewDiscordClient(token string, server *Server, historySize int) (*DiscordClient, error) {
	dc := &DiscordClient{
		server:      server,
		historySize: historySize,
		connected:   false,
	}

	// Create Discord state
	id := gateway.DefaultIdentifier(token)
	id.Compress = false

	sess := session.NewCustom(id, http.NewClient(token), handler.New())
	st := state.NewFromSession(sess, defaultstore.New())
	dc.state = ningen.FromState(st)

	// Register event handlers
	dc.state.AddHandler(dc.onReady)
	dc.state.AddHandler(dc.onMessageCreate)
	dc.state.AddHandler(dc.onMessageUpdate)
	dc.state.AddHandler(dc.onMessageDelete)
	dc.state.AddHandler(dc.onReadUpdate)
	dc.state.AddHandler(dc.onGuildCreate)
	dc.state.AddHandler(dc.onChannelCreate)

	return dc, nil
}

// Connect connects to Discord
func (dc *DiscordClient) Connect() error {
	dc.mu.Lock()
	defer dc.mu.Unlock()

	if dc.connected {
		return fmt.Errorf("already connected")
	}

	slog.Info("Connecting to Discord...")

	if err := dc.state.Open(context.Background()); err != nil {
		dc.notifyConnectionStatus("disconnected", err.Error())
		return fmt.Errorf("failed to connect to Discord: %w", err)
	}

	dc.connected = true
	slog.Info("Connected to Discord")
	dc.notifyConnectionStatus("connected", "")

	return nil
}

// Close closes the Discord connection
func (dc *DiscordClient) Close() error {
	dc.mu.Lock()
	defer dc.mu.Unlock()

	if !dc.connected {
		return nil
	}

	slog.Info("Disconnecting from Discord...")
	dc.state.Close()
	dc.connected = false
	dc.notifyConnectionStatus("disconnected", "Client closed")

	return nil
}

// IsConnected returns whether the client is connected
func (dc *DiscordClient) IsConnected() bool {
	dc.mu.RLock()
	defer dc.mu.RUnlock()
	return dc.connected
}

// GetGuilds returns all guilds
func (dc *DiscordClient) GetGuilds() ([]Guild, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	guilds, err := dc.state.Cabinet.Guilds()
	if err != nil {
		return nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to get guilds: %v", err))
	}

	result := make([]Guild, len(guilds))
	for i, g := range guilds {
		result[i] = ToGuild(g)
	}

	return result, nil
}

// GetChannels returns all channels in a guild
func (dc *DiscordClient) GetChannels(guildID discord.GuildID) ([]Channel, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	channels, err := dc.state.Cabinet.Channels(guildID)
	if err != nil {
		return nil, NewError(GuildNotFound, fmt.Sprintf("Failed to get channels: %v", err))
	}

	result := make([]Channel, 0, len(channels))
	for _, c := range channels {
		// Convert to IPC channel
		ch := ToChannel(c)

		// Add unread information
		opts := ningen.UnreadOpts{IncludeMutedCategories: true}
		indication := dc.state.ChannelIsUnread(c.ID, opts)
		ch.Unread = indication == ningen.ChannelUnread || indication == ningen.ChannelMentioned
		ch.Mentioned = indication == ningen.ChannelMentioned

		readState := dc.state.ReadState.ReadState(c.ID)
		if readState != nil {
			ch.MentionCount = readState.MentionCount
		}

		result = append(result, ch)
	}

	return result, nil
}

// GetMessages returns messages from a channel
func (dc *DiscordClient) GetMessages(channelID discord.ChannelID, limit uint, before discord.MessageID) ([]Message, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	if limit == 0 {
		limit = uint(dc.historySize)
	}

	slog.Debug("Fetching messages", "channel", channelID, "limit", limit, "before", before)

	var messages []discord.Message
	var err error

	if before.IsValid() {
		// Get messages before a specific message (pagination)
		messages, err = dc.state.MessagesBefore(channelID, before, limit)
	} else {
		// Get most recent messages
		messages, err = dc.state.Messages(channelID, limit)
	}

	if err != nil {
		slog.Error("Failed to fetch messages", "channel", channelID, "err", err)
		return nil, NewError(ChannelNotFound, fmt.Sprintf("Failed to get messages: %v", err))
	}

	slog.Debug("Fetched messages", "count", len(messages))

	// Return empty array if no messages
	if len(messages) == 0 {
		return []Message{}, nil
	}

	// Get channel to determine guild for role info
	channel, err := dc.state.Cabinet.Channel(channelID)
	if err != nil {
		slog.Warn("Failed to get channel info, continuing without guild context", "err", err)
		// Convert messages without role info
		result := make([]Message, len(messages))
		for i, m := range messages {
			result[i] = ToMessage(m, nil)
		}
		return result, nil
	}

	result := make([]Message, len(messages))
	for i, m := range messages {
		// Get member info for roles
		var roles []discord.RoleID
		if channel.GuildID.IsValid() {
			member, err := dc.state.Cabinet.Member(channel.GuildID, m.Author.ID)
			if err == nil {
				roles = member.RoleIDs
			}
		}

		result[i] = ToMessage(m, roles)
	}

	return result, nil
}

// SendMessage sends a message to a channel
func (dc *DiscordClient) SendMessage(channelID discord.ChannelID, content string) (*Message, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	msg, err := dc.state.SendMessage(channelID, content)
	if err != nil {
		return nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to send message: %v", err))
	}

	// Get channel for guild info
	channel, err := dc.state.Cabinet.Channel(channelID)
	if err != nil {
		return nil, NewError(ChannelNotFound, fmt.Sprintf("Failed to get channel: %v", err))
	}

	// Get member info for roles
	var roles []discord.RoleID
	if channel.GuildID.IsValid() {
		member, err := dc.state.Cabinet.Member(channel.GuildID, msg.Author.ID)
		if err == nil {
			roles = member.RoleIDs
		}
	}

	result := ToMessage(*msg, roles)
	return &result, nil
}

// ReplyToMessage sends a reply to a message
func (dc *DiscordClient) ReplyToMessage(channelID discord.ChannelID, messageID discord.MessageID, content string) (*Message, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	msg, err := dc.state.SendMessageReply(channelID, content, messageID)
	if err != nil {
		return nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to reply to message: %v", err))
	}

	// Get channel for guild info
	channel, err := dc.state.Cabinet.Channel(channelID)
	if err != nil {
		return nil, NewError(ChannelNotFound, fmt.Sprintf("Failed to get channel: %v", err))
	}

	// Get member info for roles
	var roles []discord.RoleID
	if channel.GuildID.IsValid() {
		member, err := dc.state.Cabinet.Member(channel.GuildID, msg.Author.ID)
		if err == nil {
			roles = member.RoleIDs
		}
	}

	result := ToMessage(*msg, roles)
	return &result, nil
}

// MarkAsRead marks a channel as read up to a message
func (dc *DiscordClient) MarkAsRead(channelID discord.ChannelID, messageID discord.MessageID) error {
	if !dc.IsConnected() {
		return NewError(NotConnected, "Not connected to Discord")
	}

	// Use ningen's ReadState to mark as read
	dc.state.ReadState.MarkRead(channelID, messageID)

	return nil
}

// EditMessage edits a message
func (dc *DiscordClient) EditMessage(channelID discord.ChannelID, messageID discord.MessageID, content string) (*Message, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	msg, err := dc.state.EditMessage(channelID, messageID, content)
	if err != nil {
		return nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to edit message: %v", err))
	}

	// Get channel for guild info
	channel, err := dc.state.Cabinet.Channel(channelID)
	if err != nil {
		return nil, NewError(ChannelNotFound, fmt.Sprintf("Failed to get channel: %v", err))
	}

	// Get member info for roles
	var roles []discord.RoleID
	if channel.GuildID.IsValid() {
		member, err := dc.state.Cabinet.Member(channel.GuildID, msg.Author.ID)
		if err == nil {
			roles = member.RoleIDs
		}
	}

	result := ToMessage(*msg, roles)
	return &result, nil
}

// DeleteMessage deletes a message
func (dc *DiscordClient) DeleteMessage(channelID discord.ChannelID, messageID discord.MessageID) error {
	if !dc.IsConnected() {
		return NewError(NotConnected, "Not connected to Discord")
	}

	err := dc.state.DeleteMessage(channelID, messageID, "")
	if err != nil {
		return NewError(DiscordAPIError, fmt.Sprintf("Failed to delete message: %v", err))
	}

	return nil
}

// GetReadState gets the read state for a channel
func (dc *DiscordClient) GetReadState(channelID discord.ChannelID) (*ReadState, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	rs := dc.state.ReadState.ReadState(channelID)
	if rs == nil {
		return &ReadState{
			ChannelID:     channelID.String(),
			LastMessageID: "",
			MentionCount:  0,
		}, nil
	}

	return &ReadState{
		ChannelID:     channelID.String(),
		LastMessageID: rs.LastMessageID.String(),
		MentionCount:  rs.MentionCount,
	}, nil
}

// GetGuildMembers returns all members in a guild
func (dc *DiscordClient) GetGuildMembers(guildID discord.GuildID) ([]Member, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	members, err := dc.state.Cabinet.Members(guildID)
	if err != nil {
		return nil, NewError(GuildNotFound, fmt.Sprintf("Failed to get members: %v", err))
	}

	result := make([]Member, len(members))
	for i, m := range members {
		// Member already has embedded User, no need to fetch separately
		result[i] = ToMember(m, m.User)
	}

	return result, nil
}

// GetGuildRoles returns all roles in a guild
func (dc *DiscordClient) GetGuildRoles(guildID discord.GuildID) ([]Role, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	roles, err := dc.state.Cabinet.Roles(guildID)
	if err != nil {
		return nil, NewError(GuildNotFound, fmt.Sprintf("Failed to get roles: %v", err))
	}

	result := make([]Role, len(roles))
	for i, r := range roles {
		result[i] = ToRole(r)
	}

	return result, nil
}

// Event handlers

func (dc *DiscordClient) onReady(r *gateway.ReadyEvent) {
	slog.Info("Discord ready", "user", r.User.Username)
}

func (dc *DiscordClient) onMessageCreate(m *gateway.MessageCreateEvent) {
	// Get channel for guild info
	channel, err := dc.state.Cabinet.Channel(m.ChannelID)
	if err != nil {
		slog.Error("failed to get channel for message", "err", err)
		return
	}

	// Get member info for roles
	var roles []discord.RoleID
	if channel.GuildID.IsValid() {
		member, err := dc.state.Cabinet.Member(channel.GuildID, m.Author.ID)
		if err == nil {
			roles = member.RoleIDs
		}
	}

	msg := ToMessage(m.Message, roles)

	// Broadcast to all clients
	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "messageCreated",
		Params:  mustMarshal(map[string]interface{}{"message": msg}),
	})
}

func (dc *DiscordClient) onMessageUpdate(m *gateway.MessageUpdateEvent) {
	// Get full message
	fullMsg, err := dc.state.Cabinet.Message(m.ChannelID, m.ID)
	if err != nil {
		slog.Error("failed to get full message", "err", err)
		return
	}

	// Get channel for guild info
	channel, err := dc.state.Cabinet.Channel(m.ChannelID)
	if err != nil {
		slog.Error("failed to get channel for message", "err", err)
		return
	}

	// Get member info for roles
	var roles []discord.RoleID
	if channel.GuildID.IsValid() {
		member, err := dc.state.Cabinet.Member(channel.GuildID, fullMsg.Author.ID)
		if err == nil {
			roles = member.RoleIDs
		}
	}

	msg := ToMessage(*fullMsg, roles)

	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "messageUpdated",
		Params:  mustMarshal(map[string]interface{}{"message": msg}),
	})
}

func (dc *DiscordClient) onMessageDelete(m *gateway.MessageDeleteEvent) {
	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "messageDeleted",
		Params: mustMarshal(map[string]interface{}{
			"channelId": m.ChannelID.String(),
			"messageId": m.ID.String(),
		}),
	})
}

func (dc *DiscordClient) onReadUpdate(event *read.UpdateEvent) {
	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "readStateUpdated",
		Params: mustMarshal(map[string]interface{}{
			"channelId":     event.ChannelID.String(),
			"lastMessageId": event.ReadState.LastMessageID.String(),
			"mentionCount":  event.ReadState.MentionCount,
		}),
	})
}

func (dc *DiscordClient) onGuildCreate(g *gateway.GuildCreateEvent) {
	guild := ToGuild(g.Guild)

	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "guildCreated",
		Params:  mustMarshal(map[string]interface{}{"guild": guild}),
	})
}

func (dc *DiscordClient) onChannelCreate(c *gateway.ChannelCreateEvent) {
	channel := ToChannel(c.Channel)

	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "channelCreated",
		Params:  mustMarshal(map[string]interface{}{"channel": channel}),
	})
}

func (dc *DiscordClient) notifyConnectionStatus(status string, reason string) {
	params := map[string]interface{}{
		"status":    status,
		"timestamp": time.Now().Format(time.RFC3339),
	}
	if reason != "" {
		params["reason"] = reason
	}

	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "connectionStatusChanged",
		Params:  mustMarshal(params),
	})
}
