// Run the native test normally and force failure after its fixture run: success and an injected failure both leave
// output that can be removed. Usage: node check-cleanup.mjs COMPILER
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const compiler = path.resolve(process.argv[2]);
const out = path.join(root, 'build/xtensa-native-test');
const test = path.join(root, 'tools/test-xtensa-native.sh');

function checkOutput(remove = true) {
    assert.ok(fs.statSync(path.join(out, 'fixtures/good/lib/abla/xtensa-llvm/23.1.3-1')).isDirectory());
    const walk = (directory) => {
        for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
            const target = path.join(directory, entry.name);
            if (!entry.isSymbolicLink()) assert.ok(fs.lstatSync(target).mode & 0o200, `not owner-writable: ${target}`);
            if (entry.isDirectory()) walk(target);
        }
    };
    assert.ok(fs.lstatSync(out).mode & 0o200);
    walk(out);
    if (remove) fs.rmSync(out, { recursive: true, force: true });
}

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'xtensa-native-cleanup-'));
try {
    // A `node` ahead of the real one in PATH that fails after the fixture test ran.
    const shim = path.join(temp, 'node');
    fs.writeFileSync(shim, '#!/usr/bin/env bash\n"$REAL_NODE" "$@" || exit $?\ncase ${1-} in */tests/cases/xtensa-native/test.mjs) exit 99;; esac\n');
    fs.chmodSync(shim, 0o755);
    const env = { ...process.env, REAL_NODE: process.execPath, PATH: temp + path.delimiter + process.env.PATH };
    let result = spawnSync(test, [compiler], { cwd: root, env, stdio: 'inherit' });
    assert.equal(result.status, 99, `failure control returned ${result.status}`);
    checkOutput();
    result = spawnSync(test, [compiler], { cwd: root, stdio: 'inherit' });
    assert.equal(result.status, 0);
    checkOutput(false);
} finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log('native cleanup: success and injected failure leave removable output');
