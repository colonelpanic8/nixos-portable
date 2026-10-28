default:
    @just --list

fmt:
    alejandra flake.nix modules
    ruff format scripts tests calamares

fmt-check:
    alejandra --check flake.nix modules
    ruff format --check scripts tests calamares

lint:
    ruff check scripts tests calamares

test:
    PYTHONPATH=scripts python -m unittest discover -s tests -v

check: fmt-check lint test
    nix flake check --no-build

build:
    nix build .#usb-image

prepare *args:
    python scripts/prepare_media.py {{args}}

# Boot a disposable copy of the built image under UEFI, with a blank disk to install onto.
vm:
    #!/usr/bin/env bash
    set -euo pipefail
    image=$(find -L result -maxdepth 1 -name '*.raw.xz' -print -quit)
    test -n "$image"
    work=$(mktemp -d)
    xz -dc "$image" | cp --sparse=always /dev/stdin "$work/stick.raw"
    truncate -s 32G "$work/stick.raw"
    qemu-img create -f qcow2 "$work/target.qcow2" 40G
    cp "${OVMF:?run inside nix develop}/FV/OVMF_VARS.fd" "$work/vars.fd"
    chmod u+w "$work/vars.fd"
    code=$OVMF/FV/OVMF_CODE.fd
    acceleration=tcg
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then acceleration=kvm; fi
    echo "VM files: $work"
    qemu-system-x86_64 -accel "$acceleration" -m 6144 -smp 4 -vga virtio \
      -drive "if=pflash,format=raw,readonly=on,file=$code" \
      -drive "if=pflash,format=raw,file=$work/vars.fd" \
      -drive "file=$work/stick.raw,format=raw,if=none,id=stick" \
      -device qemu-xhci -device usb-storage,drive=stick,bootindex=0 \
      -drive "file=$work/target.qcow2,format=qcow2,if=virtio" \
      -nic user,model=virtio-net-pci
