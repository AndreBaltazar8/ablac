# Sourced by tests. `abla_compiler_binary <compiler>` prints the compiler
# binary itself, for a test that sets ABLA_SYSROOT (or copies the compiler):
# a launcher, a frozen toolchain's or a released bin/ablac, exports its own
# sysroot. It is <compiler>.bin, the .bin beside the launcher a link points
# at, or a released toolchain's libexec/ablac.bin; else <compiler> itself.
abla_compiler_binary() {
    local compiler=$1 resolved=$1 target
    if [[ -x $compiler.bin ]]; then
        printf '%s\n' "$compiler.bin"
        return
    fi
    while [[ -L $resolved ]]; do
        target=$(readlink "$resolved")
        [[ $target == /* ]] || target=$(dirname "$resolved")/$target
        resolved=$target
    done
    if [[ -x $resolved.bin ]]; then
        printf '%s\n' "$resolved.bin"
    elif [[ -x $(dirname "$resolved")/../libexec/ablac.bin ]]; then
        printf '%s\n' "$(dirname "$resolved")/../libexec/ablac.bin"
    else
        printf '%s\n' "$compiler"
    fi
}
