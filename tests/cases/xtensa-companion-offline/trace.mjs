// Reads an strace log of the offline installer (tools/test-xtensa-companion-offline.sh).
//   node trace.mjs root-order TRACE   checks the staging directory's final chmod 0555 comes after the publishing rename
//   node trace.mjs final-chmod TRACE  prints the ordinal of the fchmod that makes the published root 0555
//   node trace.mjs payload CALL TRACE prints the ordinal of the first CALL (write, fsync) on the staging payload
//   node trace.mjs spool-open TRACE   prints the ordinal of the openat of the spool file
import assert from 'node:assert/strict';
import fs from 'node:fs';

const [command, ...rest] = process.argv.slice(2);
const trace = rest[rest.length - 1];
const lines = fs.readFileSync(trace, 'utf8').split('\n').filter((line) => line !== '');
const ordinal = (call, accept) => {
    let count = 0;
    for (const line of lines) {
        if (!line.startsWith(call + '(')) continue;
        count += 1;
        if (accept(line)) return count;
    }
    console.error(`missing ${call}`);
    process.exit(1);
};
if (command === 'root-order') {
    const rename = lines.findIndex((line) => line.startsWith('renameat2(') && line.includes(' = 0'));
    assert.ok(rename >= 0);
    const modes = lines.flatMap((line, i) => (/fchmod\(\d+<[^>]*(?:\/\.install-[^/>]+|\/23\.1\.3-1)>, 0?555\)/.test(line) ? [i] : []));
    assert.ok(modes.length === 1 && modes[0] > rename, `${rename} ${modes}`);
} else if (command === 'final-chmod') {
    console.log(ordinal('fchmod', (line) => /fchmod\(\d+<[^>]*\/23\.1\.3-1>, 0?555\)/.test(line)));
} else if (command === 'payload') {
    console.log(ordinal(rest[0], (line) => line.includes('/.install-')));
} else if (command === 'spool-open') {
    console.log(ordinal('openat', (line) => line.includes('".spool-')));
} else {
    console.error('unknown command');
    process.exit(2);
}
