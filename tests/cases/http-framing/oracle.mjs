// Sends each request stream of requests.mjs to Node's HTTP server (llhttp) and prints one verdict line per stream:
//   <name>\t<R:method path body-hex>... then E:<llhttp error code> (a refused stream) or I (nothing more happened: incomplete)
// node oracle.mjs > node.txt
// Every server event goes to the stream whose connection produced it (the stream index is put on the socket when it is
// accepted, while that stream is the only one open): a late event of the previous stream's connection, such as the
// ECONNRESET of its close, once landed in the next stream's verdict under load ("E:ECONNRESET | R:POST /p ...").
import http from "node:http";
import net from "node:net";
import { requests } from "./requests.mjs";

const results = [];
const stream = new WeakMap(); // server-side socket -> index in results
const verdictOf = (socket) => results[stream.get(socket) ?? results.length - 1];
const server = http.createServer({ maxHeaderSize: 65536, keepAliveTimeout: 5000, requireHostHeader: false }, (req, res) => {
    const chunks = [];
    const verdict = verdictOf(req.socket);
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
        // An absolute-form target is served by its path (RFC 9112 3.2.2), as Abla's servers do: compared in origin form.
        const target = req.url.split("?")[0];
        const absolute = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\/]*(.*)$/.exec(target);
        const path = absolute ? (absolute[1] || "/") : target;
        verdict.push(`R:${req.method} ${path} ${Buffer.concat(chunks).toString("hex") || "-"}`);
        res.end("ok");
    });
});
server.on("connection", (socket) => stream.set(socket, results.length - 1));
server.on("clientError", (err, socket) => {
    verdictOf(socket).push(`E:${err.code ?? err.message}`);
    socket.destroy();
});
server.listen(0, "127.0.0.1", async () => {
    const port = server.address().port;
    const lines = [];
    for (const [name, raw] of requests) {
        results.push([]);
        const verdict = results[results.length - 1];
        await new Promise((resolve) => {
            const socket = net.connect(port, "127.0.0.1", () => socket.write(Buffer.from(raw, "latin1")));
            let timer = setTimeout(done, 400);
            function done() { clearTimeout(timer); socket.destroy(); resolve(); }
            socket.on("data", (d) => { const m = /^HTTP\/1\.1 (4\d\d) /.exec(d.toString("latin1")); if (m && verdict.length === 0) verdict.push(`E:http${m[1]}`); clearTimeout(timer); timer = setTimeout(done, 150); });
            socket.on("close", done);
            socket.on("error", done);
        });
        lines.push(`${name}\t${verdict.length === 0 ? "I" : verdict.join(" | ")}`);
    }
    console.log(lines.join("\n"));
    server.close();
    process.exit(0);
});
