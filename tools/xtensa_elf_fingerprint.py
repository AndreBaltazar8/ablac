"""Test-only ELF32 Xtensa comparison; mask only relocated L32R immediates."""
import hashlib
import json
import struct


def digest(value):
    return hashlib.sha256(json.dumps(value, separators=(',', ':'), sort_keys=True).encode()).hexdigest()


def fingerprint(raw, controls=False):
    assert raw[:7] == b'\x7fELF\x01\x01\x01'
    assert struct.unpack_from('<H', raw, 16)[0] == 1, 'not a relocatable object'
    assert struct.unpack_from('<H', raw, 18)[0] == 94, 'not Xtensa'
    offset = struct.unpack_from('<I', raw, 32)[0]
    width, count, names_index = struct.unpack_from('<HHH', raw, 46)
    assert width == 40 and offset + width * count <= len(raw)
    headers = [struct.unpack_from('<IIIIIIIIII', raw, offset + i * width) for i in range(count)]

    def data(header):
        assert header[4] + header[5] <= len(raw) or header[1] == 8
        return raw[header[4]:header[4] + header[5]] if header[1] != 8 else b''

    def string(table, index):
        assert index < len(table)
        return table[index:].split(b'\0', 1)[0].decode()

    names = [string(data(headers[names_index]), h[0]) for h in headers]
    symbols = {}
    for i, h in enumerate(headers):
        if h[1] != 2:
            continue
        assert h[9] == 16 and h[5] % 16 == 0
        strings = data(headers[h[6]])
        entries = []
        for pos in range(h[4], h[4] + h[5], 16):
            name, value, size, info, other, section = struct.unpack_from('<IIIBBH', raw, pos)
            target = names[section] if section < count else section
            text = target if info & 15 == 3 else string(strings, name)
            entries.append((text, value, size, info, other, target))
        symbols[i] = entries
    allocated = {i: bytearray(data(h)) for i, h in enumerate(headers) if h[2] & 2}
    relocations, masked = [], []
    first_relocation = None
    for h in headers:
        if h[1] != 4 or h[7] not in allocated:
            continue
        assert h[9] == 12 and h[5] % 12 == 0
        for pos in range(h[4], h[4] + h[5], 12):
            address, info, addend = struct.unpack_from('<IIi', raw, pos)
            kind, index = info & 255, info >> 8
            relocations.append((names[h[7]], address, kind, symbols[h[6]][index], addend))
            first_relocation = pos if first_relocation is None else first_relocation
            body = allocated[h[7]]
            # R_XTENSA_SLOT0_OP overwrites the L32R's 16-bit immediate.
            # Do not mask its opcode/register byte, other instructions, or
            # any unrelocated fields. RELA addends remain part of the digest.
            if kind == 20 and address + 3 <= len(body) and body[address] & 15 == 1:
                body[address + 1:address + 3] = b'\0\0'
                masked.append(headers[h[7]][4] + address + 1)
    sections = sorted((names[i], h[1], h[2], h[5], h[8], h[9],
                       hashlib.sha256(allocated[i]).hexdigest())
                      for i, h in enumerate(headers) if i in allocated)
    result = dict(schema=1, elfFlags=struct.unpack_from('<I', raw, 36)[0],
                  allocatedSections=len(sections), normalizedRelocations=len(relocations),
                  maskedL32rFields=len(masked), sectionsSha256=digest(sections),
                  symbolsSha256=digest(sorted([entry for table in symbols.values() for entry in table],
                                             key=lambda entry: json.dumps(entry))),
                  relocationsSha256=digest(sorted(relocations)))
    if controls:
        # A placeholder mutation is equivalent; a real opcode or RELA-addend
        # mutation must fail. These run on the actual gate object, not a mock.
        assert masked and first_relocation is not None
        changed = bytearray(raw)
        changed[masked[0]] ^= 85
        assert fingerprint(changed) == result
        changed = bytearray(raw)
        changed[masked[0] - 1] ^= 16  # Register nibble, never relocated.
        assert fingerprint(changed)['sectionsSha256'] != result['sectionsSha256']
        changed = bytearray(raw)
        changed[first_relocation + 8] ^= 1
        assert fingerprint(changed)['relocationsSha256'] != result['relocationsSha256']
    return result
