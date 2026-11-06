#!/usr/bin/env python3
"""Offline exact differential against the frozen SDK transform; no Xtensa LLVM needed."""
import gzip
import hashlib
import json
import os
import re
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).absolute().parent.parent
fixtures = root / 'tests/cases/xtensa-routing'
compiler = os.path.abspath(sys.argv[1])  # Keep the build/ablac launcher identity.
provenance = json.loads((fixtures / 'assembly-provenance.json').read_text())
reference = fixtures / 'sdk-narrow.py'
assert hashlib.sha256(reference.read_bytes()).hexdigest() == provenance['sdkScriptSha256']
assert provenance['sdkScriptSha256'] == 'a2fd95380faf9c54d500cfed1795cad53c557fabd031df31c008e324db2a10c3'
firmware = gzip.decompress((fixtures / 'firmware.s.gz').read_bytes())
assert hashlib.sha256(firmware).hexdigest() == provenance['firmwareAssemblySha256']
lines = ['.section .text.probe,"ax",@progbits', '.literal_position', '.literal .Lprobe, 123', '', '# literal comment']
for reg in range(16):
    for value in [-2049, -2048, -33, -32, -1, 0, 1, 15, 16, 60, 61, 64, 95, 96, 2047, 2048]:
        for op in ['movi', 'addi', 'l32i', 's32i']:
            operands = f'a{reg}, {value}' if op == 'movi' else f'a{reg}, a{(reg+1)%16}, {value}'
            lines.append(f'\t{op}\t{operands} # edge {op}')
    lines.extend([f'  or a{reg}, a0, a0', f'\tadd a{reg}, a1, a2', f' or a{reg}, a0, a1'])
lines += ['movi a16, 1', 'movi a01, 1', 'movi a2, +1', 'movi a2, 0x10',
          'addi a2, a3, +1', 'add a0, a1, a16', 'movi a2, symbol',
          '.cfi_startproc', '#APP', '  movi a2, 1', '#NO_APP',
          '.begin no-transform', '  or a2, a1, a1', '.end no-transform',
          '.ascii "#APP movi a2, 1"', '.cfi_endproc', 'movi a2, 1']
edges = '\n'.join(lines).encode()  # The final unterminated line is intentional.

with tempfile.TemporaryDirectory(prefix='abla-xtensa-assembly-') as directory:
    work = Path(directory)
    binary = work / 'assembly'
    subprocess.run([compiler, 'build', str(fixtures / 'assembly.ab'), '--fast', '--no-cache', '-o', str(binary)], check=True, timeout=300)
    for name, source in [('edges', edges), ('firmware', firmware)]:
        input_path, output_path = work / f'{name}.s', work / f'{name}.out'
        input_path.write_bytes(source)
        for keep in [False, True]:
            env = dict(os.environ, ABLA_ESP_KEEP_UNWIND='1' if keep else '0')
            expected = subprocess.run([sys.executable, '-I', str(reference)], input=source, capture_output=True, env=env, check=True).stdout
            subprocess.run([str(binary), str(input_path), str(output_path), 'keep' if keep else 'narrow'], check=True, timeout=60)
            actual = output_path.read_bytes()
            assert actual == expected, f'{name}: exact SDK differential failed (keep={keep})'
            # Prove these comparisons distinguish an unchanged, unnarrowed input.
            assert expected != source, f'{name}: fixture exercises no transformation'
            assert actual.replace(b'movi.n', b'movi', 1) != expected, f'{name}: broken transform was not detected'
    subprocess.run([str(binary), str(input_path), str(output_path), 'module'], check=True, timeout=60)
    encoded = output_path.read_text()
    assert encoded.startswith('source_filename = "abla"\ntarget triple = "xtensa-esp-unknown-elf"\nmodule asm "')
    assert '\\0A' in encoded and '.p2align 2' in encoded
    payload = encoded.split('module asm "', 1)[1].rsplit('"', 1)[0]
    decoded = re.sub(rb'\\([0-9A-F]{2})', lambda match: bytes([int(match[1], 16)]), payload.encode())
    expected_body = firmware.removeprefix(b'\t.file\t"abla"\n')
    assert decoded.startswith(expected_body), 'module encoding changed the assembly body'
    alignment = decoded[len(expected_body):]
    for section in [b'.iram1.abla.freertos.yield.literal', b'.iram1.abla.freertos.coproc_exc_hook.literal']:
        assert b'.pushsection ' + section + b',"ax",@progbits\n.p2align 2\n.popsection\n' in alignment

    # Section-stack and expression cases must align the pool actually used,
    # without modifying the input assembly or inventing a neighboring pool.
    section_edges = (b'.section .text.root,"ax",@progbits\n'
                     b'movi a2, 65536\n.pushsection .iram.child,"ax",@progbits\n'
                     b'movi a3, symbol + 8\n.popsection\nmovi a4, other_symbol\n'
                     b'.previous\nmovi a5, child_symbol\n.text\nmovi a6, last_symbol\n'
                     b'.section ".text.quoted","ax",@progbits\nmovi a7, final_symbol\n')
    input_path.write_bytes(section_edges)
    subprocess.run([str(binary), str(input_path), str(output_path), 'module'], check=True, timeout=60)
    payload = output_path.read_text().split('module asm "', 1)[1].rsplit('"', 1)[0]
    decoded = re.sub(rb'\\([0-9A-F]{2})', lambda match: bytes([int(match[1], 16)]), payload.encode())
    assert decoded.startswith(section_edges)
    pools = re.findall(rb'\.pushsection ([^,\n]+),"ax",@progbits\n\.p2align 2\n\.popsection', decoded[len(section_edges):])
    assert set(pools) == {b'.literal.root', b'.iram.child.literal', b'.literal', b'.literal.quoted'}, pools

    # The target-independent empty-module envelope must not encode an input
    # filename/PID. ELF data directives let stock host llc prove this offline.
    llc = shutil.which('llc')
    if llc:
        input_path.write_bytes(b'\t.file\t"abla"\n.section .rodata.abla_probe,"a",@progbits\n.long 42\n')
        subprocess.run([str(binary), str(input_path), str(output_path), 'module'], check=True, timeout=60)
        objects = []
        for stem in ['first-process-123', 'other-process-987']:
            module, obj = work / (stem + '.ll'), work / (stem + '.o')
            module.write_bytes(output_path.read_bytes())
            subprocess.run([llc, '-mtriple=x86_64-unknown-linux-gnu', '-filetype=obj', str(module), '-o', str(obj)], check=True, timeout=60)
            objects.append(obj.read_bytes())
        assert objects[0] == objects[1], 'temporary module filename leaked into the object'
    else:
        print('SKIP object-envelope reproducibility: host llc is unavailable')

print('PASS Xtensa assembly: SDK exact text on operand edges and complete firmware, raw regions, CFI, and negative control')
