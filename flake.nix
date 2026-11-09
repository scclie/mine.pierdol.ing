{
  description = "mine-api development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      zig = pkgs.zig_0_13;
      zine = pkgs.stdenvNoCC.mkDerivation {
        pname = "zine";
        version = "0.13.0";
        src = pkgs.fetchurl {
          url = "https://github.com/kristoff-it/zine/releases/download/v0.13.0/x86_64-linux-musl.tar.xz";
          hash = "sha256-wlDgKdl4kBsMmjjqsKhg7524db9ob+Dwq/YfGAwoDbo=";
        };
        unpackPhase = "tar --extract --file=$src --xz";
        installPhase = "install -Dm755 zine $out/bin/zine";
      };
    in
    {
      packages.${system}.default = pkgs.stdenvNoCC.mkDerivation {
        pname = "mine-api";
        version = "0.1.0";
        src = ./.;
        nativeBuildInputs = [ zig pkgs.postgresql pkgs.postgresql.lib ];
        buildPhase = ''
          zig build --search-prefix ${pkgs.postgresql.lib} --search-prefix ${pkgs.postgresql} --search-prefix ${pkgs.postgresql.dev} --cache-dir "$TMPDIR/zig-cache" --global-cache-dir "$TMPDIR/zig-global-cache" --prefix "$out" -Doptimize=ReleaseSafe
        '';
        installPhase = ":";
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zig
          zine
          pkgs.nodejs
          pkgs.postgresql
          pkgs.pkg-config
          pkgs.openssl
        ];
      };
    };
}
