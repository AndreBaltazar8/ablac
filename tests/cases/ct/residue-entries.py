#!/usr/bin/env python3
"""Rewrites a fixture file for the residue read: each fixture becomes a @noinline worker with its body, and an
exported `ct_res_<name>` that calls the worker and then wipes the stack below it (abla/ct/scrub), which is the
shape of a public entry point of the crypto code. The original exports are dropped, so the two copies of a body
are never in one object (LLVM would merge identical functions into a jump). tools/test-ct.sh reads the result for
secret residue. Usage: residue-entries.py <fixture.ab> <wipe-function> <output.ab> [skip-list ...]; prints the entry names."""
import re
import sys

path, wipe, output = sys.argv[1], sys.argv[2], sys.argv[3]
# Fixtures that are read some other way (by following calls) and need no residue entry: their spec files, if any.
skip = set()
for listing in sys.argv[4:]:
    try:
        skip |= {line.split(':')[0] for line in open(listing).read().split('\n') if line.strip()}
    except FileNotFoundError:
        pass
source = open(path).read()
head = re.compile(r'^@inline @export\("(ct_(?:fix|pbe)_[A-Za-z0-9_]+)"\)\n((trusted )?fun (\w+)\(([^)]*)\)(?:: (\w+))?)', re.M)


def function_end(text, start):
    """The end of the declaration that begins at `start`: its closing brace, or the end of its expression."""
    brace = text.find('{', start)
    newline = text.find('\n', start)
    equals = text.find('=', start)
    if brace != -1 and (equals == -1 or brace < equals or (newline != -1 and brace < newline)):
        depth, at = 0, brace
        while True:
            if text[at] == '{':
                depth += 1
            elif text[at] == '}':
                depth -= 1
                if depth == 0:
                    return at + 1
            at += 1
    # An expression body: it ends where a line does not continue with indentation.
    at = text.find('\n', start)
    while at != -1 and at + 1 < len(text) and text[at + 1] in ' \t':
        at = text.find('\n', at + 1)
    return len(text) if at == -1 else at


pieces = []
last = 0
for m in list(head.finditer(source)):
    exported, signature, trusted, function, parameters, returns = m.groups()
    trusted = trusted or ''
    if exported in skip or exported.replace('ct_fix_', 'ct_leak_', 1) in skip:
        continue
    end = function_end(source, m.start(2))
    body = source[m.start(2):end]
    worker = function + 'Work'
    arguments = ', '.join(p.split(':')[0].strip() for p in parameters.split(',') if p.strip())
    copy = '@noinline ' + body.replace(f'fun {function}(', f'fun {worker}(', 1)
    entry_name = 'ct_res_' + exported[3:]
    call = f'{worker}({arguments})'
    if returns and returns != 'void':
        entry = f'val result = {call}\n    {wipe}()\n    return result'
    else:
        entry = f'{call}\n    {wipe}()\n    return'
    pieces.append(source[last:m.start()])
    pieces.append(f'{copy}\n\n@inline @export("{entry_name}")\n{trusted}fun {function}Res({parameters}): {returns or "void"} {{\n    {entry}\n}}')
    last = end
    print(entry_name)
pieces.append(source[last:])
open(output, 'w').write(''.join(pieces))
