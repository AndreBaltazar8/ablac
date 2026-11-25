# Calls of abla_x64_syscall in `llvm-objdump -d --no-show-raw-insn` output: "numbers<TAB>function<TAB>address". The numbers are the constants the
# first argument register can hold at the call (comma-separated: a shared tail can be reached with two), followed through mov immediates,
# register copies and spills to and reloads from the function's own stack slots ([x29, #n] and [sp, #n]) along every path that reaches it.
# A forward branch carries its registers and slots to its target, which unites them with those of the instruction before it; a target
# a backward branch also reaches, a call (slots survive it) and a write to sp forget them. "?" when the register is not one of a set of constants.
# Run with the file twice: the first pass finds the branch targets reached backwards.
function reg(s) { sub(/^[wx]/, "", s); return (s == "zr" || s == "sp") ? "z" : s }
function target_of(    t) { t = $NF; if ($0 ~ /<.*>/) t = $(NF - 1); if (t ~ /^0x[0-9a-f]+$/) { sub(/^0x/, "", t); return t } return "" }
function union(a, b,    n, i, out, parts) {
    out = a; n = split(b, parts, ",")
    for (i = 1; i <= n; i++) if (("," out ",") !~ ("," parts[i] ",")) out = out "," parts[i]
    return out
}
function save_to(t,    r, key, kk) {
    if (t == "") return
    if (!(t in seen)) { seen[t] = 1; for (r in v) p[t, r] = v[r]; return }
    for (r in v) if ((t, r) in p) p[t, r] = union(p[t, r], v[r])
    for (key in p) { split(key, kk, SUBSEP); if (kk[1] == t && !(kk[2] in v)) delete p[key] }
}
function merge_at(addr, fall,    r, key, kk) {
    if (!(addr in seen)) return
    if (!fall) { delete v; for (key in p) { split(key, kk, SUBSEP); if (kk[1] == addr) v[kk[2]] = p[key] } return }
    for (r in v) { if ((addr, r) in p) v[r] = union(v[r], p[addr, r]); else delete v[r] }
}
# the stack slot a load or store addresses ("x8|x29|-0x10", with the register width class), or "" when it is not one of the frame's
function slot(first, base, off,    b, o, w) {
    w = (first ~ /^w/) ? "w" : "x"
    b = base; sub(/^\[/, "", b); sub(/[,\]].*$/, "", b)
    if (b != "x29" && b != "sp") return ""
    o = off; if (base ~ /\]$/) o = "#0"
    if (o ~ /!$/ || o !~ /^#-?(0x)?[0-9a-f]+\]?$/) return "?"
    sub(/\]$/, "", o)
    return w "|" b "|" o
}
function forget_slots(    k) { for (k in v) if (k ~ /\|/) delete v[k] }
NR == FNR {
    split($1, a, ":")
    if ($0 ~ /^[[:space:]]*[0-9a-f]+:[[:space:]]+(b|b\.[a-z]+|cbn?z|tbn?z)[[:space:]]/) {
        t = target_of()
        if (t != "" && (length(t) < length(a[1]) || (length(t) == length(a[1]) && t < a[1]))) backward[t] = 1
    }
    next
}
/^[0-9a-f]+ <.*>:$/ { fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); skip = (fn == "abla_x64_syscall"); delete v; delete p; delete seen; fell = 0; next }
skip { next }
{
    split($1, a, ":"); addr = a[1]
    if (addr in backward) delete v; else merge_at(addr, fell)
    fell = 1
    op = $2
    if ($0 ~ /[[:space:]]bl?[[:space:]].*<abla_x64_syscall>/) {
        value = ("0" in v) ? v["0"] : "?"
        printf "%s\t%s\t%s\n", value, fn, addr
        if (op == "bl") { for (k in v) if (k !~ /\|/) delete v[k] } else fell = 0
        next
    }
    if (op == "mov" || op == "movz") {
        d = $3; sub(/,$/, "", d); s = $4
        D = reg(d)
        if (D == "z") { forget_slots(); next }
        if (s ~ /^#/) { x = substr(s, 2); v[D] = (x ~ /^-?0x/) ? strtonum(x) : x + 0; next }
        if (s ~ /^[wx](zr|[0-9]+)$/) { S = reg(s); if (S == "z") v[D] = 0; else if (S in v) v[D] = v[S]; else delete v[D]; next }
        delete v[D]; next
    }
    if (op == "b") { save_to(target_of()); fell = 0; next }
    if (op == "ret" || op == "br") { fell = 0; next }
    if (op == "bl" || op == "blr") { for (k in v) if (k !~ /\|/) delete v[k]; next }
    if (op ~ /^b\./ || op ~ /^(cbz|cbnz|tbz|tbnz)$/) { save_to(target_of()); next }
    if (op == "str" || op == "stur") {
        first = $3; sub(/,$/, "", first); key = slot(first, $4, $5)
        if (key == "?") forget_slots()
        else if (key != "") { S = reg(first); if (S == "z") v[key] = 0; else if (S in v) v[key] = v[S]; else delete v[key] }
        next
    }
    if (op == "ldr" || op == "ldur") {
        first = $3; sub(/,$/, "", first); D = reg(first); key = slot(first, $4, $5)
        if (key != "" && key != "?" && (key in v)) v[D] = v[key]; else if (D != "z") delete v[D]
        if ($0 ~ /\]!|\],/) forget_slots()
        next
    }
    if (op ~ /^(strb|strh|sturb|sturh|stlr|stlxr|stlrb|stp|stnp|cmp|cmn|tst|nop|dmb|dsb|isb|prfm|svc|brk)$/) {
        if (op ~ /^(stp|stnp|strb|strh|sturb|sturh)$/ || $0 ~ /\]!|\],/) forget_slots()
        next
    }
    d = $3; sub(/,$/, "", d)
    if (d == "sp") forget_slots()
    if (d ~ /^[wx][0-9]+$/) delete v[reg(d)]
    if (op ~ /^(ldp|ldnp|ldaxp)$/) { e = $4; sub(/,$/, "", e); if (e ~ /^[wx][0-9]+$/) delete v[reg(e)]; if ($0 ~ /\]!|\],/) forget_slots() }
}
