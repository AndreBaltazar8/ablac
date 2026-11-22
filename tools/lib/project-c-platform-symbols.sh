#!/usr/bin/env bash
# Sourced by the raw-Linux tests. `has_project_c_platform_symbol PROGRAM` succeeds when the program defines a global (extern) symbol of the
# project's C platform (ablaHost*, abla_host_*, abla_platform_*). The platform runtime is Abla code in the module now: its local copies (the
# panic path the background collector brings in is a local abla_platform_panic) are not C platform symbols, so only global ones count.
has_project_c_platform_symbol() {
    nm --defined-only --extern-only "$1" | awk '{print $3}' | rg '^ablaHost|^abla_host_|^abla_platform_' > /dev/null
}
