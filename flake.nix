{
  description = "A Simple Zig Project";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs = inputs: {
    devShells = builtins.mapAttrs (system: pkgs: {
      default = pkgs.mkShell {
        packages = [ pkgs.zig_0_16 pkgs.zls_0_16 ];
      };
    }) inputs.nixpkgs.legacyPackages;
  };
}
