# Derives the tagged-pointer guest's start file from tests/cases/simd/aarch64-start.s: its
# malloc becomes a tagging allocator (malloc.s.frag), free checks, retires and poisons
# (free.s.frag), the write system call strips the tag, realloc releases its old block, and the
# tagged state is appended. Every edit must match exactly once, so a change of the base file
# fails here instead of producing a guest that tests something else.
# Usage: awk -v fragments=DIR -f tagged.awk aarch64-start.s > start.s
function slurp(path,    line, text, saved) {
    saved = RS
    RS = "\n"
    text = ""
    while ((getline line < path) > 0) text = text line "\n"
    close(path)
    RS = saved
    return text
}
function occurrences(text, needle,    count, at) {
    count = 0
    while ((at = index(text, needle)) > 0) { count++; text = substr(text, at + length(needle)) }
    return count
}
function replace(text, needle, replacement,    at) {
    if (occurrences(text, needle) != 1) {
        printf "tagged.awk: expected one occurrence of: %s\n", needle > "/dev/stderr"
        exit 1
    }
    at = index(text, needle)
    return substr(text, 1, at - 1) replacement substr(text, at + length(needle))
}
BEGIN { RS = "\001" }
{
    assembly = $0
    start = index(assembly, "    .globl malloc\n")
    rest = substr(assembly, start)
    stop = start + index(rest, "    .globl calloc\n") - 1
    if (start == 0 || stop < start) { print "tagged.awk: no malloc..calloc block" > "/dev/stderr"; exit 1 }
    assembly = substr(assembly, 1, start - 1) slurp(fragments "/malloc.s.frag") substr(assembly, stop)
    assembly = replace(assembly, "    stp x0, x1, [sp, #16]\n    mov x0, x1\n",
        "    stp x0, x1, [sp, #16]\n    bl tagged_check_pointer\n    mov x0, x1\n")
    assembly = replace(assembly, "    .globl free\nfree:\n    ret\n", slurp(fragments "/free.s.frag"))
    assembly = replace(assembly, "write:\n    mov w8, #64\n",
        "write:\n    and x1, x1, #0x00ffffffffffffff\n    mov w8, #64\n")
    assembly = replace(assembly, "2:  ldp x29, x30, [sp], #32\n    ret\n",
        "2:  mov x6, x0\n    ldr x0, [sp, #16]\n    bl free\n    mov x0, x6\n    ldp x29, x30, [sp], #32\n    ret\n")
    assembly = assembly "\n    .data\n    .balign 8\ntagged_mode: .quad 0\ntagged_count: .quad 0\ntagged_freed: .quad 0\ntagged_bytes: .byte 0xb4, 0x54, 0xf1, 0x01\n"
    printf "%s", assembly
}
