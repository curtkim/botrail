{
  # Development shell for botrail. The repo is a mixed Rust/Python project:
  # seventeen Rust crates behind a pyo3 extension (`botrail._core`), a pure
  # Python surface in `python/botrail`, and a Vite studio SPA in `studio`.
  #
  # The shell provides the *toolchain* only — rustc, uv, maturin, node, pnpm —
  # and leaves the Python environment to uv, exactly as CI does. That keeps
  # `maturin develop`'s incremental rebuild (the thing you want while
  # experimenting) instead of recompiling the workspace on every edit.
  description = "botrail: build robot cells as code, verify them, ship them as USD";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs {
        inherit system;
        overlays = [ rust-overlay.overlays.default ];
      }));
    in
    {
      devShells = forAllSystems (pkgs:
        let
          inherit (pkgs) lib stdenv;

          # CI pins Python 3.12 and node 22; pnpm 10 still writes studio's
          # lockfileVersion 9.0. The wasm32 target is for
          # `cargo build -p botrail-wasm` / scripts/build_wasm_demo.sh.
          python = pkgs.python312;
          rust = pkgs.rust-bin.stable.latest.default.override {
            extensions = [ "clippy" "rustfmt" "rust-src" "rust-analyzer" ];
            targets = [ "wasm32-unknown-unknown" ];
          };

          # pip wheels are not patchelf'd, so the loader has to be told where
          # libstdc++ lives. usd-core (Pixar's reader, which the appearance
          # tests use) is the one that really needs it; numpy wants libgcc.
          wheelLibs = lib.makeLibraryPath [ stdenv.cc.cc.lib pkgs.zlib ];

          setup = pkgs.writeShellScriptBin "botrail-setup" ''
            set -euo pipefail
            cd "''${BOTRAIL_ROOT:-$PWD}"
            [ -d .venv ] || uv venv --python "$(command -v python3)" .venv
            # Mirrors CI: pyyaml for catalog manifests, usd-core to re-read
            # exported USD with Pixar's own reader, jsonschema for saved
            # projects. --group dev brings numpy/gymnasium for botrail.rl.
            # huggingface_hub is the [catalog] extra: bt.parts.* orders from
            # the botrail-catalog dataset, so the examples need it.
            uv pip install --python .venv/bin/python --group dev \
              usd-core jsonschema 'huggingface_hub>=0.24'
            # --release is worth it for anything that plans or simulates:
            # rapier/parry/nalgebra are not in Cargo.toml's dev opt-level
            # overrides, so a debug build runs the numeric core unoptimized.
            VIRTUAL_ENV="$PWD/.venv" maturin develop --uv "$@"
            # bt.studio serves python/botrail/_studio, which is gitignored
            # and built from the SPA. Needed by any `--studio` example.
            [ -f python/botrail/_studio/index.html ] || ./scripts/build_studio.sh
            echo
            echo "ready — .venv/bin/python -m pytest python/tests -q"
          '';
        in
        {
          default = pkgs.mkShell {
            packages = [
              rust
              python
              pkgs.uv
              pkgs.maturin
              pkgs.nodejs_22
              pkgs.pnpm_10
              pkgs.wasm-pack # scripts/build_wasm_demo.sh
              pkgs.git
              setup
            ];

            env = {
              # uv's own CPython builds are FHS binaries and this host has no
              # nix-ld: make uv use the interpreter from this shell instead.
              UV_PYTHON_DOWNLOADS = "never";
              UV_PYTHON = "${python}/bin/python3.12";
              LD_LIBRARY_PATH = wheelLibs;

              # scripts/docs_screenshots.py drives the studio headlessly.
              # Pin the pip `playwright` to the driver's version if it
              # complains that an executable is missing:
              #   uv pip install --python .venv/bin/python \
              #     'playwright==${lib.versions.majorMinor pkgs.playwright-driver.version}.*'
              PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
              PLAYWRIGHT_NODEJS_PATH = "${pkgs.nodejs_22}/bin/node";
              PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
            };

            shellHook = ''
              export BOTRAIL_ROOT="$PWD"
              cat <<'EOF'
botrail dev shell — rustc, uv, maturin, node/pnpm on PATH.

  botrail-setup [--release]          .venv + deps + _core + studio bundle
  maturin develop --uv               rebuild the extension after a Rust edit
  .venv/bin/python -m pytest python/tests -q -x --durations=10
  .venv/bin/python examples/basics/demo.py --studio
  ./scripts/build_studio.sh          rebuild the SPA after a studio/ edit
  cargo test -p botrail-kin -p botrail-plan -p botrail-scene
  cargo clippy --workspace -- -D warnings && cargo fmt --all --check
EOF
            '';
          };
        });

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
