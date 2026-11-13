// A USTAR archive of [name, data, mode] members as Python's tarfile wrote them (owner 0, time 0), for the fixtures.
export function ustar(members) {
    const blocks = [];
    for (const [name, data, mode] of members) {
        const header = Buffer.alloc(512);
        header.write(name, 0, 100, 'latin1');
        header.write(mode.toString(8).padStart(7, '0') + '\0', 100);
        header.write('0000000\0', 108);
        header.write('0000000\0', 116);
        header.write(data.length.toString(8).padStart(11, '0') + '\0', 124);
        header.write('00000000000\0', 136);
        header.write('        ', 148);
        header.write('0', 156);
        header.write('ustar\0' + '00', 257);
        let sum = 0;
        for (const byte of header) sum += byte;
        header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148);
        blocks.push(header, data, Buffer.alloc((512 - (data.length % 512)) % 512));
    }
    blocks.push(Buffer.alloc(1024));
    const tar = Buffer.concat(blocks);
    // tarfile pads the archive to its record size.
    return Buffer.concat([tar, Buffer.alloc((10240 - (tar.length % 10240)) % 10240)]);
}
