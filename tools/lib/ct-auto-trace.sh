#!/usr/bin/env bash
# ct_auto_follows_jit AUTO_LOG JIT_LOG: the `auto` tier's site choices are the native tier's, except that a pass
# whose sites reach no loop, lambda or recursion is interpreted whole (docs/compile-time.md#native-evaluation). Every
# native or interpreted note of the auto build is a note of the jit build, or an interpreted note naming that rule.
# Prints the notes that are neither and returns 1.
ct_auto_follows_jit() {
    local extra
    extra=$(grep -E '^note\[ct-jit\]: (native|interpreted) at ' "$1" |
        grep -v '^note\[ct-jit\]: interpreted at [0-9]*: auto: no site of this pass ' |
        grep -vxF -f <(grep -E '^note\[ct-jit\]: (native|interpreted) at ' "$2"; echo '#none') || true)
    [[ -z $extra ]] && return 0
    printf 'auto notes the jit build (%s) does not have, in %s:\n%s\n' "$2" "$1" "$extra" >&2
    return 1
}
