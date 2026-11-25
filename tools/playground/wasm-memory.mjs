const header = Uint8Array.of(0, 97, 115, 109, 1, 0, 0, 0);
const encoder = new TextEncoder();
const memoryImport = Uint8Array.of(3, ...encoder.encode("env"), 6, ...encoder.encode("memory"), 2);

function readU32(bytes, position) {
    let value = 0;
    for (let shift = 0; shift <= 28; shift += 7) {
        const byte = bytes[position.offset++];
        if (byte === undefined || (shift === 28 && byte > 15)) {
            throw new Error("Invalid Wasm unsigned integer");
        }
        value += (byte & 127) * 2 ** shift;
        if (byte < 128) return value;
    }
}

function u32(value) {
    const bytes = [];
    do {
        const digit = value % 128;
        value = Math.floor(value / 128);
        bytes.push(digit | (value === 0 ? 0 : 128));
    } while (value !== 0);
    return bytes;
}

function join(chunks) {
    const bytes = new Uint8Array(chunks.reduce((sum, part) => sum + part.length, 0));
    let offset = 0;
    for (const part of chunks) {
        bytes.set(part, offset);
        offset += part.length;
    }
    return bytes;
}

// wasm-ld emits one defined linear memory. Move it to env.memory with index
// zero, preserving the code, data segments and memory export.
export function withBoundedMemory(binary, cap, allowedSections) {
    const bytes = new Uint8Array(binary);
    if (!header.every((byte, index) => bytes[index] === byte)) throw new Error("Invalid Wasm header");
    const sections = [];
    const position = { offset: header.length };
    let imports;
    let memory;
    while (position.offset < bytes.length) {
        const start = position.offset;
        const id = bytes[position.offset++];
        if (allowedSections && !allowedSections.has(id)) throw new Error("Unexpected Wasm section");
        const size = readU32(bytes, position);
        const end = position.offset + size;
        if (end > bytes.length) throw new Error("Truncated Wasm section");
        const payload = bytes.subarray(position.offset, end);
        if (id === 2) {
            if (imports) throw new Error("Duplicate Wasm import section");
            imports = payload;
        }
        if (id === 5) {
            if (memory) throw new Error("Duplicate Wasm memory section");
            memory = payload;
        }
        sections.push({ id, bytes: bytes.subarray(start, end) });
        position.offset = end;
    }
    if (!memory) throw new Error("Expected one defined Wasm memory");
    const cursor = { offset: 0 };
    const count = readU32(memory, cursor);
    const flags = readU32(memory, cursor);
    if (count !== 1 || flags > 1) throw new Error("Expected one unshared wasm32 memory");
    const initial = readU32(memory, cursor);
    const declaredMaximum = flags === 1 ? readU32(memory, cursor) : 65536;
    if (memory.length !== cursor.offset || initial > declaredMaximum || declaredMaximum > 65536) {
        throw new Error("Invalid Wasm memory limits");
    }
    const maximum = Math.min(cap, declaredMaximum);
    if (initial > maximum) throw new Error("memory-limit");
    cursor.offset = 0;
    const importCount = imports ? readU32(imports, cursor) : 0;
    const payload = join([
        u32(importCount + 1), imports?.subarray(cursor.offset) ?? [],
        memoryImport, [1], u32(initial), u32(maximum),
    ]);
    const importSection = join([[2], u32(payload.length), payload]);
    const result = [header];
    let pendingImport = true;
    for (const section of sections) {
        if (pendingImport && section.id >= 2) {
            result.push(importSection);
            pendingImport = false;
        }
        if (section.id !== 2 && section.id !== 5) result.push(section.bytes);
    }
    return { binary: join(result), initial, maximum };
}
