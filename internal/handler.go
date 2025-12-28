package internal

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/diamondburned/arikawa/v3/discord"
)

// Handler handles JSON-RPC requests
type Handler struct {
	methods map[string]MethodFunc
	discord *DiscordClient
}

// MethodFunc is a function that handles a specific method
type MethodFunc func(params json.RawMessage) (interface{}, error)

// NewHandler creates a new handler
func NewHandler() *Handler {
	h := &Handler{
		methods: make(map[string]MethodFunc),
	}

	// Register default methods
	h.RegisterMethod("ping", h.handlePing)

	return h
}

// SetDiscordClient sets the Discord client for the handler
func (h *Handler) SetDiscordClient(dc *DiscordClient) {
	h.discord = dc

	// Register Discord methods
	h.RegisterMethod("listGuilds", h.handleListGuilds)
	h.RegisterMethod("listChannels", h.handleListChannels)
	h.RegisterMethod("getMessages", h.handleGetMessages)
	h.RegisterMethod("sendMessage", h.handleSendMessage)
	h.RegisterMethod("replyToMessage", h.handleReplyToMessage)
	h.RegisterMethod("editMessage", h.handleEditMessage)
	h.RegisterMethod("deleteMessage", h.handleDeleteMessage)
	h.RegisterMethod("markAsRead", h.handleMarkAsRead)
	h.RegisterMethod("getReadState", h.handleGetReadState)
	h.RegisterMethod("getGuildMembers", h.handleGetGuildMembers)
	h.RegisterMethod("getGuildRoles", h.handleGetGuildRoles)
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

// handleGetMessages handles the getMessages method
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

// handleGetGuildMembers handles the getGuildMembers method
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
