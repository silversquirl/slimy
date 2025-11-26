{
  inputs = {
    nixpkgs.url = "nixpkgs";
    zig.url = "github:silversquirl/zig-flake";
    zig.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    nixpkgs,
    zig,
    ...
  }: let
    forAllSystems = f:
      builtins.mapAttrs
      (system: pkgs: f pkgs zig.packages.${system}.zig_0_15_2)
      nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (pkgs: zig: {
      default = pkgs.mkShellNoCC {
        packages = [
          pkgs.bash
          zig.zls
          zig
          pkgs.shaderc
        ];
      };
    });
  };
}
