// An in-memory file system for the compiler running in a page, and the Linux system calls over it that the compiler's
// standard library makes (open, read, write, stat, directory listing, rename, unlink). The stdlib is a read-only base
// (a map from absolute path to bytes); every write lands in an overlay, so one base serves many compilations.
// Paths are POSIX and absolute; a relative path is read against the working directory ("/").
const ENOENT = 2, EIO = 5, EBADF = 9, EEXIST = 17, ENOTDIR = 20, EISDIR = 21, EINVAL = 22, ENOTEMPTY = 39, ENOSYS = 38;
const O_WRONLY = 1, O_RDWR = 2, O_CREAT = 0o100, O_EXCL = 0o200, O_TRUNC = 0o1000, O_APPEND = 0o2000, O_DIRECTORY = 0o200000;
const AT_FDCWD = -100;
// The most one file of the overlay may hold: a write or truncate past it fails (EIO / EINVAL) instead of allocating what the guest names.
const maximumFileBytes = 64 * 1048576;

const normalize = (path) => {
    const parts = [];
    for (const part of path.split("/")) {
        if (part === "" || part === ".") continue;
        if (part === "..") parts.pop();
        else parts.push(part);
    }
    return "/" + parts.join("/");
};
const parentOf = (path) => (path === "/" ? "/" : normalize(path.slice(0, path.lastIndexOf("/")) || "/"));

export class Vfs {
    // `base`: Map<absolute path, Uint8Array> (files only; directories are implied by the paths).
    constructor(base = new Map()) {
        this.base = base;
        this.files = new Map(); // overlay files: path -> { data: Uint8Array, mtime }
        this.directories = new Set(["/"]); // overlay directories
        this.removed = new Set(); // base paths deleted
        this.baseDirectories = new Set(["/"]);
        for (const path of base.keys()) {
            for (let parent = parentOf(path); !this.baseDirectories.has(parent); parent = parentOf(parent)) this.baseDirectories.add(parent);
        }
        this.baseChildren = new Map();
        for (const path of [...base.keys(), ...[...this.baseDirectories].filter((d) => d !== "/")]) this.#link(this.baseChildren, path);
        this.clock = () => Date.now();
    }
    #link(map, path) {
        const parent = parentOf(path);
        if (!map.has(parent)) map.set(parent, new Set());
        map.get(parent).add(path.slice(path.lastIndexOf("/") + 1));
    }
    kind(path) {
        if (this.files.has(path)) return "file";
        if (this.directories.has(path)) return "directory";
        if (this.removed.has(path)) return null;
        if (this.base.has(path)) return "file";
        if (this.baseDirectories.has(path)) return "directory";
        return null;
    }
    read(path) {
        if (this.files.has(path)) return this.files.get(path).data;
        if (!this.removed.has(path) && this.base.has(path)) return this.base.get(path);
        return null;
    }
    put(path, data) {
        this.files.set(path, { data, mtime: this.clock() });
        this.removed.delete(path);
        for (let parent = parentOf(path); !this.directories.has(parent); parent = parentOf(parent)) this.directories.add(parent);
    }
    list(path) {
        const names = new Set();
        if (this.baseChildren.has(path)) {
            for (const name of this.baseChildren.get(path)) if (!this.removed.has(path === "/" ? "/" + name : `${path}/${name}`)) names.add(name);
        }
        const prefix = path === "/" ? "/" : path + "/";
        for (const entries of [this.files.keys(), this.directories]) {
            for (const other of entries) {
                if (other.startsWith(prefix) && other !== path) names.add(other.slice(prefix.length).split("/")[0]);
            }
        }
        return [...names].sort();
    }
    remove(path) {
        this.files.delete(path);
        this.directories.delete(path);
        if (this.base.has(path)) this.removed.add(path);
    }
    // The text of a file the compiler wrote (an output).
    text(path) {
        const data = this.read(path);
        return data === null ? null : new TextDecoder().decode(data);
    }
}

// The system-call adapter: `memory()` returns the guest's WebAssembly.Memory. `syscall(number, a0..a5)` takes and returns BigInt.
export function createSyscalls(vfs, memory, options = {}) {
    const decoder = new TextDecoder();
    // A guest address is 32 bits; one above 2 GB arrives sign-extended.
    const ptr = (value) => Number(BigInt.asUintN(32, BigInt(value)));
    const descriptors = new Map();
    const stdin = options.stdin ?? new Uint8Array(0);
    let stdinPosition = 0;
    let next = 3;
    let cwd = options.cwd ?? "/";
    const bytes = () => new Uint8Array(memory().buffer);
    const view = () => new DataView(memory().buffer);
    const cstring = (address) => {
        const heap = bytes();
        let end = ptr(address);
        const begin = end;
        while (heap[end] !== 0) end++;
        return decoder.decode(heap.subarray(begin, end));
    };
    const resolve = (directory, path) => normalize(path.startsWith("/") ? path : `${directory}/${path}`);
    const at = (dirfd, path) => {
        if (Number(dirfd) === AT_FDCWD || path.startsWith("/")) return resolve(cwd, path);
        const entry = descriptors.get(Number(dirfd));
        return entry ? resolve(entry.path, path) : null;
    };
    const statBuffer = (address, kind, size, mtimeMs) => {
        const v = view();
        const base = ptr(address);
        for (let i = 0; i < 144; i += 8) v.setBigUint64(base + i, 0n, true);
        v.setBigUint64(base + 16, 1n, true);
        v.setUint32(base + 24, kind === "directory" ? 0o040755 : 0o100644, true);
        v.setBigInt64(base + 48, BigInt(size), true);
        v.setBigInt64(base + 56, 4096n, true);
        v.setBigInt64(base + 88, BigInt(Math.floor(mtimeMs / 1000)), true);
        v.setBigInt64(base + 96, BigInt(Math.floor((mtimeMs % 1000) * 1e6)), true);
        return 0n;
    };
    const statPath = (path, address) => {
        const kind = vfs.kind(path);
        if (kind === null) return -BigInt(ENOENT);
        const data = kind === "file" ? vfs.read(path) : null;
        const mtime = vfs.files.get(path)?.mtime ?? 0;
        return statBuffer(address, kind, data ? data.length : 4096, mtime);
    };
    const open = (path, flags, mode) => {
        if (path === null) return -BigInt(EBADF);
        const kind = vfs.kind(path);
        const write = (flags & (O_WRONLY | O_RDWR)) !== 0;
        if (kind === null) {
            if (!(flags & O_CREAT)) return -BigInt(ENOENT);
            if (vfs.kind(parentOf(path)) !== "directory") return -BigInt(ENOENT);
            vfs.put(path, new Uint8Array(0));
        } else {
            if (flags & O_CREAT && flags & O_EXCL) return -BigInt(EEXIST);
            if (kind === "directory" && write) return -BigInt(EISDIR);
            if (kind === "file" && flags & O_DIRECTORY) return -BigInt(ENOTDIR);
        }
        const isDirectory = vfs.kind(path) === "directory";
        if (!isDirectory && write && (flags & O_TRUNC)) vfs.put(path, new Uint8Array(0));
        else if (!isDirectory && write && !vfs.files.has(path)) vfs.put(path, vfs.read(path).slice());
        const fd = next++;
        descriptors.set(fd, { path, position: 0, write, append: (flags & O_APPEND) !== 0, directory: isDirectory, entries: null });
        return BigInt(fd);
    };
    const writeAt = (entry, address, length, position) => {
        const file = vfs.files.get(entry.path);
        const source = bytes().subarray(ptr(address), ptr(address) + Number(length));
        const end = position + source.length;
        if (!(position >= 0) || end > maximumFileBytes) throw new RangeError("file too large");
        if (end > file.data.length) {
            const larger = new Uint8Array(end);
            larger.set(file.data);
            file.data = larger;
        }
        file.data.set(source, position);
        file.mtime = vfs.clock();
        return BigInt(source.length);
    };
    const unlink = (path, directory) => {
        const kind = vfs.kind(path);
        if (kind === null) return -BigInt(ENOENT);
        if (directory) {
            if (kind !== "directory") return -BigInt(ENOTDIR);
            if (vfs.list(path).length) return -BigInt(ENOTEMPTY);
        } else if (kind === "directory") return -BigInt(EISDIR);
        vfs.remove(path);
        return 0n;
    };
    const rename = (from, to) => {
        const data = vfs.read(from);
        if (data === null) return vfs.kind(from) === "directory" ? -BigInt(ENOSYS) : -BigInt(ENOENT);
        vfs.put(to, data.slice());
        vfs.remove(from);
        return 0n;
    };
    const mkdir = (path) => {
        if (vfs.kind(path) !== null) return -BigInt(EEXIST);
        if (vfs.kind(parentOf(path)) !== "directory") return -BigInt(ENOENT);
        vfs.directories.add(path);
        vfs.removed.delete(path);
        return 0n;
    };
    const getdents = (entry, address, capacity) => {
        if (!entry.directory) return -BigInt(ENOTDIR);
        if (entry.entries === null) entry.entries = [".", "..", ...vfs.list(entry.path)];
        const heap = bytes();
        const v = view();
        let offset = 0;
        while (entry.position < entry.entries.length) {
            const name = entry.entries[entry.position];
            const encoded = new TextEncoder().encode(name);
            const length = (19 + encoded.length + 1 + 7) & ~7;
            if (offset + length > Number(capacity)) break;
            const child = name === "." ? entry.path : name === ".." ? parentOf(entry.path) : resolve(entry.path, name);
            const base = ptr(address) + offset;
            v.setBigUint64(base, 1n, true);
            v.setBigInt64(base + 8, BigInt(entry.position + 1), true);
            v.setUint16(base + 16, length, true);
            heap[base + 18] = vfs.kind(child) === "directory" ? 4 : 8;
            heap.set(encoded, base + 19);
            heap[base + 19 + encoded.length] = 0;
            offset += length;
            entry.position++;
        }
        return BigInt(offset);
    };
    return (number, a0, a1, a2, a3, a4, a5) => {
        number = Number(number);
        try {
            switch (number) {
                case 0: { // read
                    if (Number(a0) === 0) { // standard input: the bytes the page gave
                        const length = Math.min(Number(a2), stdin.length - stdinPosition);
                        bytes().set(stdin.subarray(stdinPosition, stdinPosition + length), ptr(a1));
                        stdinPosition += length;
                        return BigInt(length);
                    }
                    const entry = descriptors.get(Number(a0));
                    if (!entry) return -BigInt(EBADF);
                    if (entry.directory) return -BigInt(EISDIR);
                    const data = vfs.read(entry.path);
                    const length = Math.max(0, Math.min(Number(a2), data.length - entry.position));
                    bytes().set(data.subarray(entry.position, entry.position + length), ptr(a1));
                    entry.position += length;
                    return BigInt(length);
                }
                case 17: { // pread64
                    const entry = descriptors.get(Number(a0));
                    if (!entry) return -BigInt(EBADF);
                    const data = vfs.read(entry.path);
                    const position = Number(a3);
                    const length = Math.max(0, Math.min(Number(a2), data.length - position));
                    bytes().set(data.subarray(position, position + length), ptr(a1));
                    return BigInt(length);
                }
                case 1: { // write to a file this adapter opened (descriptors 1 and 2 are the host's)
                    const entry = descriptors.get(Number(a0));
                    if (!entry || !entry.write) return -BigInt(EBADF);
                    if (entry.append) entry.position = vfs.read(entry.path).length;
                    const written = writeAt(entry, a1, a2, entry.position);
                    entry.position += Number(written);
                    return written;
                }
                case 18: { // pwrite64
                    const entry = descriptors.get(Number(a0));
                    if (!entry || !entry.write) return -BigInt(EBADF);
                    return writeAt(entry, a1, a2, Number(a3));
                }
                case 2: return open(resolve(cwd, cstring(a0)), Number(a1), Number(a2));
                case 257: return open(at(a0, cstring(a1)), Number(a2), Number(a3));
                case 3: return descriptors.delete(Number(a0)) ? 0n : -BigInt(EBADF);
                case 4: case 6: return statPath(resolve(cwd, cstring(a0)), a1);
                case 5: {
                    const entry = descriptors.get(Number(a0));
                    return entry ? statPath(entry.path, a1) : -BigInt(EBADF);
                }
                case 262: {
                    const path = at(a0, cstring(a1));
                    return path === null ? -BigInt(EBADF) : statPath(path, a2);
                }
                case 8: {
                    const entry = descriptors.get(Number(a0));
                    if (!entry) return -BigInt(EBADF);
                    const where = Number(a2);
                    const size = entry.directory ? 0 : vfs.read(entry.path).length;
                    entry.position = where === 0 ? Number(a1) : where === 1 ? entry.position + Number(a1) : size + Number(a1);
                    return BigInt(entry.position);
                }
                case 21: return vfs.kind(resolve(cwd, cstring(a0))) !== null ? 0n : -BigInt(ENOENT);
                case 269: { const path = at(a0, cstring(a1)); return path !== null && vfs.kind(path) !== null ? 0n : -BigInt(ENOENT); }
                case 217: {
                    const entry = descriptors.get(Number(a0));
                    return entry ? getdents(entry, a1, a2) : -BigInt(EBADF);
                }
                case 79: { // getcwd
                    const encoded = new TextEncoder().encode(cwd + "\0");
                    if (encoded.length > Number(a1)) return -34n;
                    bytes().set(encoded, ptr(a0));
                    return BigInt(encoded.length);
                }
                case 80: { const path = resolve(cwd, cstring(a0)); if (vfs.kind(path) !== "directory") return -BigInt(ENOENT); cwd = path; return 0n; }
                case 83: return mkdir(resolve(cwd, cstring(a0)));
                case 258: { const path = at(a0, cstring(a1)); return path === null ? -BigInt(EBADF) : mkdir(path); }
                case 84: return unlink(resolve(cwd, cstring(a0)), true);
                case 87: return unlink(resolve(cwd, cstring(a0)), false);
                case 263: { const path = at(a0, cstring(a1)); return path === null ? -BigInt(EBADF) : unlink(path, (Number(a2) & 0x200) !== 0); }
                case 82: return rename(resolve(cwd, cstring(a0)), resolve(cwd, cstring(a1)));
                case 264: case 316: return rename(at(a0, cstring(a1)), at(a2, cstring(a3)));
                case 77: { // ftruncate
                    const entry = descriptors.get(Number(a0));
                    if (!entry || !entry.write) return -BigInt(EBADF);
                    const file = vfs.files.get(entry.path);
                    if (!(Number(a1) >= 0) || Number(a1) > maximumFileBytes) return -BigInt(EINVAL);
                    const data = new Uint8Array(Number(a1));
                    data.set(file.data.subarray(0, Number(a1)));
                    file.data = data;
                    return 0n;
                }
                case 74: case 75: case 72: return 0n; // fsync, fdatasync, fcntl
                case 39: return 1n; // getpid
                case 89: return -BigInt(EINVAL); // readlink: nothing is a link
                default: options.unknown?.(number);
            }
        } catch (error) {
            options.trace?.(error);
            return -BigInt(EIO);
        }
        return -BigInt(ENOSYS);
    };
}
