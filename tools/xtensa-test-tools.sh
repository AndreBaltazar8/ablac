#!/usr/bin/env bash
# Shared Xtensa fixture setup. Source this from the target test script.

abla_xtensa_test_prepare() {
    local tools_directory=$1 real_llc
    mkdir -p "$tools_directory"
    real_llc=$(command -v llc)
    cat > "$tools_directory/llc" <<EOF_SHIM
#!/usr/bin/env bash
arguments=()
for argument in "\$@"; do
    [[ \$argument == -relocation-model=pic ]] && argument=-relocation-model=static
    arguments+=("\$argument")
done
exec "$real_llc" -mcpu=esp32 "\${arguments[@]}"
EOF_SHIM
    chmod +x "$tools_directory/llc"
}

abla_xtensa_test_build() (
    local compiler=$1 tools_directory=$2 resolved root target
    shift 2
    # Installed launchers prepend their bundled LLVM after our PATH change.
    # For their Xtensa build only, run the same payload with the same installed
    # sysroot, leaving the test shim first. Other builds keep using the launcher.
    resolved=$(command -v "$compiler")
    # realpath without Python (macOS before 13 has no realpath, nor readlink -f): follow the file's links, then its directory's.
    while [[ -L $resolved ]]; do
        target=$(readlink "$resolved")
        if [[ $target == /* ]]; then resolved=$target; else resolved=$(dirname "$resolved")/$target; fi
    done
    resolved=$(cd "$(dirname "$resolved")" && pwd -P)/$(basename "$resolved")
    root=$(dirname "$(dirname "$resolved")")
    if [[ -x $root/libexec/ablac.bin && -d $root/share/abla/stdlib && $resolved == "$root/bin/ablac" ]]; then
        compiler="$root/libexec/ablac.bin"
        export ABLA_SYSROOT="$root/share/abla"
        ulimit -S -s 131072 2>/dev/null || :
    fi
    PATH="$tools_directory:$PATH" "$compiler" "$@"
)
