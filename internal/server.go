package internal

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sync"
)

// Server represents the IPC server
type Server struct {
	socketPath string
	listener   net.Listener
	handler    *Handler
	clients    map[*Client]struct{}
	clientsMu  sync.RWMutex
	ctx        context.Context
	cancel     context.CancelFunc
}

// NewServer creates a new IPC server
func NewServer(socketPath string, handler *Handler) *Server {
	ctx, cancel := context.WithCancel(context.Background())
	return &Server{
		socketPath: socketPath,
		handler:    handler,
		clients:    make(map[*Client]struct{}),
		ctx:        ctx,
		cancel:     cancel,
	}
}

// Start starts the IPC server
func (s *Server) Start() error {
	// Remove existing socket if it exists
	if err := os.RemoveAll(s.socketPath); err != nil {
		return fmt.Errorf("failed to remove existing socket: %w", err)
	}

	// Create Unix socket
	listener, err := net.Listen("unix", s.socketPath)
	if err != nil {
		return fmt.Errorf("failed to create socket: %w", err)
	}
	s.listener = listener

	// Set socket permissions (owner only)
	if err := os.Chmod(s.socketPath, 0600); err != nil {
		return fmt.Errorf("failed to set socket permissions: %w", err)
	}

	slog.Info("IPC server started", "socket", s.socketPath)

	// Accept connections
	go s.acceptLoop()

	return nil
}

// acceptLoop accepts incoming connections
func (s *Server) acceptLoop() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.ctx.Done():
				return
			default:
				slog.Error("failed to accept connection", "err", err)
				continue
			}
		}

		client := NewClient(conn, s)
		s.addClient(client)
		go client.handle()
	}
}

// addClient registers a new client
func (s *Server) addClient(client *Client) {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	s.clients[client] = struct{}{}
	slog.Info("client connected", "addr", client.conn.RemoteAddr())
}

// removeClient unregisters a client
func (s *Server) removeClient(client *Client) {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	delete(s.clients, client)
	slog.Info("client disconnected", "addr", client.conn.RemoteAddr())
}

// Broadcast sends a notification to all connected clients
func (s *Server) Broadcast(notification *Notification) {
	s.clientsMu.RLock()
	defer s.clientsMu.RUnlock()

	data, err := json.Marshal(notification)
	if err != nil {
		slog.Error("failed to marshal notification", "err", err)
		return
	}

	for client := range s.clients {
		client.Send(data)
	}
}

// Stop stops the IPC server
func (s *Server) Stop() error {
	s.cancel()

	// Close all client connections
	s.clientsMu.Lock()
	for client := range s.clients {
		client.Close()
	}
	s.clientsMu.Unlock()

	if s.listener != nil {
		s.listener.Close()
	}

	// Remove socket file
	os.RemoveAll(s.socketPath)

	slog.Info("IPC server stopped")
	return nil
}

// Client represents a connected IPC client
type Client struct {
	conn   net.Conn
	server *Server
	writer *bufio.Writer
	mu     sync.Mutex
}

// NewClient creates a new client
func NewClient(conn net.Conn, server *Server) *Client {
	return &Client{
		conn:   conn,
		server: server,
		writer: bufio.NewWriter(conn),
	}
}

// handle processes client requests
func (c *Client) handle() {
	defer func() {
		c.server.removeClient(c)
		c.conn.Close()
	}()

	scanner := bufio.NewScanner(c.conn)
	for scanner.Scan() {
		line := scanner.Bytes()
		c.handleRequest(line)
	}

	if err := scanner.Err(); err != nil {
		slog.Error("client read error", "err", err)
	}
}

// handleRequest processes a single request
func (c *Client) handleRequest(data []byte) {
	var req Request
	if err := json.Unmarshal(data, &req); err != nil {
		c.sendError(nil, ParseError, "Parse error")
		return
	}

	// Validate JSON-RPC version
	if req.JSONRPC != "2.0" {
		c.sendError(req.ID, InvalidRequest, "Invalid Request")
		return
	}

	// Handle request
	result, err := c.server.handler.Handle(&req)
	if err != nil {
		if rpcErr, ok := err.(*Error); ok {
			c.sendError(req.ID, rpcErr.Code, rpcErr.Message)
		} else {
			c.sendError(req.ID, InternalError, err.Error())
		}
		return
	}

	// Send response (only if request has ID)
	if req.ID != nil {
		c.sendResponse(req.ID, result)
	}
}

// sendResponse sends a successful response
func (c *Client) sendResponse(id *json.RawMessage, result interface{}) {
	resp := Response{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	}

	data, err := json.Marshal(resp)
	if err != nil {
		slog.Error("failed to marshal response", "err", err)
		return
	}

	c.Send(data)
}

// sendError sends an error response
func (c *Client) sendError(id *json.RawMessage, code int, message string) {
	resp := Response{
		JSONRPC: "2.0",
		ID:      id,
		Error:   NewError(code, message),
	}

	data, err := json.Marshal(resp)
	if err != nil {
		slog.Error("failed to marshal error", "err", err)
		return
	}

	c.Send(data)
}

// Send sends data to the client
func (c *Client) Send(data []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.writer.Write(data)
	c.writer.WriteByte('\n')
	c.writer.Flush()
}

// Close closes the client connection
func (c *Client) Close() {
	c.conn.Close()
}
