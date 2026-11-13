// Test-only ELF32 Xtensa comparison; mask only relocated L32R immediates. The digests are of canonical JSON, built to
// agree byte for byte with the values recorded in tests/cases/xtensa-routing/firmware-reference.json.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';

// Python's json.dumps: default separators (", " and ": ") for the sort key, compact for the digest.
const dumps = (value, compact) => {
    if (Array.isArray(value)) return '[' + value.map((v) => dumps(v, compact)).join(compact ? ',' : ', ') + ']';
    if (value !== null && typeof value === 'object') {
        return '{' + Object.keys(value).sort().map((k) => JSON.stringify(k) + (compact ? ':' : ': ') + dumps(value[k], compact)).join(compact ? ',' : ', ') + '}';
    }
    return JSON.stringify(value);
};
const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const digest = (value) => sha256(Buffer.from(dumps(value, true)));
// Python's ordering of tuples of strings and integers.
const compare = (a, b) => {
    if (Array.isArray(a) && Array.isArray(b)) {
        for (let i = 0; i < Math.min(a.length, b.length); i++) {
            const c = compare(a[i], b[i]);
            if (c) return c;
        }
        return a.length - b.length;
    }
    assert.equal(typeof a, typeof b, 'cannot order a string against a number');
    return a < b ? -1 : a > b ? 1 : 0;
};

export function fingerprint(raw, controls = false) {
    assert.ok(raw.subarray(0, 7).equals(Buffer.from([0x7f, 0x45, 0x4c, 0x46, 1, 1, 1])));
    assert.equal(raw.readUInt16LE(16), 1, 'not a relocatable object');
    assert.equal(raw.readUInt16LE(18), 94, 'not Xtensa');
    const offset = raw.readUInt32LE(32);
    const width = raw.readUInt16LE(46), count = raw.readUInt16LE(48), namesIndex = raw.readUInt16LE(50);
    assert.ok(width === 40 && offset + width * count <= raw.length);
    const headers = Array.from({ length: count }, (_, i) => Array.from({ length: 10 }, (_, k) => raw.readUInt32LE(offset + i * width + k * 4)));

    const data = (header) => {
        assert.ok(header[4] + header[5] <= raw.length || header[1] === 8);
        return header[1] !== 8 ? raw.subarray(header[4], header[4] + header[5]) : Buffer.alloc(0);
    };
    const string = (table, index) => {
        assert.ok(index < table.length);
        const end = table.indexOf(0, index);
        return table.subarray(index, end < 0 ? table.length : end).toString('utf8');
    };

    const names = headers.map((h) => string(data(headers[namesIndex]), h[0]));
    const symbols = {};
    headers.forEach((h, i) => {
        if (h[1] !== 2) return;
        assert.ok(h[9] === 16 && h[5] % 16 === 0);
        const strings = data(headers[h[6]]);
        const entries = [];
        for (let pos = h[4]; pos < h[4] + h[5]; pos += 16) {
            const name = raw.readUInt32LE(pos), value = raw.readUInt32LE(pos + 4), size = raw.readUInt32LE(pos + 8);
            const info = raw[pos + 12], other = raw[pos + 13], section = raw.readUInt16LE(pos + 14);
            const target = section < count ? names[section] : section;
            const text = (info & 15) === 3 ? target : string(strings, name);
            entries.push([text, value, size, info, other, target]);
        }
        symbols[i] = entries;
    });
    const allocated = {};
    headers.forEach((h, i) => { if (h[2] & 2) allocated[i] = Buffer.from(data(h)); });
    const relocations = [], masked = [];
    let firstRelocation = null;
    for (const h of headers) {
        if (h[1] !== 4 || !(h[7] in allocated)) continue;
        assert.ok(h[9] === 12 && h[5] % 12 === 0);
        for (let pos = h[4]; pos < h[4] + h[5]; pos += 12) {
            const address = raw.readUInt32LE(pos), info = raw.readUInt32LE(pos + 4), addend = raw.readInt32LE(pos + 8);
            const kind = info & 255, index = info >>> 8;
            relocations.push([names[h[7]], address, kind, symbols[h[6]][index], addend]);
            if (firstRelocation === null) firstRelocation = pos;
            const body = allocated[h[7]];
            // R_XTENSA_SLOT0_OP overwrites the L32R's 16-bit immediate. Do not mask its opcode/register byte, other
            // instructions, or any unrelocated fields. RELA addends remain part of the digest.
            if (kind === 20 && address + 3 <= body.length && (body[address] & 15) === 1) {
                body[address + 1] = 0;
                body[address + 2] = 0;
                masked.push(headers[h[7]][4] + address + 1);
            }
        }
    }
    const sections = Object.keys(allocated).map(Number).sort((a, b) => a - b)
        .map((i) => [names[i], headers[i][1], headers[i][2], headers[i][5], headers[i][8], headers[i][9], sha256(allocated[i])])
        .sort(compare);
    const entries = Object.values(symbols).flat();
    const result = {
        schema: 1, elfFlags: raw.readUInt32LE(36), allocatedSections: sections.length, normalizedRelocations: relocations.length,
        maskedL32rFields: masked.length, sectionsSha256: digest(sections),
        symbolsSha256: digest(entries.slice().sort((a, b) => { const x = dumps(a, false), y = dumps(b, false); return x < y ? -1 : x > y ? 1 : 0; })),
        relocationsSha256: digest(relocations.slice().sort(compare)),
    };
    if (controls) {
        // A placeholder mutation is equivalent; a real opcode or RELA-addend mutation must fail. These run on the actual
        // gate object, not a mock.
        assert.ok(masked.length && firstRelocation !== null);
        let changed = Buffer.from(raw);
        changed[masked[0]] ^= 85;
        assert.deepEqual(fingerprint(changed), result);
        changed = Buffer.from(raw);
        changed[masked[0] - 1] ^= 16; // Register nibble, never relocated.
        assert.notEqual(fingerprint(changed).sectionsSha256, result.sectionsSha256);
        changed = Buffer.from(raw);
        changed[firstRelocation + 8] ^= 1;
        assert.notEqual(fingerprint(changed).relocationsSha256, result.relocationsSha256);
    }
    return result;
}
