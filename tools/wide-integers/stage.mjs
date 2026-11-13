// stage.mjs TYPE FROM TO: copies tests/cases/wide-integers into TO for one of uint256, int256, uint128 and
// int128: `__T__` becomes the type, `__BYTES__` its size, and a line starting @u, @s, @256 or @128 is kept
// (without the tag) only for an unsigned, a signed, a 256-bit or a 128-bit type. `.in` files lose the suffix.
import fs from 'node:fs';
import path from 'node:path';

const [kind, source, target] = process.argv.slice(2, 5);
const signed = kind.startsWith('int');
const bits = Number(kind.slice(-3));
const maxdec = { uint256: 2n ** 256n - 1n, int256: 2n ** 255n - 1n, uint128: 2n ** 128n - 1n, int128: 2n ** 127n - 1n }[kind];
const words = bits === 256 ? 'u32(0), u32(0), u32(0), u32(0), u32(0), u32(0), u32(1), u32(2)' : 'u32(0), u32(0), u32(1), u32(2)';
const edge = bits === 256
    ? 'u32(4294967295), u32(0), u32(305419896), u32(1), u32(2147483648), u32(7), u32(65536), u32(9)'
    : 'u32(2147483648), u32(7), u32(65536), u32(9)';
const other = { uint256: 'int256', int256: 'uint128', uint128: 'int128', int128: 'uint256' }[kind];
const keep = { '@u': !signed, '@s': signed, '@256': bits === 256, '@128': bits === 128 };
fs.mkdirSync(target, { recursive: true });
for (const name of fs.readdirSync(source).sort()) {
    const from = path.join(source, name);
    if (name.endsWith('.mjs')) { fs.copyFileSync(from, path.join(target, name)); continue; }
    const out = [];
    for (let line of fs.readFileSync(from, 'latin1').split('\n')) {
        const tag = Object.keys(keep).find((t) => line.startsWith(t + ' ') || line.startsWith(t + '\t'));
        if (tag) {
            if (!keep[tag]) continue;
            line = line.slice(tag.length);
        }
        out.push(line);
    }
    const text = out.join('\n').replaceAll('__T__', kind).replaceAll('__BYTES__', String(bits / 8)).replaceAll('__WORDS__', words)
        .replaceAll('__BITS__', String(bits)).replaceAll('__OTHER__', other).replaceAll('__EDGEWORDS__', edge)
        .replaceAll('__MAXDECIMAL__', `"${maxdec}"`).replaceAll('__MINDECIMAL__', `"${maxdec + 1n}"`);
    fs.writeFileSync(path.join(target, name.endsWith('.in') ? name.slice(0, -3) : name), text, 'latin1');
}
