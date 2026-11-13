// Sequential Unix TLS echo/identity/deadline fixtures; no external service. The peers are Node's TLS (OpenSSL's), an
// implementation independent of the Abla program under test.
// Usage: node peer.mjs PROGRAM CERTIFICATE KEY IDENTITY_BUNDLE SCRATCH_DIRECTORY
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import tls from 'node:tls';

const [binary, certificate, key, bundle, directory] = process.argv.slice(2).map((p) => path.resolve(p));
const certificateText = fs.readFileSync(certificate), keyText = fs.readFileSync(key);

function run(address, mode) {
    return new Promise((resolve, reject) => {
        const child = spawn(binary, [address, certificate, key, bundle, mode], { stdio: ['ignore', 'pipe', 'pipe'] });
        let output = '';
        child.stdout.on('data', (d) => { output += d; });
        child.stderr.on('data', (d) => { output += d; });
        const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error(`${mode} (${address}): timed out\n${output}`)); }, 600000);
        child.on('close', (code) => {
            clearTimeout(timer);
            if (code) reject(new Error(`${mode} (${address}): ${code}\n${output}`));
            else resolve();
        });
    });
}

const endpoint = (name, abstract) => (abstract ? `@abla-tls-${process.pid}-${name}` : path.join(directory, `${name}.sock`));
const listenAddress = (address) => (address.startsWith('@') ? '\0' + address.slice(1) : address);

// One connection is served; `serve(socket, done)` reports its end through done(error?).
function peer(address, mode, { requireIdentity = false, stall = false } = {}) {
    const reject = ['invalid', 'bad-host', 'bad-ca'].includes(mode);
    const errors = [];
    let unexpectedSuccess = false;
    let finish;
    const finished = new Promise((resolve) => { finish = resolve; });
    let server;
    const done = (error) => { if (error) errors.push(error); finish(); };
    if (stall) {
        // A record that never completes (its header, then its 256 bytes one at a time, 40 s in all): a per-read
        // timeout cannot substitute for the absolute handshake deadline, and a client that honours a deadline closes
        // long before the record would end.
        server = net.createServer((socket) => {
            socket.once('data', () => {
                const bytes = Buffer.concat([Buffer.from([0x16, 0x03, 0x03, 0x01, 0x00]), Buffer.alloc(256)]);
                let at = 0;
                const timer = setInterval(() => { if (at < bytes.length) socket.write(bytes.subarray(at++, at)); else stop(); }, 160);
                const stop = () => { clearInterval(timer); socket.destroy(); done(); };
                socket.on('error', stop);
                socket.on('close', stop);
            });
            socket.on('error', () => {});
        });
    } else {
        server = tls.createServer({
            cert: certificateText, key: keyText,
            ...(requireIdentity ? { requestCert: true, rejectUnauthorized: true, ca: certificateText } : {}),
        }, (socket) => {
            socket.on('error', (error) => { if (!reject) done(error); });
            if (requireIdentity && !socket.getPeerCertificate().subject) done(new Error('client identity was not presented'));
            // TLS 1.3 rejection can arrive after the server's handshake; an application read must still fail.
            socket.on('data', (data) => {
                if (reject) { unexpectedSuccess = true; done(); return; }
                if (data.toString() !== 'hello') { done(new Error('missing echo request')); return; }
                socket.end('world');
            });
            socket.on('close', () => done());
        });
        server.on('tlsClientError', (error) => { if (!reject) done(error); else done(); });
    }
    return new Promise((resolve, rejectRun) => {
        server.on('error', rejectRun);
        server.listen(listenAddress(address), async () => {
            const watchdog = setTimeout(() => done(new Error(`peer outlived ${mode}`)), 700000);
            try {
                await run(address, mode);
                // The peer's side ends with the client's; a rejecting peer may never see a connection end cleanly.
                await Promise.race([finished, new Promise((r) => setTimeout(r, 10000))]);
            } catch (error) {
                errors.push(error);
            } finally {
                clearTimeout(watchdog);
                server.close();
                if (!address.startsWith('@')) fs.rmSync(address, { force: true });
            }
            if (errors.length) rejectRun(new Error(`peer ${mode}: ${errors.map(String).join('; ')}`));
            else if (unexpectedSuccess) rejectRun(new Error(`invalid client succeeded: ${mode}`));
            else resolve();
        });
    });
}

for (const abstract of process.platform === 'linux' ? [false, true] : [false]) {
    const prefix = abstract ? 'abstract' : 'path';
    for (const mode of ['echo', 'inherited', 'server-deadline']) await run(endpoint(`${prefix}-${mode}`, abstract), mode);
    for (const mode of ['plain', 'pem', 'p12', 'invalid', 'bad-host', 'bad-ca']) {
        await peer(endpoint(`${prefix}-${mode}`, abstract), mode, { requireIdentity: ['pem', 'p12', 'invalid'].includes(mode) });
    }
    for (const kind of ['plain', 'pem', 'p12']) await peer(endpoint(`${prefix}-deadline-${kind}`, abstract), `deadline-${kind}`, { stall: true });
}
for (const mode of ['tcp', 'tcp-identity']) await run('unused', mode);
console.log('TLS upgrades: Unix path/abstract echo, mTLS PEM/P12, rejection, deadlines, timeout inheritance and TCP named calls passed');
