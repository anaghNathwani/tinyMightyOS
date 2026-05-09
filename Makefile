# TinyMightyOS Makefile
# Top-level convenience wrapper around build scripts

SHELL := /bin/bash
ROOT  := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
BUILD := $(ROOT)/build
JOBS  := $(shell nproc)

.PHONY: all build kernel rootfs iso qemu clean distclean help

all: build

build:
	@$(ROOT)/scripts/build-all.sh -j$(JOBS)

kernel:
	@$(ROOT)/scripts/build-all.sh -j$(JOBS) --kernel-only

rootfs:
	@$(ROOT)/scripts/build-rootfs.sh -j$(JOBS)

iso:
	@$(ROOT)/scripts/build-iso.sh

qemu:
	@$(ROOT)/scripts/run-qemu.sh

qemu-kvm:
	@$(ROOT)/scripts/run-qemu.sh --kvm

qemu-uefi:
	@$(ROOT)/scripts/run-qemu.sh --kvm --uefi

clean:
	@echo "Cleaning build artifacts (keeping downloads)..."
	@rm -rf $(BUILD)/rootfs $(BUILD)/initramfs $(BUILD)/iso_root
	@rm -f  $(BUILD)/vmlinuz $(BUILD)/initrd.img $(BUILD)/rootfs.squashfs $(BUILD)/tinymightyos.iso
	@echo "Clean complete."

distclean:
	@echo "Removing entire build directory..."
	@rm -rf $(BUILD)
	@echo "Done."

help:
	@echo ""
	@echo "  TinyMightyOS Build System"
	@echo ""
	@echo "  Targets:"
	@echo "    make           — build everything (kernel + rootfs + ISO)"
	@echo "    make rootfs    — build rootfs only (no kernel)"
	@echo "    make iso       — build ISO from existing rootfs + kernel"
	@echo "    make qemu      — run in QEMU"
	@echo "    make qemu-kvm  — run in QEMU with KVM"
	@echo "    make qemu-uefi — run in QEMU with UEFI"
	@echo "    make clean     — remove build outputs"
	@echo "    make distclean — remove everything including downloads"
	@echo ""
	@echo "  Variables:"
	@echo "    JOBS=N         — parallel jobs (default: nproc)"
	@echo ""
