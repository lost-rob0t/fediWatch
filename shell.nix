{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    git
    nim
    openssl
    rabbitmq-c
    rabbitmq-server
  ];
}
