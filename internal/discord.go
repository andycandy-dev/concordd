package internal

import (
	"cmp"
	"context"
	"fmt"
	"log/slog"
	"slices"
	"sync"
	"time"

	"github.com/andycandy-dev/concordd/internal/http"
	"github.com/diamondburned/arikawa/v3/api"
	"github.com/diamondburned/arikawa/v3/discord"
	"github.com/diamondburned/arikawa/v3/gateway"
	"github.com/diamondburned/arikawa/v3/session"
	"github.com/diamondburned/arikawa/v3/state"
	"github.com/diamondburned/arikawa/v3/state/store/defaultstore"
	"github.com/diamondburned/arikawa/v3/utils/handler"
	"github.com/diamondburned/arikawa/v3/utils/httputil"
	"github.com/diamondburned/arikawa/v3/utils/json/option"
	"github.com/diamondburned/ningen/v3"
	"github.com/diamondburned/ningen/v3/states/read"
)

// DiscordClient wraps the Discord state and provides IPC-friendly methods
type DiscordClient struct {
	state                      *ningen.State
	server                     *Server
	historySize                int
	defaultAutoArchiveDuration int // minutes: 60, 1440, 4320, or 10080
	connected                  bool
	currentUserID              discord.UserID
	mu                         sync.RWMutex
}

// NewDiscordClient creates a new Discord client
func NewDiscordClient(token string, server *Server, historySize int, autoArchiveDuration int) (*DiscordClient, error) {
	// Validate auto-archive duration and use default if invalid
	validDurations := []int{60, 1440, 4320, 10080}
	isValid := false
	for _, valid := range validDurations {
		if autoArchiveDuration == valid {
			isValid = true
			break
		}
	}
	if !isValid {
		autoArchiveDuration = 10080 // Default: 1 week
		slog.Warn("Invalid auto-archive duration, using default 10080 (1 week)")
	}

	dc := &DiscordClient{
		server:                     server,
		historySize:                historySize,
		defaultAutoArchiveDuration: autoArchiveDuration,
		connected:                  false,
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
	dc.state.AddHandler(dc.onThreadCreate)
	dc.state.AddHandler(dc.onThreadUpdate)
	dc.state.AddHandler(dc.onThreadDelete)
	dc.state.AddHandler(dc.onGuildMembersChunk)

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

	// Build thread count map for forum channels
	threadCounts := make(map[discord.ChannelID]int)
	for _, c := range channels {
		if c.Type == discord.GuildPublicThread ||
			c.Type == discord.GuildPrivateThread ||
			c.Type == discord.GuildAnnouncementThread {
			if c.ParentID.IsValid() {
				threadCounts[c.ParentID]++
			}
		}
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

		// Add thread count for forum channels
		if c.Type == discord.GuildForum {
			ch.MessageCount = threadCounts[c.ID]
		}

		result = append(result, ch)
	}

	return result, nil
}

// GetDMChannels returns all direct message channels sorted by recent activity
func (dc *DiscordClient) GetDMChannels() ([]Channel, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	channels, err := dc.state.Cabinet.PrivateChannels()
	if err != nil {
		return nil, NewError(InternalError, fmt.Sprintf("Failed to get DM channels: %v", err))
	}

	// Sort channels by most recent message (descending order)
	slices.SortFunc(channels, func(a, b discord.Channel) int {
		msgID := func(ch discord.Channel) discord.MessageID {
			if ch.LastMessageID.IsValid() {
				return ch.LastMessageID
			}
			return discord.MessageID(ch.ID)
		}
		// Descending order (most recent first)
		return cmp.Compare(msgID(b), msgID(a))
	})

	result := make([]Channel, 0, len(channels))
	for _, c := range channels {
		// Only include DM channels (DirectMessage = 1, GroupDM = 3)
		if c.Type != discord.DirectMessage && c.Type != discord.GroupDM {
			continue
		}

		// Convert to IPC channel
		ch := ToChannel(c)

		// For DMs, we need to set a readable name
		if c.Type == discord.DirectMessage {
			// 1-on-1 DM: use the other user's name
			if len(c.DMRecipients) > 0 {
				ch.Name = c.DMRecipients[0].Username
			} else {
				ch.Name = "Unknown User"
			}
		} else if c.Type == discord.GroupDM {
			// Group DM: use channel name or list of participants
			if c.Name != "" {
				ch.Name = c.Name
			} else if len(c.DMRecipients) > 0 {
				// Build name from recipients (up to 3 names)
				names := make([]string, 0, 3)
				for i, r := range c.DMRecipients {
					if i >= 3 {
						names = append(names, fmt.Sprintf("and %d more", len(c.DMRecipients)-3))
						break
					}
					names = append(names, r.Username)
				}
				// Join all names into a single string
				if len(names) > 0 {
					ch.Name = "Group: " + names[0]
					for i := 1; i < len(names); i++ {
						ch.Name += ", " + names[i]
					}
				} else {
					ch.Name = "Group DM"
				}
			} else {
				ch.Name = "Group DM"
			}
		}

		// Add unread information
		// For DMs, we need custom unread logic because HasPermissions doesn't work for DMs
		// and ningen's ChannelIsUnread returns ChannelRead early
		indication := ningen.ChannelRead
		
		readState := dc.state.ReadState.ReadState(c.ID)
		if readState != nil && readState.LastMessageID.IsValid() {
			// Check for mentions first (they override everything)
			if readState.MentionCount > 0 {
				indication = ningen.ChannelMentioned
			} else {
				// For DMs, directly compare read state with channel's last message
				// Skip the permission check that ChannelIsUnread does
				if c.LastMessageID.IsValid() && readState.LastMessageID < c.LastMessageID {
					indication = ningen.ChannelUnread
				}
			}
		}
		
		ch.Unread = indication == ningen.ChannelUnread || indication == ningen.ChannelMentioned
		ch.Mentioned = indication == ningen.ChannelMentioned

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

// RequestGuildMembers requests specific guild members via gateway
// This populates the Cabinet cache with the requested members
func (dc *DiscordClient) RequestGuildMembers(guildID discord.GuildID, userIDs []discord.UserID) error {
	if !dc.IsConnected() {
		return NewError(NotConnected, "Not connected to Discord")
	}

	if len(userIDs) == 0 {
		return nil
	}

	// Send gateway command to request members
	err := dc.state.Gateway().Send(context.Background(), &gateway.RequestGuildMembersCommand{
		GuildIDs: []discord.GuildID{guildID},
		UserIDs:  userIDs,
	})
	if err != nil {
		return NewError(DiscordAPIError, fmt.Sprintf("Failed to request guild members: %v", err))
	}

	slog.Debug("Requested guild members", "guild_id", guildID, "user_count", len(userIDs))
	return nil
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

// ListThreads lists threads in a channel
func (dc *DiscordClient) ListThreads(channelID discord.ChannelID) ([]Thread, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	// Get the channel to determine its guild
	channel, err := dc.state.Cabinet.Channel(channelID)
	if err != nil {
		return nil, NewError(ChannelNotFound, fmt.Sprintf("Failed to get channel: %v", err))
	}

	// Get all channels from the guild - this includes threads from GuildCreateEvent
	allChannels, err := dc.state.Cabinet.Channels(channel.GuildID)
	if err != nil {
		return nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to get channels: %v", err))
	}

	var threads []discord.Channel
	
	// Filter for threads that belong to this channel
	for _, ch := range allChannels {
		if ch.ParentID == channelID && 
			(ch.Type == discord.GuildPublicThread ||
			 ch.Type == discord.GuildPrivateThread ||
			 ch.Type == discord.GuildAnnouncementThread) {
			threads = append(threads, ch)
		}
	}

	result := make([]Thread, len(threads))
	for i, t := range threads {
		// Check if user has joined the thread
		isJoined := dc.state.ThreadState.ThreadIsJoined(t.ID)
		result[i] = ToThread(t, isJoined)
	}

	return result, nil
}

// CreateThread creates a new thread
func (dc *DiscordClient) CreateThread(channelID discord.ChannelID, messageID discord.MessageID, name string, autoArchiveDuration int) (*Thread, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	if name == "" {
		return nil, NewError(InvalidParams, "Thread name cannot be empty")
	}

	// Set default auto archive duration if not provided
	if autoArchiveDuration == 0 {
		autoArchiveDuration = 60 // 60 minutes default
	}

	data := api.StartThreadData{
		Name:                name,
		AutoArchiveDuration: discord.ArchiveDuration(autoArchiveDuration),
	}

	var thread *discord.Channel
	var err error

	if messageID.IsValid() {
		// Create thread from message
		thread, err = dc.state.StartThreadWithMessage(channelID, messageID, data)
	} else {
		// Create standalone thread
		thread, err = dc.state.StartThreadWithoutMessage(channelID, data)
	}

	if err != nil {
		return nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to create thread: %v", err))
	}

	// User is automatically joined when creating thread
	isJoined := true
	result := ToThread(*thread, isJoined)
	return &result, nil
}

// CreateForumPost creates a forum post (thread with initial message)
func (dc *DiscordClient) CreateForumPost(channelID discord.ChannelID, name string, content string, tags []string) (*Thread, *Message, error) {
	if !dc.IsConnected() {
		return nil, nil, NewError(NotConnected, "Not connected to Discord")
	}

	if name == "" {
		return nil, nil, NewError(InvalidParams, "Post name cannot be empty")
	}

	if content == "" {
		return nil, nil, NewError(InvalidParams, "Post content cannot be empty")
	}

	// Convert tag strings to TagIDs (if provided)
	var appliedTags []discord.TagID
	for _, tagStr := range tags {
		tagID, err := discord.ParseSnowflake(tagStr)
		if err != nil {
			return nil, nil, NewError(InvalidParams, fmt.Sprintf("Invalid tag ID: %s", tagStr))
		}
		appliedTags = append(appliedTags, discord.TagID(tagID))
	}

	// For forum posts, we need to include the message in the thread creation request
	type forumThreadData struct {
		Name                string                   `json:"name"`
		AutoArchiveDuration discord.ArchiveDuration  `json:"auto_archive_duration"`
		AppliedTags         []discord.TagID          `json:"applied_tags,omitempty"`
		Message             struct {
			Content string `json:"content"`
		} `json:"message"`
	}

	data := forumThreadData{
		Name:                name,
		AutoArchiveDuration: discord.ArchiveDuration(dc.defaultAutoArchiveDuration),
		AppliedTags:         appliedTags,
	}
	data.Message.Content = content

	// Create forum post using the raw API
	var thread *discord.Channel
	err := dc.state.Client.RequestJSON(
		&thread, "POST",
		api.EndpointChannels+channelID.String()+"/threads",
		httputil.WithJSONBody(data),
	)
	if err != nil {
		return nil, nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to create forum post: %v", err))
	}

	// Get the initial message from the thread
	messages, err := dc.state.Messages(thread.ID, 1)
	if err != nil || len(messages) == 0 {
		return nil, nil, NewError(DiscordAPIError, fmt.Sprintf("Failed to get initial message: %v", err))
	}
	msg := messages[0]

	// Get member info for roles
	var roles []discord.RoleID
	if thread.GuildID.IsValid() {
		member, err := dc.state.Cabinet.Member(thread.GuildID, msg.Author.ID)
		if err == nil {
			roles = member.RoleIDs
		}
	}

	threadResult := ToThread(*thread, true)
	messageResult := ToMessage(msg, roles)
	return &threadResult, &messageResult, nil
}

// JoinThread joins a thread
func (dc *DiscordClient) JoinThread(threadID discord.ChannelID) error {
	if !dc.IsConnected() {
		return NewError(NotConnected, "Not connected to Discord")
	}

	if err := dc.state.JoinThread(threadID); err != nil {
		return NewError(DiscordAPIError, fmt.Sprintf("Failed to join thread: %v", err))
	}

	return nil
}

// LeaveThread leaves a thread
func (dc *DiscordClient) LeaveThread(threadID discord.ChannelID) error {
	if !dc.IsConnected() {
		return NewError(NotConnected, "Not connected to Discord")
	}

	if err := dc.state.LeaveThread(threadID); err != nil {
		return NewError(DiscordAPIError, fmt.Sprintf("Failed to leave thread: %v", err))
	}

	return nil
}

// ArchiveThread archives a thread
func (dc *DiscordClient) ArchiveThread(threadID discord.ChannelID) error {
	if !dc.IsConnected() {
		return NewError(NotConnected, "Not connected to Discord")
	}

	// Modify thread to set archived = true
	data := api.ModifyChannelData{
		Archived: option.True,
	}

	if err := dc.state.ModifyChannel(threadID, data); err != nil {
		return NewError(DiscordAPIError, fmt.Sprintf("Failed to archive thread: %v", err))
	}

	return nil
}

// GetForumTags gets available tags for a forum channel
func (dc *DiscordClient) GetForumTags(channelID discord.ChannelID) ([]Tag, error) {
	if !dc.IsConnected() {
		return nil, NewError(NotConnected, "Not connected to Discord")
	}

	channel, err := dc.state.Cabinet.Channel(channelID)
	if err != nil {
		return nil, NewError(ChannelNotFound, fmt.Sprintf("Failed to get channel: %v", err))
	}

	// Check if it's a forum channel
	if channel.Type != discord.GuildForum {
		return nil, NewError(InvalidParams, "Channel is not a forum channel")
	}

	result := make([]Tag, len(channel.AvailableTags))
	for i, t := range channel.AvailableTags {
		result[i] = ToTag(t)
	}

	return result, nil
}

// Event handlers

func (dc *DiscordClient) onReady(r *gateway.ReadyEvent) {
	dc.currentUserID = r.User.ID
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
		Params: mustMarshal(map[string]interface{}{
			"message":     msg,
			"channelName": channel.Name,
		}),
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

func (dc *DiscordClient) onThreadCreate(t *gateway.ThreadCreateEvent) {
	isJoined := dc.state.ThreadState.ThreadIsJoined(t.ID)
	thread := ToThread(t.Channel, isJoined)

	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "threadCreated",
		Params:  mustMarshal(map[string]interface{}{"thread": thread}),
	})
}

func (dc *DiscordClient) onThreadUpdate(t *gateway.ThreadUpdateEvent) {
	isJoined := dc.state.ThreadState.ThreadIsJoined(t.ID)
	thread := ToThread(t.Channel, isJoined)

	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "threadUpdated",
		Params:  mustMarshal(map[string]interface{}{"thread": thread}),
	})
}

func (dc *DiscordClient) onThreadDelete(t *gateway.ThreadDeleteEvent) {
	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "threadDeleted",
		Params:  mustMarshal(map[string]interface{}{
			"threadId": t.ID.String(),
			"guildId":  t.GuildID.String(),
			"parentId": t.ParentID.String(),
		}),
	})
}

func (dc *DiscordClient) onGuildMembersChunk(g *gateway.GuildMembersChunkEvent) {
	// Convert members to IPC format
	members := make([]Member, len(g.Members))
	for i, m := range g.Members {
		members[i] = ToMember(m, m.User)
	}

	dc.server.Broadcast(&Notification{
		JSONRPC: "2.0",
		Method:  "guildMembersChunk",
		Params: mustMarshal(map[string]interface{}{
			"guildId": g.GuildID.String(),
			"members": members,
		}),
	})
}
