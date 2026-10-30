{
  description = "A workflow on top of tmux to manage coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # scripts/lint.sh checks that this revision is the third_party/tmux gitlink
    tmux-fork = {
      url = "github:andreypopp/tmux/a020eaf3c42e24bf9e383a080219bd1caa65517e";
      flake = false;
    };
    mosaic = {
      url = "github:invariant-hq/mosaic/0ef02a5690365f8f7518c54755287f905814529f";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      tmux-fork,
      mosaic,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      packagesFor =
        pkgs:
        let
          ocamlPackages = pkgs.ocaml-ng.ocamlPackages_5_5.overrideScope (
            _: prev: {
              containers = prev.containers.overrideAttrs {
                version = "3.18";
                patches = [ ];
                src = pkgs.fetchFromGitHub {
                  owner = "c-cube";
                  repo = "ocaml-containers";
                  tag = "v3.18";
                  hash = "sha256-1h5Q0PPccd/3wMfV21OdMtcM6LNqEvQHMjEKLBlZsAA=";
                };
              };
            }
          );

          src = pkgs.runCommand "kido-src" { } ''
            cp -r ${self} $out
            chmod -R u+w $out
            rm -rf $out/third_party/tmux
            mkdir -p $out/third_party
            cp -r ${tmux-fork} $out/third_party/tmux
          '';

          buildKey = pkgs.runCommand "kido-fork-build-key" { nativeBuildInputs = [ pkgs.git ]; } ''
            printf '%s-%s' ${tmux-fork.rev} "$(git hash-object ${src}/scripts/install-tmux-fork.sh)" > $out
          '';

          kido-tmux = pkgs.stdenv.mkDerivation {
            pname = "kido-tmux";
            version = builtins.substring 0 7 tmux-fork.rev;
            inherit src;
            nativeBuildInputs = with pkgs; [
              autoconf
              automake
              bison
              pkg-config
            ];
            buildInputs = with pkgs; [
              libevent
              ncurses
              utf8proc
              libpng
              zlib
            ];
            dontConfigure = true;
            buildPhase = ''
              TMUX_BUILD_KEY=$(cat ${buildKey}) bash scripts/install-tmux-fork.sh $out
            '';
            dontInstall = true;
            meta.mainProgram = "kido-tmux";
          };

          mosaicPackages = ocamlPackages.buildDunePackage {
            pname = "mosaic";
            version = "0-unstable-${builtins.substring 0 7 mosaic.rev}";
            src = mosaic;
            propagatedBuildInputs = [ ocamlPackages.cmarkit ];
            buildPhase = ''
              runHook preBuild
              dune build -p matrix,toffee,tree-sitter,mosaic ''${enableParallelBuilding:+-j $NIX_BUILD_CORES}
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              dune install --prefix $out --libdir $OCAMLFIND_DESTDIR matrix toffee tree-sitter mosaic \
                --docdir $out/share/doc --mandir $out/share/man
              runHook postInstall
            '';
            meta.license = pkgs.lib.licenses.isc;
          };

          kido = ocamlPackages.buildDunePackage {
            pname = "kido";
            version = self.shortRev or self.dirtyShortRev or "unknown";
            inherit src;
            nativeBuildInputs = [ pkgs.git ];
            buildInputs = with ocamlPackages; [
              containers
              cmdliner
              yojson
              ppx_yojson_conv
              ppx_compare
              ppx_string_conv
              ppx_expect
              dune-build-info
              mosaicPackages
            ];
            # dune-workspace turns on dune package management, which fetches
            # dune.lock; the build key and version need git metadata that the
            # sandbox does not have
            postPatch = ''
              rm dune-workspace
              substituteInPlace lib/dune --replace-fail \
                '(run bash %{project_root}/scripts/install-tmux-fork.sh --print-build-key)' \
                '(echo "'"$(cat ${buildKey})"'")'
              sed -i 's/^(name kido)$/&\n(version ${self.shortRev or self.dirtyShortRev or "unknown"})/' dune-project
            '';
            postInstall = ''
              ln -s ${pkgs.lib.getExe kido-tmux} $out/bin/kido-tmux
            '';
            meta.mainProgram = "kido";
          };
        in
        {
          inherit kido kido-tmux;
          default = kido;
        };
    in
    {
      packages = forAllSystems packagesFor;
    };
}
