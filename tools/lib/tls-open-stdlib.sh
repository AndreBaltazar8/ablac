#!/usr/bin/env bash
# tls_open_stdlib ROOT DIR: a copy of ROOT/stdlib at DIR/stdlib-open whose TLS machines' key material is public again.
# TlsClient's and TlsServer's secrets are `private var` fields of their own modules, so no program can read or replace
# them; the tests that check a wipe from outside (server.ab, wipe.ab, handles.ab) read and set them, and build against
# this copy with ABLA_STDLIB=DIR/stdlib-open. Returns 1 when the copy has no opened field (the fields were renamed).
tls_open_stdlib() {
    local open=$2/stdlib-open
    rm -rf -- "$open"
    cp -r -- "$1/stdlib" "$open"
    sed -i -e "s/^private var TlsClient\./var TlsClient./" "$open/abla/tls/pure/client/entry.ab"
    sed -i -e "s/^private var TlsServer\./var TlsServer./" "$open/abla/tls/pure/server/entry.ab"
    grep "^var TlsClient\.masterSecret" "$open/abla/tls/pure/client/entry.ab" > /dev/null &&
        grep "^var TlsServer\.master:" "$open/abla/tls/pure/server/entry.ab" > /dev/null ||
        { echo "tls_open_stdlib: the open library copy has no open machine fields" >&2; return 1; }
}
