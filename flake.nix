{
  description = "A Nix-flake-based development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zon2nix = {
      url = "github:jcollie/zon2nix?rev=c28e93f3ba133d4c1b1d65224e2eebede61fd071";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig, zon2nix }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSupportedSystem = f: lib.genAttrs supportedSystems (system: f rec {
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
        zigPkg = zig.packages.${system}."0.15.2";
        zon2nixPkg = zon2nix.packages.${system}.zon2nix;
      });
    in
    {
      packages = forEachSupportedSystem ({ pkgs, zigPkg, ... }: {
        deps = pkgs.callPackage ./build.zig.zon.nix {
          zig_0_15 = zigPkg;
        };
        default = pkgs.rustPlatform.buildRustPackage {
          pname = "trolley";
          version = (lib.importTOML ./cli/Cargo.toml).package.version;
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./VERSION
              ./cli
              ./config
            ];
          };
          cargoLock.lockFile = ./Cargo.lock;
          cargoBuildFlags = ["-p" "trolley"];
          env.TROLLEY_RUNTIME_SOURCE = "https://github.com/weedonandscott/trolley/releases/download/v{version}/trolley-runtime-{target}.tar.xz";
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.xz ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
            ];
        };
      });

      devShells = forEachSupportedSystem ({ pkgs, zigPkg, zon2nixPkg, ... }: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            claude-code

            # trolley build toolchain
            zigPkg
            pkg-config

            # Rust (trolley CLI)
            cargo
            rustc
            rustfmt
            clippy
            rust-analyzer

            # Task runner
            just

            # CI
            act
            zon2nixPkg
          ]
          ++ lib.optionals stdenv.hostPlatform.isLinux [
            # libghostty native deps
            bzip2
            expat
            fontconfig
            freetype
            harfbuzz
            libGL
            libpng
            libxml2
            oniguruma
            simdutf
            zlib
            glslang
            spirv-cross

            # X11 / windowing (for GLFW wrapper)
            glfw
            libxkbcommon
            libx11
            libxcursor
            libxext
            libxi
            libxinerama
            libxrandr
          ];

          shellHook = lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
            # Ghostty's build.zig eagerly builds for iOS even when we only need
            # macOS. Nix only ships a macOS SDK, so we unset Nix's SDK env vars
            # and let Zig discover the system Xcode which has all Apple SDKs.
            unset SDKROOT
            unset DEVELOPER_DIR
            export PATH=$(echo "$PATH" | awk -v RS=: -v ORS=: '$0 !~ /xcrun/ || $0 == "/usr/bin" {print}' | sed 's/:$//')
          '';
        };
      });
    };

  nixConfig = {
    extra-substituters = ["https://trolley.cachix.org"];
    extra-trusted-public-keys = ["trolley.cachix.org-1:j4ckLzEzdt+r2MOinJiaT/uWS+febWBnho9wqejHQUQ="];
  };
}
