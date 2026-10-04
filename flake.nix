{
  description = "FediWatch consuming the generated StarLang wire contract";
  inputs = {
    star-router.url = "github:lost-rob0t/starRouter/20e5c9e8bf49660fd230d8e7306dd9209648f6e9";
    nixpkgs.follows = "star-router/nixpkgs";
    starintel-doc.follows = "star-router/starintel-doc";
    fedi = { url = "github:lost-rob0t/fedi/d6a3d7f7674e35677f5a529f9b0e8e332b198602"; flake = false; };
    lrucache = { url = "github:jackhftang/lrucache/1c2eede7e2fbe05b0498537a6f82be8063e093d6"; flake = false; };
  };
  outputs = { self, nixpkgs, star-router, starintel-doc, fedi, lrucache }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python3.withPackages (p: [p.pyzmq]);
      paths = "--noNimblePath --path:src --path:${starintel-doc}/src --path:${star-router}/src --path:${fedi}/src --path:${lrucache}/src --path:${star-router.inputs.cligen} --path:${star-router.inputs.zmq} --path:$TMPDIR/ulid-deps";
      libraries = pkgs.lib.makeLibraryPath [ pkgs.pcre pkgs.zeromq pkgs.openssl ];
      actor = pkgs.stdenv.mkDerivation {
        pname = "fediWatch";
        version = "0.3.0";
        src = self;
        nativeBuildInputs = [ pkgs.nim python pkgs.makeWrapper ];
        buildInputs = [ pkgs.openssl ];
        buildPhase = ''
          # Nim 2.2.12 otherwise gives pkg/random and std/random the same C name.
          # Rename only the pinned ULID RNG module; its implementation is unchanged.
          mkdir -p "$TMPDIR/ulid-deps"
          cp -r ${star-router.inputs.ulid}/src/. "$TMPDIR/ulid-deps/"
          cp -r ${star-router.inputs.random}/src/. "$TMPDIR/ulid-deps/"
          mv "$TMPDIR/ulid-deps/random.nim" "$TMPDIR/ulid-deps/ulid_random.nim"
          chmod u+w "$TMPDIR/ulid-deps/ulid.nim"
          substituteInPlace "$TMPDIR/ulid-deps/ulid.nim" --replace-fail 'import pkg/random' 'import ulid_random'
          nim c -d:release -d:ssl ${paths} --nimcache:"$TMPDIR/nimcache" --out:fediWatch src/fediWatch.nim
        '';
        doCheck = true;
        doInstallCheck = true;
        checkPhase = ''
          python scripts/sync-starintel-schema.py --offline
          python scripts/check-runtime-release.py ${starintel-doc} ${star-router}
          export LD_LIBRARY_PATH=${libraries}
          python tests/actor_wire.py "$PWD/fediWatch" ${star-router.packages.${system}.default}/bin/starRouter
        '';
        installPhase = ''
          mkdir -p "$out/bin"
          install -m755 fediWatch "$out/bin/fediWatch"
          wrapProgram "$out/bin/fediWatch" --prefix LD_LIBRARY_PATH : ${libraries} \
            --set-default SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        '';
        installCheckPhase = ''
          python tests/actor_wire.py "$out/bin/fediWatch" ${star-router.packages.${system}.default}/bin/starRouter
        '';
      };
    in {
      packages.${system}.default = actor;
      checks.${system}.default = actor;
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.nim pkgs.nimble python ];
        LD_LIBRARY_PATH = libraries;
      };
    };
}
