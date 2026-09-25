# slk (getslk.sh): cliente TUI de Slack, reemplaza al oficial de Electron
# (home.packages en ../common.nix). No está en nixpkgs (proyecto nuevo) -
# se empaqueta acá con buildGoModule, pineado a un tag por hash (igual que
# cualquier otro input externo, AGENTS.md §7).
{ lib, buildGoModule, fetchFromGitHub, pkg-config, libx11 }:

buildGoModule (finalAttrs: {
  pname = "slk";
  version = "0.22.0";

  src = fetchFromGitHub {
    owner = "gammons";
    repo = "slk";
    rev = "v${finalAttrs.version}";
    hash = "sha256-GHalz2565N4s83DSQHW6uxdSnsQz+QriXOYPWXdF0qY=";
  };

  vendorHash = "sha256-/J4gr4m9v6Y0Be8BU4wepIdl2sjoPh0pFCvJL2kIeLk=";

  # golang.design/x/clipboard usa cgo contra X11/Xlib.h para el portapapeles.
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ libx11 ];

  subPackages = [ "cmd/slk" ];

  meta = {
    description = "Cliente TUI de Slack (no oficial, sin Electron)";
    homepage = "https://getslk.sh/";
    license = lib.licenses.mit;
    mainProgram = "slk";
  };
})
