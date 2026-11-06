#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/host-llvm-tools"
mkdir -p "$output_directory/shim"
rm -f "$output_directory/shim.log"

# An llc first on PATH that compiles for the ESP32, as abla-embedded's esp-llvm-bin does
# for a PaperMono build, which also builds a host program there. A host build takes its opt
# and llc from its own toolchain (ABLA_LLVM_TOOLS, or a PATH directory holding both); a
# non-Xtensa cross build still runs PATH's llc. Xtensa now selects its explicit
# companion, covered separately by test-xtensa-routing.
real_llc=$(command -v llc)
cat > "$output_directory/shim/llc" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$output_directory/shim.log"
arguments=()
for argument in "\$@"; do
    [[ \$argument == -relocation-model=pic ]] && argument=-relocation-model=static
    arguments+=("\$argument")
done
# A real SDK wrapper passes other architectures through unchanged.
for argument in "\${arguments[@]}"; do
    if [[ \$argument == -mtriple=wasm* ]]; then exec "$real_llc" "\${arguments[@]}"; fi
done
exec "$real_llc" -mcpu=esp32 "\${arguments[@]}"
EOF
chmod +x "$output_directory/shim/llc"
cat > "$output_directory/hello.ab" <<'EOF'
import "abla/io"
fun main: int {
    println("hello from the host")
    0
}
EOF

host_build() { # label [env assignments...]
    local label=$1
    shift
    if ! env "$@" PATH="$output_directory/shim:$PATH" "$compiler" build "$output_directory/hello.ab" \
        -o "$output_directory/hello-$label" --no-cache >"$output_directory/$label.out" 2>&1; then
        echo "host-llvm-tools: a host build ($label) with an ESP32 llc first on PATH failed" >&2
        sed -n '1,20p' "$output_directory/$label.out" >&2
        exit 1
    fi
    if [[ $("$output_directory/hello-$label") != "hello from the host" ]]; then
        echo "host-llvm-tools: the host program ($label) printed something else" >&2
        exit 1
    fi
    if [[ -s $output_directory/shim.log ]]; then
        echo "host-llvm-tools: a host build ($label) ran the llc first on PATH:" >&2
        cat "$output_directory/shim.log" >&2
        exit 1
    fi
}

host_build configured
# Without ABLA_LLVM_TOOLS: the first PATH directory with both opt and llc, not the lone llc.
host_build unconfigured -u ABLA_LLVM_TOOLS

printf 'fun main: int = 42\n' > "$output_directory/cross.ab"
PATH="$output_directory/shim:$PATH" "$compiler" build "$output_directory/cross.ab" \
    -o "$output_directory/hello-wasm.o" --no-cache \
    --target-triple wasm32-unknown-unknown --object-format wasm --emit object >"$output_directory/cross.out" 2>&1 || {
    echo "host-llvm-tools: the non-Xtensa cross object failed to build" >&2
    sed -n '1,20p' "$output_directory/cross.out" >&2
    exit 1
}
if ! grep -q -- '-mtriple=wasm32-unknown-unknown' "$output_directory/shim.log"; then
    echo "host-llvm-tools: a non-Xtensa cross codegen did not run the llc on PATH" >&2
    exit 1
fi

echo "host-llvm-tools: host builds run their own opt and llc past an ESP32 llc on PATH; non-Xtensa cross builds still run it"
