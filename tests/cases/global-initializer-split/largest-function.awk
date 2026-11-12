# Prints the length of the largest function body in a WebAssembly module's code section.
# Input: the module's bytes as decimal numbers (od -An -v -tu1). The bytes are consumed
# one at a time by a small state machine, so a module of any size needs no storage.
# Section layout: id byte, LEB128 size, payload; the code section (id 10) starts with a
# LEB128 function count, then each body is a LEB128 length followed by that many bytes.
function leb_byte(b) {
    value += (b % 128) * mul
    mul *= 128
    return b < 128
}
function start_leb() { value = 0; mul = 1 }
function finish_section() { skip = section_left; state = skip > 0 ? "skip-section" : "id" }
function consume(b) {
    consumed++
    if (state == "header") { if (consumed == 8) state = "id"; return }
    if (state == "id") { id = b; start_leb(); state = "size"; return }
    if (state == "size") {
        if (!leb_byte(b)) return
        section_left = value
        if (id == 10) { start_leb(); state = "count" }
        else { skip = section_left; state = skip > 0 ? "skip-section" : "id" }
        return
    }
    if (state == "skip-section") { if (--skip == 0) state = "id"; return }
    # Inside the code section: every byte below counts against its size.
    section_left--
    if (state == "count") {
        if (!leb_byte(b)) return
        functions = value
        if (functions == 0) finish_section(); else { start_leb(); state = "length" }
        return
    }
    if (state == "length") {
        if (!leb_byte(b)) return
        if (value > largest) largest = value
        body_left = value
        if (body_left > 0) state = "body"
        else { if (--functions == 0) finish_section(); else { start_leb(); state = "length" } }
        return
    }
    if (state == "body") {
        if (--body_left > 0) return
        if (--functions == 0) finish_section(); else { start_leb(); state = "length" }
        return
    }
}
BEGIN { state = "header"; largest = 0 }
{ for (i = 1; i <= NF; i++) consume($i + 0) }
END { print largest }
