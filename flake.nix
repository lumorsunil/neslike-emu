{
  description = "A Simple Zig Project";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs: {
    devShells = builtins.mapAttrs (system: pkgs: {
      default = pkgs.mkShell {
        packages = [ pkgs.zig pkgs.zls ];
      };
    }) inputs.nixpkgs.legacyPackages;
  };
}
