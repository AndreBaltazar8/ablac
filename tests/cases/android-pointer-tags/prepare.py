#!/usr/bin/env python3
"""Generate source-synchronized private RSA tests and a tagged A64 libc shim.

All guest loads/stores really carry their tags under qemu-aarch64 TBI. The
allocator never strips returned pointers. free/realloc reject a changed tag.
This tests TBI, not MTE, bionic, real TLS interoperability or an Android device.
"""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('root', type=Path)
parser.add_argument('sysroot', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
root, sysroot, out = args.root.absolute(), args.sysroot.absolute(), args.output.absolute()
out.mkdir(parents=True, exist_ok=True)
(out / "abla.toml").write_text('compileCapabilities = ["filesystem.write"]\n')
source = (sysroot / 'stdlib/abla/crypto/rsa/entry.ab').read_text()
begin = '// BEGIN RSA SECRET BIGNUM PRIMITIVES'
end = '// END RSA SECRET BIGNUM PRIMITIVES'
assert source.count(begin) == source.count(end) == 1
private = source[source.index(begin):source.index(end) + len(end)]
fixture = (root / 'tests/cases/android-pointer-tags/main.ab').read_text()
assert fixture.count('"@HOST_PLATFORM@"') == 1
host = sysroot / 'stdlib/abla/runtime/platform/host.ab'
assert host.is_file()
fixture = fixture.replace('"@HOST_PLATFORM@"', json.dumps(str(host)))
(out / 'fixture.ab').write_text(fixture + '\n' + private + '\n')
relative = out.relative_to(root)
for profile, fast in [('release', False), ('fast', True)]:
    driver = '''import "abla/build"
import "abla/compiler"
#compilerGrant("filesystem.write")
compile fun taggedObject(): bool {
    val target = defineTarget("tagged-arm64", "aarch64-unknown-linux-gnu", "elf", "none", "none", false, false)
    target && buildProgram("tagged-pointers", SOURCE, OUTPUT, "tagged-arm64", "object", FAST, false)
}
val built = #taggedObject()
fun main: int = if (built) 0 else 1
'''.replace('SOURCE', json.dumps((relative / 'fixture.ab').as_posix())).replace('OUTPUT', json.dumps((relative / (profile + '.o')).as_posix())).replace('FAST', str(fast).lower())
    (out / (profile + '-build.ab')).write_text(driver)
assembly = (root / 'tests/cases/simd/aarch64-start.s').read_text()
start = assembly.index('    .globl malloc\n')
stop = assembly.index('    .globl calloc\n', start)
assembly = assembly[:start] + '''    .globl malloc
malloc:
    add x0, x0, #31
    and x0, x0, #-16
    adrp x1, heap_next
    add x1, x1, :lo12:heap_next
    ldr x2, [x1]
    cbnz x2, 1f
    adrp x2, heap
    add x2, x2, :lo12:heap
1:  add x3, x2, x0
    str x3, [x1]
    str x0, [x2]
    adrp x4, tagged_mode
    add x4, x4, :lo12:tagged_mode
    ldr x4, [x4]
    cbnz x4, 2f
    adrp x5, tagged_count
    add x5, x5, :lo12:tagged_count
    ldr x4, [x5]
    add x6, x4, #1
    str x6, [x5]
    and x4, x4, #3
    adrp x5, tagged_bytes
    add x5, x5, :lo12:tagged_bytes
    ldrb w4, [x5, x4]
    b 3f
2:  mov x4, #0xb4
3:  str x4, [x2, #8]
    add x0, x2, #16
    orr x0, x0, x4, lsl #56
    ret

''' + assembly[stop:]
needle = '    stp x0, x1, [sp, #16]\n    mov x0, x1\n'
assert assembly.count(needle) == 1
assembly = assembly.replace(needle, '    stp x0, x1, [sp, #16]\n    bl tagged_check_pointer\n    mov x0, x1\n')
needle = '    .globl free\nfree:\n    ret\n'
assert assembly.count(needle) == 1
assembly = assembly.replace(needle, '''    .globl free
free:
    cbz x0, 2f
    lsr x2, x0, #56
    ldur x3, [x0, #-8]
    cmp x2, x3
    b.ne tagged_bad_pointer
    // Remember release, so double free and realloc-after-free are rejected.
    orr x2, x2, #0x100
    stur x2, [x0, #-8]
    adrp x2, tagged_freed
    add x2, x2, :lo12:tagged_freed
    ldr x3, [x2]
    add x3, x3, #1
    str x3, [x2]
    // A bump allocator alone would leave wrongly collected live values usable.
    // Poison the actual allocation after its prefix, making lost roots fail.
    ldur x3, [x0, #-16]
    sub x3, x3, #16
    mov x4, x0
    mov w5, #0xdd
1:  cbz x3, 2f
    strb w5, [x4], #1
    sub x3, x3, #1
    b 1b
2:  ret

tagged_check_pointer:
    cbz x0, 2f
    lsr x2, x0, #56
    ldur x3, [x0, #-8]
    cmp x2, x3
    b.ne tagged_bad_pointer
2:  ret

tagged_bad_pointer:
    mov w0, #66
    mov w8, #93
    svc #0

    // Custom call names keep the invalid-tag controls out of malloc/free
    // builtin folding; production runtime calls still use the actual ABI.
    .globl tagged_probe_free
tagged_probe_free:
    b free
    .globl tagged_probe_realloc
tagged_probe_realloc:
    b realloc

    .globl tagged_set_mode
tagged_set_mode:
    adrp x1, tagged_mode
    add x1, x1, :lo12:tagged_mode
    str x0, [x1]
    ret

    .globl tagged_free_count
tagged_free_count:
    adrp x1, tagged_freed
    add x1, x1, :lo12:tagged_freed
    ldr x0, [x1]
    ret

    .globl getpid
getpid:
    mov x0, #1
    ret
''')
# Panic messages may be heap backed. Strip only at the kernel write boundary,
# not any allocation, load/store, copy, realloc or free.
needle = 'write:\n    mov w8, #64\n'
assert assembly.count(needle) == 1
assembly = assembly.replace(needle, 'write:\n    and x1, x1, #0x00ffffffffffffff\n    mov w8, #64\n')
# realloc invalidates its old block too. x6 holds the new result across our
# leaf free stub, which deliberately clobbers only x2..x5.
needle = '2:  ldp x29, x30, [sp], #32\n    ret\n'
assert assembly.count(needle) == 1
assembly = assembly.replace(needle, '2:  mov x6, x0\n    ldr x0, [sp, #16]\n    bl free\n    mov x0, x6\n    ldp x29, x30, [sp], #32\n    ret\n')
assembly += '''
    .data
    .balign 8
tagged_mode: .quad 0
tagged_count: .quad 0
tagged_freed: .quad 0
tagged_bytes: .byte 0xb4, 0x54, 0xf1, 0x01
'''
for entry in ['values', 'pages', 'descriptor', 'rsa', 'bad_free', 'bad_realloc']:
    assert assembly.count('    bl simd_checks\n') == 1
    (out / (entry + '-start.s')).write_text(assembly.replace('    bl simd_checks\n', '    bl tagged_' + entry + '\n'))
print('tagged pointer fixture: real RSA helpers + A64 tagged allocator generated')
