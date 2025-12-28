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
	ID           string `json:"id"`
	GuildID      string `json:"guildId,omitempty"`
	Name         string `json:"name"`
	Type         int    `json:"type"`
	Position     int    `json:"position"`
	ParentID     string `json:"parentId,omitempty"`
	Unread       bool   `json:"unread"`
	Mentioned    bool   `json:"mentioned"`
	MentionCount int    `json:"mentionCount"`
}

// Message represents a Discord message
type Message struct {
	ID                string     `json:"id"`
	ChannelID         string     `json:"channelId"`
	GuildID           string     `json:"guildId,omitempty"`
	Author            User       `json:"author"`
	Content           string     `json:"content"`
	Timestamp         time.Time  `json:"timestamp"`
	EditedTimestamp   *time.Time `json:"editedTimestamp,omitempty"`
	Attachments       []string   `json:"attachments"` // URLs for MVP
	Embeds            int        `json:"embeds"`      // Count for MVP
	Reactions         []Reaction `json:"reactions"`
	ReferencedMessage *string    `json:"referencedMessage,omitempty"` // Message ID for replies
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
		ID:       c.ID.String(),
		GuildID:  c.GuildID.String(),
		Name:     c.Name,
		Type:     int(c.Type),
		Position: c.Position,
		ParentID: c.ParentID.String(),
	}
}

// ToMessage converts arikawa Message to IPC Message
func ToMessage(m discord.Message, roles []discord.RoleID) Message {
	attachments := make([]string, len(m.Attachments))
	for i, a := range m.Attachments {
		attachments[i] = a.URL
	}

	reactions := make([]Reaction, len(m.Reactions))
	for i, r := range m.Reactions {
		reactions[i] = Reaction{
			Emoji: r.Emoji.Name,
			Count: r.Count,
			Me:    r.Me,
		}
	}

	msg := Message{
		ID:          m.ID.String(),
		ChannelID:   m.ChannelID.String(),
		GuildID:     m.GuildID.String(),
		Author:      ToUser(m.Author, roles),
		Content:     m.Content,
		Timestamp:   m.Timestamp.Time(),
		Attachments: attachments,
		Embeds:      len(m.Embeds),
		Reactions:   reactions,
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
