#!/usr/bin/env python3
"""Generate intraprocedural CT fixtures from production crypto, never stale copies.

Only public metadata/address adapters are handwritten. Allocation, clear/copy,
free and out-of-line calls cannot be followed by check-asm.py. Hash guards on
all excluded text require a coverage review if that scaffolding changes.
Each generated function has a twin with a secret-indexed volatile store.
"""
from pathlib import Path
import hashlib
import re
import sys

ROOT = Path(__file__).resolve().parents[3]
AES = (ROOT / 'stdlib/abla/crypto/aes/entry.ab').read_text()
BN = (ROOT / 'stdlib/abla/crypto/bignum/entry.ab').read_text()
RSA = (ROOT / 'stdlib/abla/crypto/rsa/entry.ab').read_text()


def body(source, name):
    match = re.search(r'^.*\bfun ' + name + r'\(', source, re.M)
    assert match, name
    start = source.index('{', match.start()) + 1
    end = source.index('\n}', start)
    return source[start:end]


# These guards cover ONLY text left outside the generated fixtures, not their
# tested bodies. Regenerating a fixture must never silently miss a new branch
# added to one of the excluded allocation/dispatch sections.
GUARDS = {
    'rsaReduceWide': '70cb36939027e8908938b0c85604f47cd4cb76d03d51a3abd0b2ca973e52120e',
    'rsaCrt': 'ec3addee5a5fd74adebecd24260bbc8f67efcabc64d421633d3a44467254dd65',
    'bnResidueSquare': '2bb8f304e7c5f1047e19dfdb5507ec2bedb6331b54384daab6d73a6dcaf91905',
    'bnFromBytes': 'eeebce423076a53fb063f21cbfb0397b5be468ad3d3ef283e2363eb3b35219c8',
    'aesSoftBlocks': '8ff73661c081f911087468327f77b4eef43a7cfea6b155f883861da35e242c60',
    'aesWrappers': 'd2951fcd9ac1af4d3560dd97d0356b52be56f2322af65db80e98f512b7a3f441',
}


def guard(name, *pieces):
    actual = hashlib.sha256('\0'.join(pieces).encode()).hexdigest()
    if name not in GUARDS:
        raise AssertionError(f'missing source guard {name}: {actual}')
    assert GUARDS[name] == actual, f'{name}: excluded source changed; review CT coverage (now {actual})'


def section(text, begin, end):
    assert text.count(begin) == 1, begin
    assert end in text, end
    at = text.index(begin)
    stop = text.index(end, at)
    return text[at:stop], text[:at], text[stop:]


out = []
specs = []
leaks = []
follow_specs = []
follow_leaks = []


def fixture(name, args, setup, actual, taints, leak_address='work', follow=False):
    # Leak controls run the same generated body before a genuine secret-indexed
    # volatile store; a missed call is NOT accepted as detecting this leak.
    # `follow`: the body calls private functions that stay calls, so only the x86-64 checker that follows calls
    # (tools/test-ct.sh orchestration_read) reads it, and it is listed apart.
    for bad in [False, True]:
        exported = 'ct_' + ('leak_' if bad else 'fix_') + name
        extra = ('\n    ablaUnsafeVolatileStoreU8(work + int(bnLoad(' + leak_address +
                 ').declassify() & u32(255)), 1)\n') if bad else ''
        out.append(f'\n@inline @export("{exported}")\ntrusted fun {exported}({args}): void {{\n{setup}\n{actual}{extra}\n}}\n')
        ((follow_leaks if follow else leaks) if bad else (follow_specs if follow else specs)).append(exported + ':' + taints)


# The key schedule, the hardware decryption keys and the hardware block loops are read as written: the functions of
# plain integers between BEGIN/END AES KEY EXPANSION (the test appends that region to the fixture module, and
# follows the calls between its functions). What allocates, builds the key object or finds a managed string's
# address is outside it, and given nothing secret: the guard below makes a change there a reviewed one.
def chunk(source, name):
    # A function written as one expression: from its `fun` to the next blank line.
    match = re.search(r'^[^\n]*\bfun ' + name + r'\(.*?(?=\n\n)', source, re.M | re.S)
    assert match, name
    return match.group(0)


# The wrappers, and the public entries that choose which addresses and how many rounds reach the read workers.
wrappers = ''.join(body(AES, name) for name in ['aesKeyBytes', 'aesAllocateMemory', 'aesNewKey', 'aesStringAddress', 'aesExpandBytes'])
wrappers += ''.join(chunk(AES, name) for name in ['AesKey.schedule', 'AesKey.decryption', 'aesHardwareEncrypt', 'aesHardwareDecrypt'])
guard('aesWrappers', wrappers)
# A secret never becomes a public integer in the text the checker doesn't read: the compiler rejects branching on,
# indexing by or dividing a secret, so what is left to the assembly check there is only what the compiler itself
# might add, and declassifying is the one way out of the type.
assert 'declassify' not in wrappers, 'an allocation wrapper declassifies'
for count in [16, 24, 32]:
    fixture(f'aes_expand_{count * 8}', 'work: int, source: int, hardware: bool', '',
            f'    aesExpandSchedule(work, source, {count}, hardware)', '@0,@1', 'source', follow=True)
fixture('aes_expand_variable', 'work: int, source: int, count: int, hardware: bool', '',
        '    aesExpandSchedule(work, source, count, hardware)', '@0,@1', 'source', follow=True)
fixture('aes_decryption_keys', 'schedule: int, out: int, rounds: int, work: int', '',
        '    aesDecryptionKeys(schedule, out, rounds)', '@0,@1', 'schedule', follow=True)
fixture('aes_hardware_encrypt', 'schedule: int, rounds: int, input: int, output: int, count: int, work: int', '',
        '    aesHardwareEncryptAt(schedule, rounds, input, output, count)', '@0,@2,@3', 'schedule', follow=True)
fixture('aes_hardware_decrypt', 'keys: int, rounds: int, input: int, output: int, count: int, work: int', '',
        '    aesHardwareDecryptAt(keys, rounds, input, output, count)', '@0,@2,@3', 'keys', follow=True)

# Exact byte-loader body (unaligned source), writing all four loaded bytes.
load = body(AES, 'aesLoadBytes')
last = '    secretU32(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24))'
assert load.endswith(last)
fixture('aes_load_bytes', 'work: int', '    val address = work',
        load[:-len(last)] + '    aesStore(work + 8, ' + last.strip() + ')', '@0')

# The complete input/output loops around the already-checked bitsliced rounds.
blocks = body(AES, 'aesSoftBlocks')
loading, before, after = section(blocks, '        val second =', '        aesOrthogonalize(q)')
storing, middle, tail = section(after, '        for (i in 0 until 4)', '        block = block + 2')
guard('aesSoftBlocks', before, middle, tail)
fixture('aes_block_io', 'work: int, count: int',
        '    val q = work\n    val input = work + 32\n    val output = input + count * 16\n    var block = 0',
        '    while (block < count) {\n' + loading + storing + '        block = block + 2\n    }', '@0')

# Only the initial public-length bnClear call is excluded, not any secret work.
for name in ['bnFromBytes', 'bnResidueSquare']:
    source = body(BN, name)
    clear = '\n    bnClear(' + ('to' if name == 'bnFromBytes' else 'out') + ', words)\n'
    assert source.startswith(clear), name
    guard(name, clear)
    actual = source[len(clear):]
    if name == 'bnFromBytes':
        fixture('bn_from_bytes', 'work: int, count: int',
                '    val to = work\n    val data = work + ((count + 3) / 4) * 4', actual, '@0')
    else:
        fixture('bn_residue_square', 'work: int, words: int',
                '    val out = work\n    val modulus = work + words * 4\n    val t = work + words * 8', actual, '@0')
fixture('bn_to_bytes', 'work: int, count: int',
        '    val from = work\n    val to = work + ((count + 3) / 4) * 4',
        body(BN, 'bnToBytes'), '@0')

crt = body(RSA, 'rsaCrt')
correction, prefix, suffix = section(crt, '    var borrow =', '    rsaMultiplyPlain(p, h, h, key.inverseQ())')
recombine, bridge, ending = section(suffix, '    carry = secretU32', '    bnCopy(out, padded, nWords)')
guard('rsaCrt', prefix, bridge, ending)
for name in ['rsaCrt', 'rsaModulusFromLimbs', 'rsaReduceWide']:
    assert 'declassify' not in body(RSA, name), f'{name} declassifies: its text is read only by the type system'
assert correction.count('p.value()') == 1
fixture('rsa_crt_correction', 'work: int, words: int',
        '    val m1 = work\n    val m2p = work + words * 4\n    val h = work + words * 8\n    val prime = work + words * 12',
        correction.replace('p.value()', 'prime'), '@0')
fixture('rsa_crt_recombine', 'work: int, words: int',
        '    val wide = words * 2\n    val padded = work\n    val m2 = work + wide * 4\n    var carry = secretU32(u32(0))', recombine, '@0')

# Wide reduction's carry/add/subtract glue is part of rsaCrt's reduction path.
reduction, prefix, suffix = section(body(RSA, 'rsaReduceWide'),
    '    var carry =', '    bnRelease(high, words)')
guard('rsaReduceWide', prefix, suffix)
assert reduction.count('modulus.value()') == reduction.count('modulus.scratch()') == 1
fixture('rsa_reduce_wide', 'work: int, words: int',
        '    val out = work\n    val high = work + words * 4\n    val prime = work + words * 8\n    val scratch = work + words * 12',
        reduction.replace('modulus.value()', 'prime').replace('modulus.scratch()', 'scratch'), '@0')

path = Path(sys.argv[1])
path.write_text(''.join(out))
path.with_suffix('.good').write_text('\n'.join(specs) + '\n')
path.with_suffix('.leaks').write_text('\n'.join(leaks) + '\n')
path.with_suffix('.follow').write_text('\n'.join(follow_specs) + '\n')
path.with_suffix('.followleaks').write_text('\n'.join(follow_leaks) + '\n')
print(f'crypto source fixtures: {len(specs)} paths with {len(leaks)} secret-index controls, {len(follow_specs)} read by following calls with {len(follow_leaks)}')
