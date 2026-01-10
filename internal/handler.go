package internal

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/diamondburned/arikawa/v3/discord"
)

// Handler routes JSON-RPC methods to their implementations.
// Discord methods are registered after SetDiscordClient is called.
type Handler struct {
	methods map[string]MethodFunc
	discord *DiscordClient
}

// MethodFunc handles a specific JSON-RPC method.
// Returns result data or an error (automatically wrapped in JSON-RPC Error).
type MethodFunc func(params json.RawMessage) (interface{}, error)

// NewHandler creates a new handler
func NewHandler() *Handler {
	h := &Handler{
		methods: make(map[string]MethodFunc),
	}

	// Register default methods
	h.RegisterMethod("ping", h.handlePing)
	h.RegisterMethod("getCurrentUser", h.handleGetCurrentUser)

	return h
}

// SetDiscordClient sets the Discord client and registers all Discord-dependent methods.
// Called after gateway connection is established.
func (h *Handler) SetDiscordClient(dc *DiscordClient) {
	h.discord = dc

	// Register Discord methods
	h.RegisterMethod("listGuilds", h.handleListGuilds)
	h.RegisterMethod("listChannels", h.handleListChannels)
	h.RegisterMethod("listDMs", h.handleListDMs)
	h.RegisterMethod("getMessages", h.handleGetMessages)
	h.RegisterMethod("sendMessage", h.handleSendMessage)
	h.RegisterMethod("replyToMessage", h.handleReplyToMessage)
	h.RegisterMethod("editMessage", h.handleEditMessage)
	h.RegisterMethod("deleteMessage", h.handleDeleteMessage)
	h.RegisterMethod("markAsRead", h.handleMarkAsRead)
	h.RegisterMethod("getReadState", h.handleGetReadState)
	h.RegisterMethod("getGuildMembers", h.handleGetGuildMembers)
	h.RegisterMethod("getGuildRoles", h.handleGetGuildRoles)
	h.RegisterMethod("requestGuildMembers", h.handleRequestGuildMembers)
	
	// Thread methods
	h.RegisterMethod("listThreads", h.handleListThreads)
	h.RegisterMethod("createThread", h.handleCreateThread)
	h.RegisterMethod("createForumPost", h.handleCreateForumPost)
	h.RegisterMethod("joinThread", h.handleJoinThread)
	h.RegisterMethod("leaveThread", h.handleLeaveThread)
	h.RegisterMethod("archiveThread", h.handleArchiveThread)
	h.RegisterMethod("getForumTags", h.handleGetForumTags)
}

// RegisterMethod registers a method handler
func (h *Handler) RegisterMethod(method string, handler MethodFunc) {
	h.methods[method] = handler
}

// Handle handles a JSON-RPC request
func (h *Handler) Handle(req *Request) (interface{}, error) {
	handler, ok := h.methods[req.Method]
	if !ok {
		return nil, NewError(MethodNotFound, fmt.Sprintf("Method not found: %s", req.Method))
	}

	return handler(req.Params)
}

// handlePing handles the ping method
func (h *Handler) handlePing(params json.RawMessage) (interface{}, error) {
	return map[string]interface{}{
		"status":    "ok",
		"timestamp": time.Now().Format(time.RFC3339),
	}, nil
}

// handleGetCurrentUser returns the authenticated user's ID.
// Returns error if called before gateway READY event.
func (h *Handler) handleGetCurrentUser(params json.RawMessage) (interface{}, error) {
	if h.discord == nil {
		return nil, NewError(InternalError, "Discord client not initialized")
	}

	userID := h.discord.currentUserID

	if !userID.IsValid() {
		return nil, NewError(InternalError, "Current user not available yet")
	}
	
	return map[string]interface{}{
		"id": userID.String(),
	}, nil
}

// handleListGuilds handles the listGuilds method
func (h *Handler) handleListGuilds(params json.RawMessage) (interface{}, error) {
	guilds, err := h.discord.GetGuilds()
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"guilds": guilds,
	}, nil
}

// handleListChannels handles the listChannels method
func (h *Handler) handleListChannels(params json.RawMessage) (interface{}, error) {
	var req struct {
		GuildID string `json:"guildId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	guildID, err := discord.ParseSnowflake(req.GuildID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid guild ID")
	}

	channels, err := h.discord.GetChannels(discord.GuildID(guildID))
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"channels": channels,
	}, nil
}

// handleListDMs handles the listDMs method
func (h *Handler) handleListDMs(params json.RawMessage) (interface{}, error) {
	if h.discord == nil {
		return nil, NewError(NotConnected, "Discord client not initialized")
	}

	channels, err := h.discord.GetDMChannels()
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"channels": channels,
	}, nil
}

// handleGetMessages fetches message history with optional pagination.
// First call per channel may be slow (fetches from API). Subsequent calls are instant (cached).
// Use 'before' param to load older messages.
func (h *Handler) handleGetMessages(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
		Limit     uint   `json:"limit,omitempty"`
		Before    string `json:"before,omitempty"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	var beforeID discord.MessageID
	if req.Before != "" {
		id, err := discord.ParseSnowflake(req.Before)
		if err != nil {
			return nil, NewError(InvalidParams, "Invalid before message ID")
		}
		beforeID = discord.MessageID(id)
	}

	messages, err := h.discord.GetMessages(discord.ChannelID(channelID), req.Limit, beforeID)
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"messages": messages,
	}, nil
}

// handleSendMessage handles the sendMessage method
func (h *Handler) handleSendMessage(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
		Content   string `json:"content"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	message, err := h.discord.SendMessage(discord.ChannelID(channelID), req.Content)
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"message": message,
	}, nil
}

// handleReplyToMessage handles the replyToMessage method
func (h *Handler) handleReplyToMessage(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
		MessageID string `json:"messageId"`
		Content   string `json:"content"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	messageID, err := discord.ParseSnowflake(req.MessageID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid message ID")
	}

	message, err := h.discord.ReplyToMessage(discord.ChannelID(channelID), discord.MessageID(messageID), req.Content)
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"message": message,
	}, nil
}

// handleMarkAsRead handles the markAsRead method
func (h *Handler) handleMarkAsRead(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
		MessageID string `json:"messageId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	messageID, err := discord.ParseSnowflake(req.MessageID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid message ID")
	}

	if err := h.discord.MarkAsRead(discord.ChannelID(channelID), discord.MessageID(messageID)); err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"success": true,
	}, nil
}

// handleEditMessage handles the editMessage method
func (h *Handler) handleEditMessage(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
		MessageID string `json:"messageId"`
		Content   string `json:"content"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	messageID, err := discord.ParseSnowflake(req.MessageID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid message ID")
	}

	message, err := h.discord.EditMessage(discord.ChannelID(channelID), discord.MessageID(messageID), req.Content)
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"message": message,
	}, nil
}

// handleDeleteMessage handles the deleteMessage method
func (h *Handler) handleDeleteMessage(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
		MessageID string `json:"messageId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	messageID, err := discord.ParseSnowflake(req.MessageID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid message ID")
	}

	if err := h.discord.DeleteMessage(discord.ChannelID(channelID), discord.MessageID(messageID)); err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"success": true,
	}, nil
}

// handleGetReadState handles the getReadState method
func (h *Handler) handleGetReadState(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	readState, err := h.discord.GetReadState(discord.ChannelID(channelID))
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"readState": readState,
	}, nil
}

// handleGetGuildMembers returns cached members from gateway events.
// For guilds >75 members, may only include recently active users.
// Use requestGuildMembers to fetch specific user data for mention resolution.
func (h *Handler) handleGetGuildMembers(params json.RawMessage) (interface{}, error) {
	var req struct {
		GuildID string `json:"guildId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	guildID, err := discord.ParseSnowflake(req.GuildID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid guild ID")
	}

	members, err := h.discord.GetGuildMembers(discord.GuildID(guildID))
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"members": members,
	}, nil
}

// handleGetGuildRoles handles the getGuildRoles method
func (h *Handler) handleGetGuildRoles(params json.RawMessage) (interface{}, error) {
	var req struct {
		GuildID string `json:"guildId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	guildID, err := discord.ParseSnowflake(req.GuildID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid guild ID")
	}

	roles, err := h.discord.GetGuildRoles(discord.GuildID(guildID))
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"roles": roles,
	}, nil
}

// handleRequestGuildMembers requests specific member data via gateway.
// Members arrive asynchronously and are cached. No immediate return of member data.
// Use this when mentions need resolution but users aren't in getGuildMembers cache.
func (h *Handler) handleRequestGuildMembers(params json.RawMessage) (interface{}, error) {
	var req struct {
		GuildID string   `json:"guildId"`
		UserIDs []string `json:"userIds"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	guildID, err := discord.ParseSnowflake(req.GuildID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid guild ID")
	}

	userIDs := make([]discord.UserID, len(req.UserIDs))
	for i, id := range req.UserIDs {
		userID, err := discord.ParseSnowflake(id)
		if err != nil {
			return nil, NewError(InvalidParams, fmt.Sprintf("Invalid user ID: %s", id))
		}
		userIDs[i] = discord.UserID(userID)
	}

	err = h.discord.RequestGuildMembers(discord.GuildID(guildID), userIDs)
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"status": "ok",
	}, nil
}

// handleListThreads returns active threads from state cache.
// For forum channels, these are the forum posts.
func (h *Handler) handleListThreads(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	threads, err := h.discord.ListThreads(discord.ChannelID(channelID))
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"threads": threads,
	}, nil
}

// handleCreateThread creates a thread from a message or standalone.
// If messageId is empty, creates a standalone thread (ANNOUNCEMENT_THREAD or PUBLIC_THREAD).
func (h *Handler) handleCreateThread(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID           string `json:"channelId"`
		MessageID           string `json:"messageId,omitempty"`
		Name                string `json:"name"`
		AutoArchiveDuration int    `json:"autoArchiveDuration,omitempty"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	var messageID discord.MessageID
	if req.MessageID != "" {
		mid, err := discord.ParseSnowflake(req.MessageID)
		if err != nil {
			return nil, NewError(InvalidParams, "Invalid message ID")
		}
		messageID = discord.MessageID(mid)
	}

	thread, err := h.discord.CreateThread(discord.ChannelID(channelID), messageID, req.Name, req.AutoArchiveDuration)
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"thread": thread,
	}, nil
}

// handleCreateForumPost creates a new post in a forum channel.
// Returns both the thread and the initial message.
func (h *Handler) handleCreateForumPost(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string   `json:"channelId"`
		Name      string   `json:"name"`
		Content   string   `json:"content"`
		Tags      []string `json:"tags,omitempty"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	thread, message, err := h.discord.CreateForumPost(discord.ChannelID(channelID), req.Name, req.Content, req.Tags)
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"thread":  thread,
		"message": message,
	}, nil
}

// handleJoinThread handles the joinThread method
func (h *Handler) handleJoinThread(params json.RawMessage) (interface{}, error) {
	var req struct {
		ThreadID string `json:"threadId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	threadID, err := discord.ParseSnowflake(req.ThreadID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid thread ID")
	}

	if err := h.discord.JoinThread(discord.ChannelID(threadID)); err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"success": true,
	}, nil
}

// handleLeaveThread handles the leaveThread method
func (h *Handler) handleLeaveThread(params json.RawMessage) (interface{}, error) {
	var req struct {
		ThreadID string `json:"threadId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	threadID, err := discord.ParseSnowflake(req.ThreadID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid thread ID")
	}

	if err := h.discord.LeaveThread(discord.ChannelID(threadID)); err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"success": true,
	}, nil
}

// handleArchiveThread handles the archiveThread method
func (h *Handler) handleArchiveThread(params json.RawMessage) (interface{}, error) {
	var req struct {
		ThreadID string `json:"threadId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	threadID, err := discord.ParseSnowflake(req.ThreadID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid thread ID")
	}

	if err := h.discord.ArchiveThread(discord.ChannelID(threadID)); err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"success": true,
	}, nil
}

// handleGetForumTags handles the getForumTags method
func (h *Handler) handleGetForumTags(params json.RawMessage) (interface{}, error) {
	var req struct {
		ChannelID string `json:"channelId"`
	}

	if err := json.Unmarshal(params, &req); err != nil {
		return nil, NewError(InvalidParams, "Invalid parameters")
	}

	channelID, err := discord.ParseSnowflake(req.ChannelID)
	if err != nil {
		return nil, NewError(InvalidParams, "Invalid channel ID")
	}

	tags, err := h.discord.GetForumTags(discord.ChannelID(channelID))
	if err != nil {
		return nil, err
	}

	return map[string]interface{}{
		"tags": tags,
	}, nil
}
