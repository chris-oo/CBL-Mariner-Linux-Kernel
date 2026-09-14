#!/usr/bin/env bash
# Build an x86_64 SEV-SNP guest kernel for direct boot with MSHV.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT="${SNP_GUEST_OUT:-$ROOT/.snp-guest-build}"
JOBS="${SNP_GUEST_JOBS:-$(nproc)}"
LOCALVERSION="${SNP_GUEST_LOCALVERSION:--snp-guest}"
ACTION="${1:-build}"

usage() {
    cat <<'EOF'
Usage: build-snp-guest.sh [build|configure|menuconfig|--help]

  build       Configure and build arch/x86/boot/bzImage (default).
  configure   Set and check the required SNP guest options.
  menuconfig  Configure, then open the kernel configuration editor.

Environment:
  SNP_GUEST_OUT           Build directory (default: .snp-guest-build beside
                          this script). Relative paths use the caller's directory.
  SNP_GUEST_JOBS          Parallel build jobs (default: nproc).
  SNP_GUEST_LOCALVERSION  Kernel release suffix (default: -snp-guest).

New builds start from x86_64_defconfig, not the MSHV root-partition config.
Existing configurations are reused, with required guest options reapplied.
This builds the kernel image only; it does not build or install modules,
create an initramfs, or install the kernel. Supply a compatible guest
initramfs and root filesystem separately.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

if (( $# > 1 )); then
    usage >&2
    exit 2
fi

case "$ACTION" in
    --help|-h)
        usage
        exit 0
        ;;
    build|configure|menuconfig)
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "SNP_GUEST_JOBS must be a positive integer"
OUT="$(realpath -m -- "$OUT")"
[[ "$OUT" != "$ROOT" ]] || fail "SNP_GUEST_OUT must be outside the source directory root"

make_kernel() {
    make -C "$ROOT" O="$OUT" ARCH=x86_64 LOCALVERSION="$LOCALVERSION" "$@"
}

require_config() {
    grep -qx "CONFIG_$1=y" "$OUT/.config" ||
        fail "required kernel option CONFIG_$1=y is unavailable"
}

configure() {
    local symbol
    local -a enabled=(
        64BIT CPU_SUP_AMD EFI EFI_STUB RELOCATABLE AMD_MEM_ENCRYPT
        HYPERV HYPERV_VMBUS HYPERV_TIMER SMP X86_LOCAL_APIC X86_X2APIC
        X86_FRED BLK_DEV_INITRD DEVTMPFS DEVTMPFS_MOUNT TTY
        SERIAL_8250 SERIAL_8250_CONSOLE EARLY_PRINTK X86_VERBOSE_BOOTUP
        DEBUG_INFO_NONE
    )
    local -a disabled=(MSHV_ROOT HYPERV_VTL_MODE WERROR LOCALVERSION_AUTO)
    local -a config_args=()

    mkdir -p -- "$OUT"

    if [[ ! -f "$OUT/.config" ]]; then
        make_kernel x86_64_defconfig
    fi

    # Leave an unchanged .config untouched to avoid needless Kbuild updates.
    for symbol in "${enabled[@]}"; do
        if ! grep -qx "CONFIG_${symbol}=y" "$OUT/.config"; then
            config_args+=(--enable "$symbol")
        fi
    done

    for symbol in "${disabled[@]}"; do
        if grep -Eq "^CONFIG_${symbol}=(y|m)$" "$OUT/.config"; then
            config_args+=(--disable "$symbol")
        fi
    done

    if (( ${#config_args[@]} )); then
        "$ROOT/scripts/config" --file "$OUT/.config" "${config_args[@]}"
    fi

    make_kernel olddefconfig

    for symbol in "${enabled[@]}"; do
        require_config "$symbol"
    done

    for symbol in "${disabled[@]}"; do
        if grep -Eq "^CONFIG_${symbol}=(y|m)$" "$OUT/.config"; then
            fail "CONFIG_${symbol} must be disabled for this guest build"
        fi
    done
}

configure

case "$ACTION" in
    build)
        make_kernel -j"$JOBS" bzImage
        image="$OUT/arch/x86/boot/bzImage"
        [[ -s "$image" ]] || fail "kernel build did not produce $image"
        printf 'Built SNP guest kernel: %s\n' "$image"
        ;;
    configure)
        printf 'Configured SNP guest kernel: %s\n' "$OUT/.config"
        ;;
    menuconfig)
        make_kernel menuconfig
        ;;
esac
