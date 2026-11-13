// Strict byte comparison with diagnostic-only thin 64-bit Mach-O inventories.
//
// Nothing is stripped, re-signed, normalized or accepted as an exception. A mismatch always exits 1. Formats follow
// Apple's loader.h and cs_blobs.h:
// https://github.com/apple-oss-distributions/cctools/blob/main/include/mach-o/loader.h
// https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/cs_blobs.h
//
// node tools/compare-macos-binaries.mjs PUBLISHED REBUILT REPORT_DIRECTORY
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { pathToFileURL } from 'node:url';

const sha = (data) => createHash('sha256').update(data).digest('hex');
const hex = (n) => '0x' + n.toString(16);

function cstr(data, start, end) {
    if (!(start >= 0 && start < end && end <= data.length)) throw new Error('string offset outside its container');
    const stop = data.indexOf(0, start);
    if (stop < 0 || stop >= end) throw new Error('subsection not found');
    return data.subarray(start, stop).toString('utf8');
}

function span(data, offset, size) {
    if (offset < 0 || size < 0 || offset + size > data.length) throw new Error(`file range outside image: ${offset}+${size}`);
    return data.subarray(offset, offset + size);
}
const trimmed = (buffer) => { let end = buffer.length; while (end > 0 && buffer[end - 1] === 0) end--; return buffer.subarray(0, end).toString('utf8'); };
const uuidText = (b) => { const h = b.toString('hex'); return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`; };

export function inventory(file) {
    const data = fs.readFileSync(file);
    if (data.length < 32 || data.readUInt32LE(0) !== 0xfeedfacf) throw new Error('expected a thin little-endian 64-bit Mach-O image');
    const [, cpu, subtype, kind, count, commandBytes, flags, reserved] = Array.from({ length: 8 }, (_, i) => data.readUInt32LE(i * 4));
    span(data, 32, commandBytes);
    const result = {
        path: String(file), bytes: data.length, sha256: sha(data),
        header: { cpu, subtype, filetype: kind, flags, commands: count, commandBytes, reserved },
        loadCommands: [], sections: [], symbols: [], codeDirectories: [],
    };
    let position = 32;
    let symtab = null;
    for (let index = 0; index < count; index++) {
        const command = data.readUInt32LE(position), size = data.readUInt32LE(position + 4);
        if (size < 8 || position + size > 32 + commandBytes) throw new Error('invalid load-command size');
        const raw = span(data, position, size);
        const record = { index, command: hex(command), offset: position, bytes: size, sha256: sha(raw) };
        if (command === 0x19) {
            record.segment = trimmed(raw.subarray(8, 24));
            const nsects = raw.readUInt32LE(64);
            if (72 + nsects * 80 > size) throw new Error('invalid segment section count');
            for (let sectionId = 0; sectionId < nsects; sectionId++) {
                const at = 72 + sectionId * 80;
                const name = raw.subarray(at, at + 16), segment = raw.subarray(at + 16, at + 32);
                const address = raw.readBigUInt64LE(at + 32), length = raw.readBigUInt64LE(at + 40);
                const offset = raw.readUInt32LE(at + 48), alignment = raw.readUInt32LE(at + 52), sectionFlags = raw.readUInt32LE(at + 64);
                const zero = [1, 0xc, 0x12].includes(sectionFlags & 0xff);
                const content = zero ? Buffer.alloc(0) : span(data, offset, Number(length));
                result.sections.push({
                    index: result.sections.length + 1, name: trimmed(segment) + ',' + trimmed(name), address, bytes: length, offset, alignment,
                    flags: hex(sectionFlags), zeroFill: zero, sha256: zero ? null : sha(content),
                });
            }
        } else if (command === 0x1b) {
            record.uuid = uuidText(raw.subarray(8, 24));
        } else if (command === 2) {
            symtab = [0, 1, 2, 3].map((i) => raw.readUInt32LE(8 + i * 4));
            record.symbolTable = { offset: symtab[0], count: symtab[1], stringsOffset: symtab[2], stringsBytes: symtab[3] };
        } else if ([0xc, 0xd, 0x18, 0x1f, 0x20, 0x80000018, 0x8000001f, 0x80000023].includes(command)) {
            const [name, timestamp, current, compatibility] = [0, 1, 2, 3].map((i) => raw.readUInt32LE(8 + i * 4));
            Object.assign(record, { name: cstr(raw, name, size), timestamp, currentVersion: hex(current), compatibilityVersion: hex(compatibility) });
        } else if (command === 0x8000001c) {
            record.path = cstr(raw, raw.readUInt32LE(8), size);
        } else if (command === 0x32) {
            const [platform, minimum, sdk, tools] = [0, 1, 2, 3].map((i) => raw.readUInt32LE(8 + i * 4));
            Object.assign(record, {
                platform, minimumOS: hex(minimum), sdk: hex(sdk),
                tools: Array.from({ length: tools }, (_, i) => [raw.readUInt32LE(24 + i * 8), raw.readUInt32LE(28 + i * 8)]),
            });
        } else if ([0x1d, 0x26, 0x29, 0x80000033, 0x80000034].includes(command)) {
            const offset = raw.readUInt32LE(8), length = raw.readUInt32LE(12);
            const content = span(data, offset, length);
            record.fileData = { offset, bytes: length, sha256: sha(content) };
            if (command === 0x1d) {
                const magic = content.readUInt32BE(0), total = content.readUInt32BE(4), blobs = content.readUInt32BE(8);
                if (magic !== 0xfade0cc0 || total > length || 12 + 8 * blobs > total) throw new Error('invalid embedded signature container');
                for (let i = 0; i < blobs; i++) {
                    const slot = content.readUInt32BE(12 + 8 * i), begin = content.readUInt32BE(16 + 8 * i);
                    const tag = content.readUInt32BE(begin), blobSize = content.readUInt32BE(begin + 4);
                    const blob = span(content, begin, blobSize);
                    if (tag === 0xfade0c02) {
                        const word = (n) => blob.readUInt32BE(n * 4);
                        const [version, cdFlags, hashes, identifier, special, pages, limit] = [2, 3, 4, 5, 6, 7, 8].map(word);
                        result.codeDirectories.push({
                            slot, version: hex(version), flags: hex(cdFlags), identifier: cstr(blob, identifier, blob.length), codePages: pages,
                            specialSlots: special, codeLimit: limit, hashSize: blob[36], hashType: blob[37], pageSizeLog2: blob[39], hashesOffset: hashes, sha256: sha(blob),
                        });
                    }
                }
            }
        }
        result.loadCommands.push(record);
        position += size;
    }
    if (position !== 32 + commandBytes) throw new Error('load-command total mismatch');
    if (symtab) {
        const [offset, symbolCount, strings, stringBytes] = symtab;
        span(data, strings, stringBytes);
        span(data, offset, symbolCount * 16);
        for (let i = 0; i < symbolCount; i++) {
            const at = offset + i * 16;
            const name = data.readUInt32LE(at), type = data[at + 4], section = data[at + 5], descriptor = data.readUInt16LE(at + 6), value = data.readBigUInt64LE(at + 8);
            result.symbols.push({ name: cstr(data, strings + name, strings + stringBytes), type: hex(type), section, descriptor, value });
        }
    }
    return [data, result];
}

const typeOf = (symbol) => parseInt(symbol.type, 16);

function location(info, offset) {
    if (offset === null) return null;
    for (const command of info.loadCommands) {
        if (command.offset <= offset && offset < command.offset + command.bytes) return { region: 'load command', command: command.command, index: command.index };
        const payload = command.fileData;
        if (payload && payload.offset <= offset && offset < payload.offset + payload.bytes) return { region: 'link-edit data', command: command.command };
    }
    for (const section of info.sections) {
        if (!section.zeroFill && section.offset <= offset && BigInt(offset) < BigInt(section.offset) + section.bytes) {
            const address = section.address + BigInt(offset - section.offset);
            const candidates = info.symbols.filter((s) => s.section === section.index && !(typeOf(s) & 0xe0) && s.value <= address);
            let best = null;
            for (const s of candidates) if (best === null || s.value > best.value) best = s;
            return { region: 'section', section: section.name, symbol: best ? best.name : null };
        }
    }
    return { region: 'Mach-O header, padding or unclassified link-edit data' };
}

function functionHashes(data, info) {
    const result = {};
    for (const section of info.sections) {
        if (section.name !== '__TEXT,__text') continue;
        const symbols = info.symbols.filter((s) => s.section === section.index && (typeOf(s) & 0x0e) === 0x0e && !(typeOf(s) & 0xe0)
            && section.address <= s.value && s.value < section.address + section.bytes);
        const starts = [...new Set([...symbols.map((s) => s.value), section.address + section.bytes])].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
        for (const symbol of symbols) {
            // bisect_right: the first start after the symbol.
            const endIndex = starts.findIndex((v) => v > symbol.value);
            if (endIndex >= 0) {
                const size = Number(starts[endIndex] - symbol.value);
                const offset = section.offset + Number(symbol.value - section.address);
                result[symbol.name] = { bytes: size, sha256: sha(span(data, offset, size)) };
            }
        }
    }
    return result;
}

// Python's json.dumps(indent=2): ASCII-only text, one item per line, big integers as written.
export function dumps(value, indent = 0) {
    const pad = ' '.repeat(indent + 2), close = ' '.repeat(indent);
    if (value === null) return 'null';
    if (typeof value === 'bigint') return value.toString();
    if (typeof value === 'string') return JSON.stringify(value).replace(/[\u0080-￿]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
    if (typeof value !== 'object') return JSON.stringify(value);
    if (Array.isArray(value)) return value.length ? '[\n' + value.map((v) => pad + dumps(v, indent + 2)).join(',\n') + '\n' + close + ']' : '[]';
    const keys = Object.keys(value);
    return keys.length ? '{\n' + keys.map((k) => `${pad}${dumps(k)}: ${dumps(value[k], indent + 2)}`).join(',\n') + '\n' + close + '}' : '{}';
}

export function compare(left, right, directory, { quiet = false } = {}) {
    fs.mkdirSync(directory, { recursive: true });
    const [a, ai] = inventory(left);
    const [b, bi] = inventory(right);
    for (const [label, info] of [['published', ai], ['rebuilt', bi]]) fs.writeFileSync(path.join(directory, label + '.macho.json'), dumps(info) + '\n');
    const equal = a.equals(b);
    let offset = null;
    if (!equal) {
        offset = 0;
        while (offset < Math.min(a.length, b.length) && a[offset] === b[offset]) offset++;
    }
    const sa = new Map(ai.sections.map((s) => [s.name, s])), sb = new Map(bi.sections.map((s) => [s.name, s]));
    const sections = [...new Set([...sa.keys(), ...sb.keys()])].sort()
        .filter((name) => !isDeepStrictEqual(sa.get(name), sb.get(name))).map((name) => ({ name, published: sa.get(name) ?? null, rebuilt: sb.get(name) ?? null }));
    const fa = functionHashes(a, ai), fb = functionHashes(b, bi);
    const functions = [...new Set([...Object.keys(fa), ...Object.keys(fb)])].sort()
        .filter((name) => !isDeepStrictEqual(fa[name], fb[name])).map((name) => ({ name, published: fa[name] ?? null, rebuilt: fb[name] ?? null }));
    const cmpStatus = spawnSync('cmp', ['-s', String(left), String(right)]).status;
    if (![0, 1].includes(cmpStatus) || (cmpStatus === 0) !== equal) throw new Error(`cmp disagrees with byte comparison: ${cmpStatus}`);
    const report = {
        rawEqual: equal, cmpStatus, publishedSha256: ai.sha256, rebuiltSha256: bi.sha256, firstDifferentByte: offset,
        publishedLocation: location(ai, offset), rebuiltLocation: location(bi, offset), differentSections: sections, differentFunctionCount: functions.length,
        firstDifferentFunctions: functions.slice(0, 20), publishedCodeDirectories: ai.codeDirectories, rebuiltCodeDirectories: bi.codeDirectories,
    };
    fs.writeFileSync(path.join(directory, 'comparison.json'), dumps(report) + '\n');
    if (!quiet) console.log(dumps(report));
    return equal ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    const [published, rebuilt, report] = process.argv.slice(2);
    if (!published || !rebuilt || !report) { console.error('usage: compare-macos-binaries.mjs PUBLISHED REBUILT REPORT_DIRECTORY'); process.exit(2); }
    try { process.exit(compare(published, rebuilt, report)); } catch (error) { console.error(error.message); process.exit(1); }
}
