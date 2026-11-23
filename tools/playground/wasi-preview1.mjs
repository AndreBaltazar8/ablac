// The Preview 1 calls used by the Abla command runtime.
const errno = {
    badf: 8, exist: 20, fault: 21, inval: 28, isdir: 31, mfile: 33,
    nametoolong: 37, noent: 44, nospc: 51, notdir: 54, notcapable: 76,
};
const encoder = new TextEncoder();
const pathDecoder = new TextDecoder("utf-8", { fatal: true });

class WasiError extends Error {
    constructor(name) {
        super(`WASI ${name}`);
        this.code = errno[name];
    }
}

function fail(code) {
    throw new WasiError(code);
}

function guestPath(name) {
    if (!name) fail("noent");
    if (name.length > 4096) fail("nametoolong");
    if (name.startsWith("/") || name.includes("\0")) fail("notcapable");
    const components = name.split("/");
    if (components.includes("..")) fail("notcapable");
    return components.filter((part) => part && part !== ".").join("/");
}

function parent(path) {
    return path.slice(0, Math.max(0, path.lastIndexOf("/")));
}

function cString(text) {
    if (text.includes("\0")) throw new Error("NUL in argument or environment value");
    return encoder.encode(text + "\0");
}

function realTime() {
    return BigInt(Date.now()) * 1000000n;
}

export function wasiHost(memory, request, limits, post) {
    const args = ["program.wasm", ...(request.args ?? [])].map(cString);
    const environment = Object.entries(request.env ?? {}).map(([key, value]) => {
        if (!key || key.includes("=")) throw new Error("Invalid environment name");
        return cString(`${key}=${value}`);
    });
    const stdin = encoder.encode(request.stdin ?? "");
    const fds = new Map([
        [0, { stdin: true, offset: 0 }],
        [1, { output: "stdout", decoder: new TextDecoder() }],
        [2, { output: "stderr", decoder: new TextDecoder() }],
        [3, { preopen: true }],
    ]);
    const quota = Math.min(limits.memoryPages * 65536, 8 * 1024 * 1024);
    let fileBytes = 0;
    let outputBytes = 0;
    let nextInode = 1;
    const paths = new Map();

    function create(path, directory) {
        if (paths.size >= 4096) fail("nospc");
        const entry = { directory, data: new Uint8Array(0), changed: realTime(), inode: nextInode++ };
        paths.set(path, entry);
        return entry;
    }

    function resize(entry, length) {
        const nextSize = fileBytes - entry.data.length + length;
        if (nextSize > quota) fail("nospc");
        const data = new Uint8Array(length);
        data.set(entry.data.subarray(0, length));
        entry.data = data;
        fileBytes = nextSize;
    }

    function directory(path) {
        const entry = paths.get(path);
        if (!entry) fail("noent");
        if (!entry.directory) fail("notdir");
    }

    create("", true);
    for (const [name, text] of Object.entries(request.files ?? {})) {
        const path = guestPath(name);
        if (!path || paths.has(path)) fail("exist");
        let prefix = "";
        for (const component of parent(path).split("/").filter(Boolean)) {
            prefix = prefix ? `${prefix}/${component}` : component;
            if (!paths.has(prefix)) create(prefix, true);
            directory(prefix);
        }
        const data = encoder.encode(text);
        const file = create(path, false);
        resize(file, data.length);
        file.data.set(data);
    }

    function bytes(address, length) {
        const offset = address >>> 0;
        const buffer = memory.buffer;
        if (offset + length > buffer.byteLength) fail("fault");
        return new Uint8Array(buffer, offset, length);
    }

    function view(address, size) {
        const region = bytes(address, size);
        return new DataView(region.buffer, region.byteOffset, region.length);
    }

    function putSize(address, value) {
        view(address, 4).setUint32(0, value, true);
    }

    function sizes(values, count, length) {
        putSize(count, values.length);
        putSize(length, values.reduce((sum, value) => sum + value.length, 0));
    }

    function vector(values, address, start) {
        const pointers = view(address, values.length * 4);
        const strings = bytes(start, values.reduce((sum, value) => sum + value.length, 0));
        let offset = 0;
        for (const [index, value] of values.entries()) {
            pointers.setUint32(index * 4, strings.byteOffset + offset, true);
            strings.set(value, offset);
            offset += value.length;
        }
    }

    function descriptor(fd) {
        const entry = fds.get(fd);
        if (!entry) fail("badf");
        return entry;
    }

    function relativeTo(fd, address, length) {
        if (!descriptor(fd).preopen) fail("notdir");
        const size = length >>> 0;
        if (size > 4096) fail("nametoolong");
        const name = bytes(address, size);
        let decoded;
        try {
            decoded = pathDecoder.decode(name);
        } catch {
            fail("inval");
        }
        return guestPath(decoded);
    }

    function opened(fd, lookup, address, length, flags, rights, inherit, fdflags, result) {
        if ((lookup & ~1) || (flags & ~13) || (fdflags & ~1) || (rights & ~66n) || inherit) fail("inval");
        const writable = (rights & 64n) !== 0n;
        if ((flags & 8) && !writable) fail("notcapable");
        const path = relativeTo(fd, address, length);
        const slot = view(result, 4);
        let id = 4;
        while (fds.has(id)) id += 1;
        if (id >= 256) fail("mfile");
        let file = paths.get(path);
        if (file) {
            if (file.directory) fail("isdir");
            if ((flags & 5) === 5) fail("exist");
        } else {
            if (!(flags & 1)) fail("noent");
            directory(parent(path));
            file = create(path, false);
        }
        if (flags & 8) {
            resize(file, 0);
            file.changed = realTime();
        }
        fds.set(id, { file, offset: 0, readable: (rights & 2n) !== 0n, writable, append: Boolean(fdflags & 1) });
        slot.setUint32(0, id, true);
    }

    function filestat(fd, lookup, address, length, result) {
        if (lookup & ~1) fail("inval");
        const entry = paths.get(relativeTo(fd, address, length));
        if (!entry) fail("noent");
        bytes(result, 64).fill(0);
        const stat = view(result, 64);
        stat.setBigUint64(8, BigInt(entry.inode), true);
        stat.setUint8(16, entry.directory ? 3 : 4);
        stat.setBigUint64(24, 1n, true);
        stat.setBigUint64(32, BigInt(entry.data.length), true);
        for (const offset of [40, 48, 56]) stat.setBigUint64(offset, entry.changed, true);
    }

    function read(fd, vectors, count, result) {
        const entry = descriptor(fd);
        if (!entry.stdin && !entry.readable) fail("badf");
        const input = entry.stdin ? stdin : entry.file.data;
        const iovs = view(vectors, (count >>> 0) * 8);
        const written = view(result, 4);
        let actual = 0;
        for (let offset = 0; offset < iovs.byteLength; offset += 8) {
            const target = bytes(iovs.getUint32(offset, true), iovs.getUint32(offset + 4, true));
            const chunk = input.subarray(entry.offset, entry.offset + target.length);
            target.set(chunk);
            entry.offset += chunk.length;
            actual += chunk.length;
            if (chunk.length < target.length) break;
        }
        written.setUint32(0, actual, true);
    }

    function write(fd, vectors, count, result) {
        const entry = descriptor(fd);
        if (!entry.output && !entry.writable) fail("badf");
        const iovs = view(vectors, (count >>> 0) * 8);
        const written = view(result, 4);
        let actual = 0;
        for (let offset = 0; offset < iovs.byteLength; offset += 8) {
            const chunk = bytes(iovs.getUint32(offset, true), iovs.getUint32(offset + 4, true));
            if (entry.output) {
                const available = limits.outputBytes - outputBytes;
                const part = chunk.subarray(0, available);
                const text = entry.decoder.decode(part, { stream: true });
                if (text) post({ type: entry.output, text });
                outputBytes += part.length;
                if (part.length < chunk.length) throw new Error("output-limit");
            } else {
                const file = entry.file;
                const start = entry.append ? file.data.length : entry.offset;
                const end = start + chunk.length;
                if (end > file.data.length) {
                    if (fileBytes - file.data.length + end > quota && actual > 0) break;
                    resize(file, end);
                }
                file.data.set(chunk, start);
                entry.offset = end;
                file.changed = realTime();
            }
            actual += chunk.length;
        }
        written.setUint32(0, actual, true);
    }

    function call(fn) {
        return (...params) => {
            try {
                fn(...params);
                return 0;
            } catch (error) {
                if (error instanceof WasiError) return error.code;
                throw error;
            }
        };
    }

    const procExit = {};
    let status;
    const output = [fds.get(1), fds.get(2)];
    const imports = {
        args_sizes_get: call((count, size) => sizes(args, count, size)),
        args_get: call((argv, strings) => vector(args, argv, strings)),
        environ_sizes_get: call((count, size) => sizes(environment, count, size)),
        environ_get: call((envp, strings) => vector(environment, envp, strings)),
        fd_read: call(read),
        fd_write: call(write),
        fd_close: call((fd) => { if (!fds.delete(fd)) fail("badf"); }),
        fd_prestat_get: call((fd, result) => {
            if (!descriptor(fd).preopen) fail("badf");
            const stat = view(result, 8);
            stat.setUint32(0, 0, true);
            stat.setUint32(4, 1, true);
        }),
        fd_prestat_dir_name: call((fd, address, length) => {
            if (!descriptor(fd).preopen) fail("badf");
            if ((length >>> 0) < 1) fail("nametoolong");
            bytes(address, 1)[0] = 46;
        }),
        path_open: call(opened),
        path_filestat_get: call(filestat),
        path_create_directory: call((fd, address, length) => {
            const path = relativeTo(fd, address, length);
            if (paths.has(path)) fail("exist");
            directory(parent(path));
            create(path, true);
        }),
        proc_exit: (code) => {
            status = code >>> 0;
            throw procExit;
        },
        clock_time_get: call((clock, _precision, address) => {
            if (clock !== 0 && clock !== 1) fail("inval");
            const value = clock === 0 ? realTime() : BigInt(Math.floor(performance.now() * 1e6));
            view(address, 8).setBigUint64(0, value, true);
        }),
        random_get: call((data, size) => {
            const target = bytes(data, size >>> 0);
            for (let offset = 0; offset < target.length; offset += 65536) {
                crypto.getRandomValues(target.subarray(offset, offset + 65536));
            }
        }),
    };
    return {
        imports,
        exit(error) {
            if (error === procExit) return { type: "exit", code: status };
            return { type: "exit", trap: error.message || String(error) };
        },
        flush() {
            for (const entry of output) {
                const text = entry.decoder.decode();
                if (text) post({ type: entry.output, text });
            }
        },
    };
}
