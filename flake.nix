{
  description = "mine-api development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.mojang-transport.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs, mojang-transport }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      zig = pkgs.zig_0_13;
      zigLibc = pkgs.writeText "zig-base-libc.conf" ''
        include_dir=${pkgs.glibc.dev}/include
        sys_include_dir=${pkgs.glibc.dev}/include
        crt_dir=${pkgs.glibc}/lib
        msvc_lib_dir=
        kernel32_lib_dir=
        gcc_dir=
      '';
      transportSources = import mojang-transport { inherit system; };
      curlSource = transportSources.curlMinimal;
      aresSource = transportSources.c-aresMinimal;
      mojangAres = pkgs.c-aresMinimal.overrideAttrs (_: {
        version = aresSource.version;
        src = aresSource.src;
        patches = [];
      });
      mojangTls = pkgs.openssl;
      mojangCa = pkgs.cacert;
      mojangCurl = (pkgs.curlMinimal.override {
        c-aresSupport = true;
        c-aresMinimal = mojangAres;
        opensslSupport = true;
        openssl = mojangTls;
        gssSupport = false;
        scpSupport = false;
        http2Support = false;
        http3Support = false;
        zlibSupport = true;
        zlib = pkgs.zlib;
        brotliSupport = false;
        zstdSupport = false;
        idnSupport = false;
        ldapSupport = false;
        pslSupport = false;
        gnutlsSupport = false;
        rustlsSupport = false;
        gsaslSupport = false;
        rtmpSupport = false;
      }).overrideAttrs (old: {
        version = curlSource.version;
        src = curlSource.src;
        patches = [];

        configureFlags = (builtins.filter (flag:
          flag != "--with-ca-fallback" && flag != "--without-librtmp"
        ) old.configureFlags) ++ [
          "--disable-threaded-resolver" "--disable-httpsrr"
          "--without-ca-fallback" "--without-ca-bundle" "--without-ca-path"
        ];
      });
      transportPrefixes = [
        (pkgs.lib.getDev mojangCurl) (pkgs.lib.getLib mojangCurl)
        (pkgs.lib.getDev mojangAres) (pkgs.lib.getLib mojangAres)
        (pkgs.lib.getDev mojangTls) (pkgs.lib.getLib mojangTls)
        (pkgs.lib.getDev pkgs.zlib) (pkgs.lib.getLib pkgs.zlib)
      ];
      identity = x: {
        version = x.version or null;
        drvPath = x.drvPath;
        outputPath = toString x;
        outputs = builtins.listToAttrs (map (name: {
          inherit name;
          value = toString x.${name};
        }) (x.outputs or []));
        source = if x ? src then {
          path = toString x.src;
          hash = x.src.outputHash or null;
        } else null;
      };
      transportIdentity = x: (identity x) // {
        srcHash = x.src.outputHash;
        stdenvDrv = x.stdenv.drvPath;
        libcPath = toString x.stdenv.cc.libc;
        buildInputs = map toString (x.buildInputs or []);
        propagatedBuildInputs = map toString (x.propagatedBuildInputs or []);
        nativeBuildInputs = map toString (x.nativeBuildInputs or []);
        configureFlags = x.configureFlags or [];
      };
      declaredInputs = {
        curl = {
          buildInputs = [ (toString (pkgs.lib.getDev pkgs.runtimeShellPackage)) ];
          propagatedBuildInputs = map (x: toString (pkgs.lib.getDev x))
            [ mojangAres pkgs.openssl pkgs.zlib ];
        };
        ares = { buildInputs = []; propagatedBuildInputs = []; };
      };
      runtimeInventory =
        assert pkgs.lib.assertMsg (mojangCurl.stdenv.drvPath == pkgs.stdenv.drvPath)
          "private curl must use base stdenv";
        assert pkgs.lib.assertMsg (mojangAres.stdenv.drvPath == pkgs.stdenv.drvPath)
          "private c-ares must use base stdenv";
        assert pkgs.lib.assertMsg (toString mojangTls == toString pkgs.openssl)
          "private curl must use base OpenSSL";
        assert pkgs.lib.assertMsg (builtins.all (x:
          toString x.stdenv.cc.libc == toString pkgs.glibc
        ) [ mojangCurl mojangAres ]) "private transport must use base libc";
        assert pkgs.lib.assertMsg (builtins.all (name:
          let actual = transportIdentity (if name == "curl" then mojangCurl else mojangAres);
          in actual.buildInputs == declaredInputs.${name}.buildInputs
            && actual.propagatedBuildInputs == declaredInputs.${name}.propagatedBuildInputs
        ) [ "curl" "ares" ]) "private transport declared runtime inputs must be base-only";
        {
          schemaVersion = 1;
          inherit declaredInputs;
          sources = {
            base = { inherit (nixpkgs) rev narHash; path = toString nixpkgs; };
            transport = { inherit (mojang-transport) rev narHash; path = toString mojang-transport; };
          };
          base = builtins.mapAttrs (_: identity) {
            inherit (pkgs) stdenv stdenvNoCC glibc openssl zlib postgresql krb5 keyutils cacert;
            compiler = pkgs.stdenv.cc;
            compilerUnwrapped = pkgs.stdenv.cc.cc;
            binutils = pkgs.binutils;
            inherit zig;
          };
          transport = {
            curl = (transportIdentity mojangCurl) // {
              opensslPath = toString mojangCurl.openssl;
              zlibPath = toString pkgs.zlib;
            };
            ares = transportIdentity mojangAres;
          };
          expectedInterpreter = pkgs.stdenv.cc.bintools.dynamicLinker;
          tools.readelf = "${pkgs.binutils}/bin/readelf";
          tools.strace = "${pkgs.strace}/bin/strace";
          artifacts = map (x: "${pkgs.lib.getLib x}/lib") [ mojangCurl mojangAres ];
          packages = {
            default = "${apiPackage}/bin/mine-api";
            capability = "${transportTests}/bin/mojang-transport-capability-tests";
            transport = "${transportTests}/bin/mojang-transport-tests";
          };
          metadata = {
            ca_bundle = "${mojangCa}/etc/ssl/certs/ca-bundle.crt";
            curl_version = mojangCurl.version;
            ares_version = mojangAres.version;
            openssl_version = mojangTls.version;
          };
        };
      applicationSource = withTests: pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions ([
          ./build.zig ./build.zig.zon ./src ./db/migrations
          ./assets/password-deny-list.txt
        ] ++ pkgs.lib.optionals withTests [ ./test/mojang_transport_test.zig ./test/support/mojang_transport.zig ]);
      };
      apiPackage = pkgs.stdenvNoCC.mkDerivation {
        pname = "mine-api";
        version = "0.1.0";
        src = applicationSource false;
        nativeBuildInputs = [ zig pkgs.postgresql pkgs.postgresql.lib pkgs.pkg-config ];
        buildInputs = [ mojangCurl mojangAres mojangTls pkgs.zlib mojangCa ];
        MOJANG_CA_BUNDLE = "${mojangCa}/etc/ssl/certs/ca-bundle.crt";
        MOJANG_CURL_VERSION = mojangCurl.version;
        MOJANG_ARES_VERSION = mojangAres.version;
        MOJANG_OPENSSL_VERSION = mojangTls.version;
        TASK12_ZIG_PREFIXES = pkgs.lib.concatStringsSep ":" (
          [ "${pkgs.postgresql.lib}" "${pkgs.postgresql}" "${pkgs.postgresql.dev}" ]
          ++ map toString transportPrefixes
        );
        buildPhase = ''
          zig build --libc ${zigLibc} --search-prefix ${pkgs.postgresql.lib} --search-prefix ${pkgs.postgresql} --search-prefix ${pkgs.postgresql.dev} --cache-dir "$TMPDIR/zig-cache" --global-cache-dir "$TMPDIR/zig-global-cache" --prefix "$out" -Doptimize=ReleaseSafe ${pkgs.lib.concatMapStringsSep " " (p: "--search-prefix ${p}") transportPrefixes}
        '';
        installPhase = ":";
      };
      transportTests = apiPackage.overrideAttrs (old: {
        pname = "mojang-transport-tests";
        src = applicationSource true;
        buildPhase = builtins.replaceStrings [ "zig build " ]
          [ "zig build install-mojang-transport-tests " ] old.buildPhase;
      });
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
      lib.mojangRuntimeInventory.${system} = runtimeInventory;
      checks.${system}.mojang-base-family = pkgs.runCommand "mojang-base-family" {
        outputs = [ "out" "evidence" ];
        nativeBuildInputs = [ pkgs.python3 ];
        transportArtifacts = (map pkgs.lib.getLib [ mojangCurl mojangAres ]) ++ [ apiPackage transportTests mojangCa ];
        runtimeProviders = [ pkgs.glibc (pkgs.lib.getLib pkgs.openssl)
          (pkgs.lib.getLib pkgs.zlib) pkgs.postgresql.lib
          (pkgs.lib.getLib pkgs.krb5) (pkgs.lib.getLib pkgs.keyutils) pkgs.binutils pkgs.strace ];
        inventory = pkgs.writeText "mojang-runtime-inventory.json"
          (builtins.unsafeDiscardStringContext (builtins.toJSON runtimeInventory));
      } ''
        cp ${./test/mojang_base_family_check.py} mojang_base_family_check.py
        cp ${./test/mojang_base_family_check_test.py} mojang_base_family_check_test.py
        cp ${./test/mojang_capability_check.py} mojang_capability_check.py
        cp ${./test/mojang_capability_check_test.py} mojang_capability_check_test.py
        export PYTHONDONTWRITEBYTECODE=1
        export MOJANG_INVENTORY="$inventory"
        python mojang_base_family_check_test.py -v
        python mojang_capability_check_test.py -v
        python mojang_base_family_check.py --inventory-stdin --require-realized < "$inventory" > "$out"
        mkdir "$evidence"
        cp "$inventory" "$evidence/inventory.json"
        python mojang_capability_check.py --inventory "$inventory" --graph "$out" --output "$evidence/capability"
      '';
      packages.${system} = {
        mojang-curl = mojangCurl;
        mojang-ares = mojangAres;
        default = apiPackage;
        mojang-transport-tests = transportTests;
      };

      devShells.${system}.default = pkgs.mkShell {
        ZIG_LIBC = zigLibc;
        packages = [
          zig
          zine
          pkgs.nodejs
          pkgs.postgresql
          pkgs.pkg-config
          pkgs.openssl
          mojangCurl
          mojangAres
          mojangTls
          pkgs.zlib
          mojangCa
        ] ++ transportPrefixes;
        MOJANG_CA_BUNDLE = "${mojangCa}/etc/ssl/certs/ca-bundle.crt";
        MOJANG_CURL_VERSION = mojangCurl.version;
        MOJANG_ARES_VERSION = mojangAres.version;
        MOJANG_OPENSSL_VERSION = mojangTls.version;
        TASK12_ZIG_PREFIXES = pkgs.lib.concatStringsSep ":" (
          [ "${pkgs.postgresql.lib}" "${pkgs.postgresql}" "${pkgs.postgresql.dev}" ]
          ++ map toString transportPrefixes
        );
      };
    };
}
