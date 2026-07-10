{
  description = "hvisor + Asterinas 开发环境";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-hvisor.url = "github:NixOS/nixpkgs/nixos-24.05";

    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    rust-overlay-hvisor.url = "github:oxalica/rust-overlay/f3b20ea4131408ea585bddb1f41f91c4de9499cf";
    rust-overlay-hvisor.inputs.nixpkgs.follows = "nixpkgs-hvisor";
  };

  outputs = { nixpkgs, nixpkgs-hvisor, rust-overlay, rust-overlay-hvisor, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f:
        builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        }) systems);

      mkPkgs = nixpkgsInput: overlay: system:
        import nixpkgsInput {
          inherit system;
          overlays = [ overlay.overlays.default ];
          config.allowUnfree = true;
        };
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = mkPkgs nixpkgs rust-overlay system;
          hvisorPkgs = mkPkgs nixpkgs-hvisor rust-overlay-hvisor system;

          hvisorToolchain =
            hvisorPkgs.rust-bin.fromRustupToolchainFile ./toolchains/hvisor/rust-toolchain.toml;
          asterinasToolchain =
            pkgs.rust-bin.fromRustupToolchainFile ./toolchains/asterinas/rust-toolchain.toml;

          commonPackages = with pkgs; [
            bc
            binutils
            bison
            cargo-binutils
            clang
            cpio
            curl
            dosfstools
            e2fsprogs
            e2tools
            elfutils
            exfatprogs
            expect
            file
            flex
            gawk
            git
            gnumake
            gnutar
            grub2
            grub2_efi
            jq
            kmod
            libxml2
            lld
            llvm
            mtools
            nasm
            numactl
            openssl
            OVMF
            parted
            patchelf
            perl
            pixman
            pkg-config
            podman
            python3
            qemu
            qemu_kvm
            ripgrep
            screen
            socat
            sqlite
            strace
            dtc
            pkgs.pkgsStatic.stdenv.cc
            ubootTools
            unzip
            wget
            xorriso
            zip
          ];

          mkShell = name: rustToolchain: extraPackages:
            pkgs.mkShell {
              packages = commonPackages ++ [ pkgs.gcc rustToolchain ] ++ extraPackages;

              shellHook = ''
                export VDSO_LIBRARY_DIR="$PWD/.cache/linux_vdso"
                export OVMF_FD="${pkgs.OVMF.fd}/FV/OVMF.fd"
                export GRUB_X86_64_EFI="${pkgs.grub2_efi}/lib/grub/x86_64-efi"
                unset OBJCOPY

                echo "已进入 ${name} 开发环境"
                echo "rustc: $(rustc --version)"
                echo "VDSO_LIBRARY_DIR=''${VDSO_LIBRARY_DIR}"
              '';
            };

          driverShell = pkgs.mkShell {
            packages = commonPackages ++ [ pkgs.gcc13 ];

            shellHook = ''
              export VDSO_LIBRARY_DIR="$PWD/.cache/linux_vdso"
              export OVMF_FD="${pkgs.OVMF.fd}/FV/OVMF.fd"
              export GRUB_X86_64_EFI="${pkgs.grub2_efi}/lib/grub/x86_64-efi"
              unset OBJCOPY
              unset LD_LIBRARY_PATH

              echo "已进入 hvisor-tool driver 开发环境"
              echo "gcc: $(gcc --version | head -n 1)"
              echo "VDSO_LIBRARY_DIR=''${VDSO_LIBRARY_DIR}"
            '';
          };
        in
        {
          default = mkShell "hvisor + Asterinas 基础" pkgs.rust-bin.stable.latest.default [ ];
          hvisor = mkShell "hvisor" hvisorToolchain [ ];
          asterinas = mkShell "Asterinas" asterinasToolchain [ ];
          driver = driverShell;
        });
    };
}
