{
  description = "concordd - Discord IPC daemon for external clients";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages = {
          default = pkgs.buildGoModule {
            pname = "concordd";
            version = "1.0.0-${self.shortRev or "dirty"}";
            src = ./.;
            
            # This hash will need to be updated after first build
            # Run: nix build to get the correct hash
            vendorHash = "sha256-3JRjJqQDfyLOEh59ciJ5UsC/rSYNBDBwnko40PnjV2o=";

            ldflags = [
              "-s"
              "-w"
            ];

            meta = with pkgs.lib; {
              description = "Discord IPC daemon exposing JSON-RPC 2.0 interface over Unix sockets";
              longDescription = ''
                concordd is a standalone daemon that maintains a persistent Discord connection
                and exposes a JSON-RPC 2.0 interface over Unix domain sockets for external clients.
                
                Features:
                - 12 API methods for Discord operations (guilds, channels, messages, etc.)
                - 7 real-time event types for push notifications
                - Message caching for instant retrieval
                - Support for multiple concurrent clients
              '';
              homepage = "https://github.com/ayn2op/concordd";
              license = licenses.mit;
              maintainers = [ ];
              mainProgram = "concordd";
            };
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            go
            gopls
            gotools
            go-tools
          ];

          shellHook = ''
            echo "🚀 concordd development environment"
            echo "Go version: $(go version)"
            echo ""
            echo "Commands:"
            echo "  go build        - Build concordd"
            echo "  go run .        - Run concordd"
            echo "  nix build       - Build with Nix"
            echo "  nix run         - Run with Nix"
            echo ""
            echo "Usage:"
            echo "  concordd start              - Start the daemon"
            echo "  concordd start --help       - Show all options"
            echo ""
          '';
        };

        apps = {
          default = {
            type = "app";
            program = "${self.packages.${system}.default}/bin/concordd";
          };
        };
      }
    );
}
