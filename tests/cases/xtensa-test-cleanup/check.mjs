// Run the offline companion test normally and with failure after its first installation: both leave output that can
// be removed. Usage: node check.mjs COMPILER
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const compiler = path.resolve(process.argv[2]);
const out = path.join(root, 'build/xtensa-companion-offline');
const test = path.join(root, 'tools/test-xtensa-companion-offline.sh');

function checkOutput(remove = true) {
    assert.ok(fs.statSync(path.join(out, 'target/23.1.3-1')).isDirectory(), 'fixture was not installed');
    assert.ok(fs.lstatSync(out).mode & 0o200);
    const walk = (directory) => {
        for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
            const target = path.join(directory, entry.name);
            if (!entry.isSymbolicLink()) assert.ok(fs.lstatSync(target).mode & 0o200, `not owner-writable: ${target}`);
            if (entry.isDirectory()) walk(target);
        }
    };
    walk(out);
    if (remove) fs.rmSync(out, { recursive: true, force: true });
}

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'xtensa-cleanup-'));
try {
    // A compiler that builds as asked, then makes the built program fail after it has run.
    const wrapper = path.join(temp, 'compiler');
    fs.writeFileSync(wrapper, `#!/usr/bin/env bash
set -euo pipefail
"$REAL_COMPILER" "$@"
while [[ $# -gt 0 ]]; do
    if [[ $1 == -o ]]; then output=$2; break; fi
    shift
done
mv "$output" "$output.real"
cat > "$output" <<'EOF'
#!/bin/sh
"$0.real" "$@" || exit $?
exit 99
EOF
chmod +x "$output"
`);
    fs.chmodSync(wrapper, 0o755);
    let result = spawnSync(test, [wrapper], { cwd: root, env: { ...process.env, REAL_COMPILER: compiler }, stdio: 'inherit' });
    assert.equal(result.status, 99, `failure control returned ${result.status}`);
    checkOutput();
    result = spawnSync(test, [compiler], { cwd: root, stdio: 'inherit' });
    assert.equal(result.status, 0);
    checkOutput(false);
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log('xtensa cleanup: success and injected failure leave removable output');
