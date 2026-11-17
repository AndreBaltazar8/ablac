// Sends each request stream of requests.mjs to Node's HTTP server (llhttp) and prints one verdict line per stream:
//   <name>\t<R:method path body-hex>... then E:<llhttp error code> (a refused stream) or I (nothing more happened: incomplete)
// node oracle.mjs > node.txt
import http from "node:http";
import net from "node:net";
import { requests } from "./requests.mjs";

const results = [];
const server = http.createServer({ maxHeaderSize: 65536, keepAliveTimeout: 5000, requireHostHeader: false }, (req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
        const path = req.url.split("?")[0];
        results[results.length - 1].push(`R:${req.method} ${path} ${Buffer.concat(chunks).toString("hex") || "-"}`);
        res.end("ok");
    });
});
server.on("clientError", (err, socket) => {
    results[results.length - 1].push(`E:${err.code ?? err.message}`);
    socket.destroy();
});
server.listen(0, "127.0.0.1", async () => {
    const port = server.address().port;
    const lines = [];
    for (const [name, raw] of requests) {
        results.push([]);
        await new Promise((resolve) => {
            const socket = net.connect(port, "127.0.0.1", () => socket.write(Buffer.from(raw, "latin1")));
            let timer = setTimeout(done, 400);
            function done() { clearTimeout(timer); socket.destroy(); resolve(); }
            socket.on("data", (d) => { const m = /^HTTP\/1\.1 (4\d\d) /.exec(d.toString("latin1")); if (m && results[results.length - 1].length === 0) results[results.length - 1].push(`E:http${m[1]}`); clearTimeout(timer); timer = setTimeout(done, 150); });
            socket.on("close", done);
            socket.on("error", done);
        });
        const verdict = results[results.length - 1];
        lines.push(`${name}\t${verdict.length === 0 ? "I" : verdict.join(" | ")}`);
    }
    console.log(lines.join("\n"));
    server.close();
    process.exit(0);
});
