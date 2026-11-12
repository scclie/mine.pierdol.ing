# evaluate only with cached pinned inputs and a sanitized module
# no host imports, deployment, decryption or full-system validation
{ nixpkgs, sopsModule, serverModules, secretFile }:
let
  lib = import (nixpkgs + "/lib");
  evaluate = enabled: (import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      sopsModule
      (serverModules + "/base.nix")
      (serverModules + "/sites.nix")
      (serverModules + "/proxy.nix")
      (serverModules + "/mine-platform.nix")
      ({ pkgs, ... }: {
        system.stateVersion = "26.05";
        sccl.proxy.enable = true;
        sccl.sites = {
          enable = true;
          sites.unrelated.domain = "cache-control.invalid";
        };
        sccl.minePlatform = {
          enable = enabled;
          package = pkgs.hello; # evaluation-only placeholder
          sitePath = "/tank/sites/mine/public";
          adminDiscordIds = [ "123456789012345678" ];
        };
        services.postgresql = { enable = true; enableTCPIP = true; settings.port = 5432; };
        sops.age.keyFile = "/no-decryption-in-evaluation";
        sops.secrets = lib.genAttrs ([ "cloudflare/api-token" ] ++ lib.optionals enabled
          (map (n: "mine-platform/${n}") [ "db-password" "discord-client-id" "discord-client-secret" "session-signing-key" ]))
          (_: { sopsFile = lib.mkForce secretFile; });
      })
    ];
  }).config;
  c = evaluate true;
  disabled = evaluate false;
  mine = c.services.nginx.virtualHosts.mine;
  assetKey = v: let keys = lib.filter (n: lib.hasPrefix "~*" n) (builtins.attrNames v.locations);
    in assert builtins.length keys == 1; builtins.head keys;
  mineAssets = mine.locations.${assetKey mine};
  other = c.services.nginx.virtualHosts.unrelated;
  otherPolicy = other.locations.${assetKey other}.extraConfig;
in
assert builtins.match "[[:space:]]*add_header Cache-Control \"no-cache\";[[:space:]]*" mineAssets.extraConfig != null;
assert c.sccl.sites.sites.mine.assetCacheControl == "no-cache";
assert mineAssets.tryFiles == "$uri =404";
assert mine.root == "/tank/sites/mine/public";
assert mine.serverName == "mine.pierdol.ing";
assert mine.locations."^~ /api".proxyPass == "http://127.0.0.1:8088";
assert mine.useACMEHost == "wildcard.sccl.cc";
assert c.sccl.sites.sites.unrelated.assetCacheControl == "public, max-age=31536000, immutable";
assert lib.hasInfix "public, max-age=31536000, immutable" otherPolicy;
assert !(disabled.services.nginx.virtualHosts ? mine);
assert !(disabled.systemd.services ? mine-platform);
assert !(disabled.sops.templates ? mine-platform-env);
assert !(disabled.sops.secrets ? "mine-platform/db-password");
{
  status = "PASS (scoped module evaluation only)";
  inherit (mineAssets) extraConfig tryFiles;
  assetLocation = assetKey mine;
  unrelatedPolicy = otherPolicy;
  disabledHasMineVhost = disabled.services.nginx.virtualHosts ? mine;
}
