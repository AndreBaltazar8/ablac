#!/usr/bin/env python3
"""Strict byte comparison with diagnostic-only thin 64-bit Mach-O inventories.

Nothing is stripped, re-signed, normalized or accepted as an exception. A
mismatch always exits 1. Formats follow Apple's loader.h and cs_blobs.h:
https://github.com/apple-oss-distributions/cctools/blob/main/include/mach-o/loader.h
https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h
"""
import argparse
import bisect
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import uuid


def sha(data):
    return hashlib.sha256(data).hexdigest()


def cstr(data, start, end):
    if not 0 <= start < end <= len(data):
        raise ValueError('string offset outside its container')
    return data[start:data.index(0, start, end)].decode('utf-8', errors='replace')


def span(data, offset, size):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise ValueError(f'file range outside image: {offset}+{size}')
    return data[offset:offset + size]


def inventory(path):
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xfeedfacf:
        raise ValueError('expected a thin little-endian 64-bit Mach-O image')
    _, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from('<8I', data)
    span(data, 32, command_bytes)
    result = dict(path=str(path), bytes=len(data), sha256=sha(data),
                  header=dict(cpu=cpu, subtype=subtype, filetype=kind, flags=flags,
                              commands=count, commandBytes=command_bytes, reserved=reserved),
                  loadCommands=[], sections=[], symbols=[], codeDirectories=[])
    position = 32
    symtab = None
    for index in range(count):
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or position + size > 32 + command_bytes:
            raise ValueError('invalid load-command size')
        raw = span(data, position, size)
        record = dict(index=index, command=hex(command), offset=position, bytes=size, sha256=sha(raw))
        if command == 0x19:
            record['segment'] = raw[8:24].rstrip(b'\0').decode()
            nsects = struct.unpack_from('<I', raw, 64)[0]
            if 72 + nsects * 80 > size:
                raise ValueError('invalid segment section count')
            for section_id in range(nsects):
                fields = struct.unpack_from('<16s16sQQ8I', raw, 72 + section_id * 80)
                name, segment, address, length, offset, alignment, reloc, nreloc, section_flags, *_ = fields
                zero = (section_flags & 0xff) in (1, 0xc, 0x12)
                content = b'' if zero else span(data, offset, length)
                result['sections'].append(dict(index=len(result['sections']) + 1,
                    name=segment.rstrip(b'\0').decode() + ',' + name.rstrip(b'\0').decode(),
                    address=address, bytes=length, offset=offset, alignment=alignment,
                    flags=hex(section_flags), zeroFill=zero, sha256=None if zero else sha(content)))
        elif command == 0x1b:
            record['uuid'] = str(uuid.UUID(bytes=raw[8:24]))
        elif command == 2:
            symtab = struct.unpack_from('<4I', raw, 8)
            record['symbolTable'] = dict(zip(['offset', 'count', 'stringsOffset', 'stringsBytes'], symtab))
        elif command in (0xc, 0xd, 0x18, 0x1f, 0x20, 0x80000018, 0x8000001f, 0x80000023):
            name, timestamp, current, compatibility = struct.unpack_from('<4I', raw, 8)
            record.update(name=cstr(raw, name, size), timestamp=timestamp,
                          currentVersion=hex(current), compatibilityVersion=hex(compatibility))
        elif command == 0x8000001c:
            record['path'] = cstr(raw, struct.unpack_from('<I', raw, 8)[0], size)
        elif command == 0x32:
            platform, minimum, sdk, tools = struct.unpack_from('<4I', raw, 8)
            record.update(platform=platform, minimumOS=hex(minimum), sdk=hex(sdk),
                          tools=[struct.unpack_from('<II', raw, 24 + i * 8) for i in range(tools)])
        elif command in (0x1d, 0x26, 0x29, 0x80000033, 0x80000034):
            offset, length = struct.unpack_from('<II', raw, 8)
            content = span(data, offset, length)
            record['fileData'] = dict(offset=offset, bytes=length, sha256=sha(content))
            if command == 0x1d:
                magic, total, blobs = struct.unpack_from('>III', content)
                if magic != 0xfade0cc0 or total > length or 12 + 8 * blobs > total:
                    raise ValueError('invalid embedded signature container')
                for i in range(blobs):
                    slot, begin = struct.unpack_from('>II', content, 12 + 8 * i)
                    tag, blob_size = struct.unpack_from('>II', content, begin)
                    blob = span(content, begin, blob_size)
                    if tag == 0xfade0c02:
                        _, _, version, cd_flags, hashes, identifier, special, pages, limit = struct.unpack_from('>9I', blob)
                        result['codeDirectories'].append(dict(slot=slot, version=hex(version),
                            flags=hex(cd_flags), identifier=cstr(blob, identifier, len(blob)),
                            codePages=pages, specialSlots=special, codeLimit=limit,
                            hashSize=blob[36], hashType=blob[37], pageSizeLog2=blob[39],
                            hashesOffset=hashes, sha256=sha(blob)))
        result['loadCommands'].append(record)
        position += size
    if position != 32 + command_bytes:
        raise ValueError('load-command total mismatch')
    if symtab:
        offset, count, strings, string_bytes = symtab
        span(data, strings, string_bytes)
        span(data, offset, count * 16)
        for i in range(count):
            name, typ, section, desc, value = struct.unpack_from('<IBBHQ', data, offset + i * 16)
            result['symbols'].append(dict(name=cstr(data, strings + name, strings + string_bytes),
                type=hex(typ), section=section, descriptor=desc, value=value))
    return data, result


def location(info, offset):
    if offset is None:
        return None
    for command in info['loadCommands']:
        if command['offset'] <= offset < command['offset'] + command['bytes']:
            return dict(region='load command', command=command['command'], index=command['index'])
        payload = command.get('fileData')
        if payload and payload['offset'] <= offset < payload['offset'] + payload['bytes']:
            return dict(region='link-edit data', command=command['command'])
    for section in info['sections']:
        if not section['zeroFill'] and section['offset'] <= offset < section['offset'] + section['bytes']:
            address = section['address'] + offset - section['offset']
            candidates = [s for s in info['symbols'] if s['section'] == section['index']
                          and not int(s['type'], 16) & 0xe0 and s['value'] <= address]
            symbol = max(candidates, key=lambda s: s['value'])['name'] if candidates else None
            return dict(region='section', section=section['name'], symbol=symbol)
    return dict(region='Mach-O header, padding or unclassified link-edit data')


def function_hashes(data, info):
    result = {}
    for section in info['sections']:
        if section['name'] != '__TEXT,__text':
            continue
        symbols = [s for s in info['symbols'] if s['section'] == section['index']
                   and int(s['type'], 16) & 0x0e == 0x0e and not int(s['type'], 16) & 0xe0
                   and section['address'] <= s['value'] < section['address'] + section['bytes']]
        starts = sorted({s['value'] for s in symbols} | {section['address'] + section['bytes']})
        for symbol in symbols:
            end_index = bisect.bisect_right(starts, symbol['value'])
            if end_index < len(starts):
                size = starts[end_index] - symbol['value']
                offset = section['offset'] + symbol['value'] - section['address']
                result[symbol['name']] = dict(bytes=size, sha256=sha(span(data, offset, size)))
    return result


def compare(left, right, directory):
    directory.mkdir(parents=True, exist_ok=True)
    a, ai = inventory(left)
    b, bi = inventory(right)
    for label, info in [('published', ai), ('rebuilt', bi)]:
        (directory / (label + '.macho.json')).write_text(json.dumps(info, indent=2) + '\n')
    equal = a == b
    offset = None if equal else next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    sa = {s['name']: s for s in ai['sections']}
    sb = {s['name']: s for s in bi['sections']}
    sections = [dict(name=name, published=sa.get(name), rebuilt=sb.get(name))
                for name in sorted(sa.keys() | sb.keys()) if sa.get(name) != sb.get(name)]
    fa, fb = function_hashes(a, ai), function_hashes(b, bi)
    functions = [dict(name=name, published=fa.get(name), rebuilt=fb.get(name))
                 for name in sorted(fa.keys() | fb.keys()) if fa.get(name) != fb.get(name)]
    cmp_status = subprocess.run(['cmp', '-s', str(left), str(right)]).returncode
    if cmp_status not in (0, 1) or (cmp_status == 0) != equal:
        raise RuntimeError(f'cmp disagrees with byte comparison: {cmp_status}')
    report = dict(rawEqual=equal, cmpStatus=cmp_status, publishedSha256=ai['sha256'],
                  rebuiltSha256=bi['sha256'], firstDifferentByte=offset,
                  publishedLocation=location(ai, offset), rebuiltLocation=location(bi, offset),
                  differentSections=sections, differentFunctionCount=len(functions),
                  firstDifferentFunctions=functions[:20],
                  publishedCodeDirectories=ai['codeDirectories'], rebuiltCodeDirectories=bi['codeDirectories'])
    (directory / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    return 0 if equal else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('published', type=Path)
    parser.add_argument('rebuilt', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    raise SystemExit(compare(args.published, args.rebuilt, args.report))
