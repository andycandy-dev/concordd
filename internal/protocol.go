// Package internal implements the concordd IPC server using JSON-RPC 2.0 over Unix domain sockets.
//
// The protocol follows the JSON-RPC 2.0 spec with line-delimited messages (each ending in \n).
// Clients send requests and receive both responses (with matching ID) and notifications (no ID).
package internal

import (
	"encoding/json"
	"fmt"
)

// Request represents a JSON-RPC 2.0 request from client to daemon.
type Request struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id,omitempty"` // Can be string, number, or null
	Method  string           `json:"method"`
	Params  json.RawMessage  `json:"params,omitempty"`
}

// Response represents a JSON-RPC 2.0 response from daemon to client.
// Either Result or Error will be set, never both.
type Response struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id,omitempty"`
	Result  interface{}      `json:"result,omitempty"`
	Error   *Error           `json:"error,omitempty"`
}

// Notification represents a JSON-RPC 2.0 notification (no ID, no response expected).
// Used for push events like messageCreated, readStateUpdated, etc.
type Notification struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

// Error represents a JSON-RPC 2.0 error
type Error struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
}

// Standard JSON-RPC 2.0 error codes per spec.
const (
	ParseError     = -32700
	InvalidRequest = -32600
	MethodNotFound = -32601
	InvalidParams  = -32602
	InternalError  = -32603
)

// Application-specific error codes (range -32000 to -32099 per spec).
const (
	DiscordAPIError  = -32000 // Discord API returned an error
	NotConnected     = -32001 // Gateway connection not established yet
	PermissionDenied = -32002 // User lacks Discord permissions for action
	ChannelNotFound  = -32003 // Channel ID not in cache or doesn't exist
	GuildNotFound    = -32004 // Guild ID not in cache or user not a member
)

// NewError creates a new JSON-RPC error
func NewError(code int, message string) *Error {
	return &Error{
		Code:    code,
		Message: message,
	}
}

// NewErrorWithData creates a new JSON-RPC error with additional data
func NewErrorWithData(code int, message string, data interface{}) *Error {
	return &Error{
		Code:    code,
		Message: message,
		Data:    data,
	}
}

// Error implements the error interface
func (e *Error) Error() string {
	return fmt.Sprintf("JSON-RPC error %d: %s", e.Code, e.Message)
}

// mustMarshal marshals data for notifications. Panics on marshal failure
// since notification params should always be serializable DTOs.
func mustMarshal(v interface{}) json.RawMessage {
	data, err := json.Marshal(v)
	if err != nil {
		panic(fmt.Sprintf("failed to marshal: %v", err))
	}
	return data
}
