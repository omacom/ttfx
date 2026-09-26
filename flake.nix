{
  description = "ttfx — Terminal text effects (Rust port of TTE)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
    forAllSystems = nixpkgs.lib.genAttrs systems;
    nixpkgsFor = forAllSystems (system: import nixpkgs {inherit system;});
  in {
    formatter = forAllSystems (
      system:
        nixpkgsFor.${system}.alejandra
    );
    packages = forAllSystems (
      system: let
        pkgs = nixpkgsFor.${system};
        version = (fromTOML (builtins.readFile ./Cargo.toml)).package.version;
        common = {
          pname = "ttfx";
          inherit version;
          src = ./.;
          cargoLock = {
            lockFile = ./Cargo.lock;
          };
          nativeBuildInputs = [pkgs.installShellFiles];
          postInstall = ''
            installShellCompletion --cmd ttfx \
              --bash <($out/bin/ttfx --print-completion bash) \
              --zsh <($out/bin/ttfx --print-completion zsh)
          '';
          meta = with pkgs.lib; {
            description = "Terminal text effects — a Rust port of terminaltexteffects (TTE)";
            homepage = "https://github.com/omacom-io/ttfx";
            license = licenses.mit;
            mainProgram = "ttfx";
          };
        };
        ttfx = pkgs.rustPlatform.buildRustPackage common;
      in {
        default = ttfx;
        ttfx = ttfx;
      }
    );

    devShells = forAllSystems (
      system: let
        pkgs = nixpkgsFor.${system};
      in {
        default = pkgs.mkShell {
          inputsFrom = [self.packages.${system}.default];
          packages = with pkgs; [
            cargo
            rustc
            clippy
            rustfmt
            rust-analyzer
            python3
            git
            alejandra
          ];
          env = {
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          };
        };
      }
    );

    apps = forAllSystems (system: {
      default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/ttfx";
      };
    });
  };
}
