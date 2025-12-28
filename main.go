package main

import (
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/andycandy-dev/concordd/internal"
	"github.com/andycandy-dev/concordd/internal/keyring"
	"github.com/andycandy-dev/concordd/internal/logger"
	"github.com/spf13/cobra"
)

var (
	socketPath  string
	token       string
	logPath     string
	logLevel    string
	historySize int
	configPath  string
)

var rootCmd = &cobra.Command{
	Use:   "concordd",
	Short: "Discord IPC daemon for external clients",
	Long: `A long-running daemon that maintains a Discord connection and exposes
an IPC interface via Unix domain socket for external clients (e.g., Emacs).`,
}

var startCmd = &cobra.Command{
	Use:   "start",
	Short: "Start the daemon",
	Long:  `Start the Discord IPC daemon and listen for client connections.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		// Setup logging
		var level slog.Level
		switch logLevel {
		case "debug":
			level = slog.LevelDebug
		case "info":
			level = slog.LevelInfo
		case "warn":
			level = slog.LevelWarn
		case "error":
			level = slog.LevelError
		default:
			level = slog.LevelInfo
		}

		if err := logger.Load(logPath, level); err != nil {
			return fmt.Errorf("failed to load logger: %w", err)
		}

		slog.Info("Starting concordd",
			"socket", socketPath,
			"history_size", historySize,
			"log_level", logLevel,
		)

		// Get Discord token
		if token == "" {
			token = os.Getenv("DISCORDO_TOKEN")
		}

		if token == "" {
			var err error
			token, err = keyring.GetToken()
			if err != nil {
				return fmt.Errorf("failed to get token: %w", err)
			}
		}

		// Create handler and server
		handler := internal.NewHandler()
		server := internal.NewServer(socketPath, handler)

		// Start IPC server
		if err := server.Start(); err != nil {
			return fmt.Errorf("failed to start IPC server: %w", err)
		}
		defer server.Stop()

		// Create and connect Discord client
		discord, err := internal.NewDiscordClient(token, server, historySize)
		if err != nil {
			return fmt.Errorf("failed to create Discord client: %w", err)
		}
		defer discord.Close()

		// Set Discord client in handler (enables Discord methods)
		handler.SetDiscordClient(discord)

		// Connect to Discord
		if err := discord.Connect(); err != nil {
			return fmt.Errorf("failed to connect to Discord: %w", err)
		}

		slog.Info("Daemon running. Press Ctrl+C to stop.")

		// Wait for interrupt signal
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
		<-sigChan

		slog.Info("Shutting down...")
		return nil
	},
}

func init() {
	// Root command flags
	rootCmd.PersistentFlags().StringVar(&logPath, "log-path", logger.DefaultPath(), "path to log file")
	rootCmd.PersistentFlags().StringVar(&logLevel, "log-level", "info", "log level (debug|info|warn|error)")

	// Start command flags
	startCmd.Flags().StringVar(&socketPath, "socket-path", "/tmp/concordd.sock", "Unix socket path")
	startCmd.Flags().StringVar(&token, "token", "", "Discord token (default: $DISCORDO_TOKEN or keyring)")
	startCmd.Flags().IntVar(&historySize, "history-size", 100, "message cache size per channel")
	startCmd.Flags().StringVar(&configPath, "config", "", "config file path")

	rootCmd.AddCommand(startCmd)
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		slog.Error("failed to execute command", "err", err)
		os.Exit(1)
	}
}
