package internal

import (
	"fmt"
	"time"

	"github.com/diamondburned/arikawa/v3/discord"
)

// User represents a Discord user
type User struct {
	ID            string   `json:"id"`
	Username      string   `json:"username"`
	Discriminator string   `json:"discriminator"`
	Avatar        string   `json:"avatar"`
	Bot           bool     `json:"bot"`
	Roles         []string `json:"roles,omitempty"` // Role IDs for this user in the context
}

// Guild represents a Discord guild/server
type Guild struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	Icon    string `json:"icon"`
	OwnerID string `json:"ownerId"`
}

// Channel represents a Discord channel
type Channel struct {
	ID              string `json:"id"`
	GuildID         string `json:"guildId,omitempty"`
	Name            string `json:"name"`
	Type            int    `json:"type"`
	Position        int    `json:"position"`
	ParentID        string `json:"parentId,omitempty"`
	Unread          bool   `json:"unread"`
	Mentioned       bool   `json:"mentioned"`
	MentionCount    int    `json:"mentionCount"`
	MessageCount    int    `json:"messageCount,omitempty"` // For forum channels: active thread count
	LastMessageID   string `json:"lastMessageId,omitempty"` // ID of last message in channel
}

// Message represents a Discord message
type Message struct {
	ID                string       `json:"id"`
	ChannelID         string       `json:"channelId"`
	GuildID           string       `json:"guildId,omitempty"`
	Author            User         `json:"author"`
	Content           string       `json:"content"`
	Timestamp         time.Time    `json:"timestamp"`
	EditedTimestamp   *time.Time   `json:"editedTimestamp,omitempty"`
	Attachments       []Attachment `json:"attachments"`
	Embeds            []Embed      `json:"embeds"`
	Reactions         []Reaction   `json:"reactions"`
	ReferencedMessage *string      `json:"referencedMessage,omitempty"` // Message ID for replies
	Mentions          []string     `json:"mentions"`                    // User IDs mentioned in message
}

// Attachment represents a message attachment
type Attachment struct {
	ID          string `json:"id"`
	Filename    string `json:"filename"`
	ContentType string `json:"contentType,omitempty"`
	Size        uint64 `json:"size"`
	URL         string `json:"url"`
	ProxyURL    string `json:"proxyUrl,omitempty"`
	Height      uint   `json:"height,omitempty"`
	Width       uint   `json:"width,omitempty"`
}

// Embed represents a message embed
type Embed struct {
	Type      string          `json:"type,omitempty"`
	URL       string          `json:"url,omitempty"`
	Thumbnail *EmbedThumbnail `json:"thumbnail,omitempty"`
	Image     *EmbedImage     `json:"image,omitempty"`
	Video     *EmbedVideo     `json:"video,omitempty"`
}

// EmbedThumbnail represents an embed thumbnail
type EmbedThumbnail struct {
	URL    string `json:"url"`
	Height uint   `json:"height,omitempty"`
	Width  uint   `json:"width,omitempty"`
}

// EmbedImage represents an embed image
type EmbedImage struct {
	URL    string `json:"url"`
	Height uint   `json:"height,omitempty"`
	Width  uint   `json:"width,omitempty"`
}

// EmbedVideo represents an embed video
type EmbedVideo struct {
	URL    string `json:"url"`
	Height uint   `json:"height,omitempty"`
	Width  uint   `json:"width,omitempty"`
}

// Reaction represents a message reaction
type Reaction struct {
	Emoji string `json:"emoji"`
	Count int    `json:"count"`
	Me    bool   `json:"me"` // Whether current user reacted
}

// ReadState represents channel read state
type ReadState struct {
	ChannelID     string `json:"channelId"`
	LastMessageID string `json:"lastMessageId"`
	MentionCount  int    `json:"mentionCount"`
}

// Member represents a guild member
type Member struct {
	User     User     `json:"user"`
	Nick     string   `json:"nick,omitempty"`     // Nickname in guild
	RoleIDs  []string `json:"roleIds"`            // Role IDs
	JoinedAt string   `json:"joinedAt,omitempty"` // ISO 8601 timestamp
}

// Role represents a guild role
type Role struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Color       int    `json:"color"`       // RGB color value
	Hoist       bool   `json:"hoist"`       // Whether displayed separately
	Position    int    `json:"position"`    // Position in role hierarchy
	Permissions string `json:"permissions"` // Permission bitfield as string
	Mentionable bool   `json:"mentionable"` // Whether can be @mentioned
}

// Thread represents a Discord thread
type Thread struct {
	ID                  string   `json:"id"`
	GuildID             string   `json:"guildId"`
	ParentID            string   `json:"parentId"` // Parent channel
	Name                string   `json:"name"`
	Type                int      `json:"type"`
	MessageCount        int      `json:"messageCount"`
	MemberCount         int      `json:"memberCount"`
	Archived            bool     `json:"archived"`
	Locked              bool     `json:"locked"`
	Invitable           bool     `json:"invitable,omitempty"`
	AutoArchiveDuration int      `json:"autoArchiveDuration"`
	ArchiveTimestamp    string   `json:"archiveTimestamp"`
	CreateTimestamp     string   `json:"createTimestamp,omitempty"`
	IsJoined            bool     `json:"isJoined"` // Whether current user joined
	AppliedTags         []string `json:"appliedTags,omitempty"` // For forum posts
}

// Tag represents a forum tag
type Tag struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Moderated bool   `json:"moderated"`
	EmojiID   string `json:"emojiId,omitempty"`
	EmojiName string `json:"emojiName,omitempty"`
}

// Helper functions to convert from arikawa types to IPC DTOs

// ToUser converts arikawa User to IPC User
func ToUser(u discord.User, roles []discord.RoleID) User {
	roleIDs := make([]string, len(roles))
	for i, r := range roles {
		roleIDs[i] = r.String()
	}

	return User{
		ID:            u.ID.String(),
		Username:      u.Username,
		Discriminator: u.Discriminator,
		Avatar:        u.Avatar,
		Bot:           u.Bot,
		Roles:         roleIDs,
	}
}

// ToGuild converts arikawa Guild to IPC Guild
func ToGuild(g discord.Guild) Guild {
	return Guild{
		ID:      g.ID.String(),
		Name:    g.Name,
		Icon:    g.Icon,
		OwnerID: g.OwnerID.String(),
	}
}

// ToChannel converts arikawa Channel to IPC Channel (unread info added separately)
func ToChannel(c discord.Channel) Channel {
	return Channel{
		ID:            c.ID.String(),
		GuildID:       c.GuildID.String(),
		Name:          c.Name,
		Type:          int(c.Type),
		Position:      c.Position,
		ParentID:      c.ParentID.String(),
		LastMessageID: c.LastMessageID.String(),
	}
}

// ToMessage converts arikawa Message to IPC Message
func ToMessage(m discord.Message, roles []discord.RoleID) Message {
	attachments := make([]Attachment, len(m.Attachments))
	for i, a := range m.Attachments {
		attachments[i] = Attachment{
			ID:          a.ID.String(),
			Filename:    a.Filename,
			ContentType: a.ContentType,
			Size:        a.Size,
			URL:         string(a.URL),
			ProxyURL:    string(a.Proxy),
			Height:      a.Height,
			Width:       a.Width,
		}
	}

	embeds := make([]Embed, len(m.Embeds))
	for i, e := range m.Embeds {
		embed := Embed{
			Type: string(e.Type),
			URL:  string(e.URL),
		}

		if e.Thumbnail != nil {
			embed.Thumbnail = &EmbedThumbnail{
				URL:    string(e.Thumbnail.URL),
				Height: e.Thumbnail.Height,
				Width:  e.Thumbnail.Width,
			}
		}

		if e.Image != nil {
			embed.Image = &EmbedImage{
				URL:    string(e.Image.URL),
				Height: e.Image.Height,
				Width:  e.Image.Width,
			}
		}

		if e.Video != nil {
			embed.Video = &EmbedVideo{
				URL:    string(e.Video.URL),
				Height: e.Video.Height,
				Width:  e.Video.Width,
			}
		}

		embeds[i] = embed
	}

	reactions := make([]Reaction, len(m.Reactions))
	for i, r := range m.Reactions {
		reactions[i] = Reaction{
			Emoji: r.Emoji.Name,
			Count: r.Count,
			Me:    r.Me,
		}
	}

	mentions := make([]string, len(m.Mentions))
	for i, u := range m.Mentions {
		mentions[i] = u.ID.String()
	}

	msg := Message{
		ID:          m.ID.String(),
		ChannelID:   m.ChannelID.String(),
		GuildID:     m.GuildID.String(),
		Author:      ToUser(m.Author, roles),
		Content:     m.Content,
		Timestamp:   m.Timestamp.Time(),
		Attachments: attachments,
		Embeds:      embeds,
		Reactions:   reactions,
		Mentions:    mentions,
	}

	if m.EditedTimestamp.IsValid() {
		t := m.EditedTimestamp.Time()
		msg.EditedTimestamp = &t
	}

	if m.Reference != nil && m.Reference.MessageID.IsValid() {
		id := m.Reference.MessageID.String()
		msg.ReferencedMessage = &id
	}

	return msg
}

// ToMember converts arikawa Member to IPC Member
func ToMember(m discord.Member, u discord.User) Member {
	roleIDs := make([]string, len(m.RoleIDs))
	for i, r := range m.RoleIDs {
		roleIDs[i] = r.String()
	}

	member := Member{
		User:    ToUser(u, m.RoleIDs),
		Nick:    m.Nick,
		RoleIDs: roleIDs,
	}

	if m.Joined.IsValid() {
		member.JoinedAt = m.Joined.Time().Format(time.RFC3339)
	}

	return member
}

// ToRole converts arikawa Role to IPC Role
func ToRole(r discord.Role) Role {
	return Role{
		ID:          r.ID.String(),
		Name:        r.Name,
		Color:       int(r.Color),
		Hoist:       r.Hoist,
		Position:    r.Position,
		Permissions: fmt.Sprintf("%d", r.Permissions), // Convert uint64 to string
		Mentionable: r.Mentionable,
	}
}

// ToThread converts arikawa Channel (thread) to IPC Thread
func ToThread(c discord.Channel, isJoined bool) Thread {
	thread := Thread{
		ID:       c.ID.String(),
		GuildID:  c.GuildID.String(),
		ParentID: c.ParentID.String(),
		Name:     c.Name,
		Type:     int(c.Type),
		MessageCount: c.MessageCount,
		MemberCount:  c.MemberCount,
		IsJoined:     isJoined,
	}

	// Add thread metadata if available
	if c.ThreadMetadata != nil {
		thread.Archived = c.ThreadMetadata.Archived
		thread.Locked = c.ThreadMetadata.Locked
		thread.Invitable = c.ThreadMetadata.Invitable
		thread.AutoArchiveDuration = int(c.ThreadMetadata.AutoArchiveDuration)
		thread.ArchiveTimestamp = c.ThreadMetadata.ArchiveTimestamp.Time().Format(time.RFC3339)
		
		if c.ThreadMetadata.CreateTimestamp != nil && c.ThreadMetadata.CreateTimestamp.IsValid() {
			thread.CreateTimestamp = c.ThreadMetadata.CreateTimestamp.Time().Format(time.RFC3339)
		}
	}

	// Add applied tags for forum posts
	if len(c.AppliedTags) > 0 {
		thread.AppliedTags = make([]string, len(c.AppliedTags))
		for i, tag := range c.AppliedTags {
			thread.AppliedTags[i] = tag.String()
		}
	}

	return thread
}

// ToTag converts arikawa Tag to IPC Tag
func ToTag(t discord.Tag) Tag {
	tag := Tag{
		ID:        t.ID.String(),
		Name:      t.Name,
		Moderated: t.Moderated,
	}

	if t.EmojiID.IsValid() {
		tag.EmojiID = t.EmojiID.String()
	}
	if t.EmojiName != nil && *t.EmojiName != "" {
		tag.EmojiName = *t.EmojiName
	}

	return tag
}
