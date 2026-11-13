// A loopback TLS server on ::1 for the TLS program: it reads one request, checks its first line, and answers with a
// chunked response in four writes, split inside a header name and inside chunks. Node's TLS (OpenSSL's) is the peer.
// Usage: node peer.mjs PROGRAM CERTIFICATE KEY OUTPUT_DIRECTORY
import fs from 'node:fs';
import tls from 'node:tls';

const [binary, cert, key, output] = process.argv.slice(2);
const errors = [];
let served;
const finished = new Promise((resolve) => { served = resolve; });
const server = tls.createServer({ cert: fs.readFileSync(cert), key: fs.readFileSync(key) }, (socket) => {
    let request = '';
    let answered = false;
    socket.on('error', (error) => { errors.push(String(error)); served(); });
    socket.on('close', () => { if (!answered) errors.push('truncated request'); served(); });
    socket.on('data', (part) => {
        request += part.toString('latin1');
        if (answered || !request.includes('\r\n\r\n')) return;
        answered = true;
        if (!request.startsWith('GET /fixture HTTP/1.1\r\n')) { errors.push('wrong request'); socket.destroy(); return; }
        const parts = ['HTTP/1.1 200 OK\r\nTransfer-', 'Encoding: chunked\r\n\r\n', '2\r\nhe\r\n', '3\r\nllo\r\n0\r\n\r\n'];
        parts.slice(0, -1).forEach((p) => socket.write(p));
        socket.end(parts[parts.length - 1]);
    });
});
server.listen(0, '::1', async () => {
    const { port } = server.address();
    // The program runs as a child while this process keeps serving, so it must not block the event loop.
    const { spawn } = await import('node:child_process');
    const child = spawn(binary, [output, cert, String(port)], { stdio: 'inherit' });
    const timer = setTimeout(() => child.kill('SIGKILL'), 15000);
    const code = await new Promise((resolve) => child.on('close', (c) => resolve(c === null ? 'killed' : c)));
    clearTimeout(timer);
    await Promise.race([finished, new Promise((r) => setTimeout(r, 5000))]);
    server.close();
    if (code !== 0 || errors.length) { console.error(`TLS fixture failed: ${code}, ${JSON.stringify(errors)}`); process.exit(1); }
});
