#!/usr/bin/env bash
# compiler_is_static <compiler>: true when the compiler is the statically linked one (#806 step C: no program interpreter), which cannot load a
# shared object at compile time (decision #88: manifest nativeLibraries and dlopen of a library are not available in it).
compiler_is_static() {
    local payload=$1
    # build/ablac is a launcher script whose compiler is build/ablac.bin.
    [[ -f $payload.bin ]] && payload=$payload.bin
    local headers
    headers=$(readelf -lW "$payload" 2>/dev/null) || return 1
    [[ $headers == *'Program Headers'* && $headers != *' INTERP '* ]]
}
