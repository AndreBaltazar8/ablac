// Load client for tests/benchmarks/websocket-server-load.ab (run with Bun).
//
//   bun tools/websocket-load-client.ts [url=ws://127.0.0.1:9101/ws]
//       [sockets=1000] [seconds=15] [inputHz=20]
//
// Opens N sockets, sends a small input message per socket at inputHz, and
// reports received frames/bytes plus the spread of tick arrival per second.
const url = process.argv[2] ?? 'ws://127.0.0.1:9101/ws';
const sockets = Number(process.argv[3] ?? 1000);
const seconds = Number(process.argv[4] ?? 15);
const inputHz = Number(process.argv[5] ?? 20);

let open = 0;
let failed = 0;
let closed = 0;
let frames = 0;
let bytes = 0;
let sent = 0;
// Per tick: first/last arrival across all sockets (fan-out spread).
const tickFirst = new Map<number, number>();
const tickLast = new Map<number, number>();
const tickCount = new Map<number, number>();
const clients: WebSocket[] = [];

const started = performance.now();
for (let i = 0; i < sockets; i++) {
	const ws = new WebSocket(url);
	ws.binaryType = 'arraybuffer';
	ws.onopen = () => open++;
	ws.onerror = () => failed++;
	ws.onclose = (event) => {
		closed++;
		if (open > 0) open--;
		if (performance.now() - started < (seconds - 1) * 1000) console.log(`client socket closed code=${event.code} reason=${event.reason}`);
	};
	ws.onmessage = (event) => {
		const now = performance.now();
		frames++;
		const text = typeof event.data === 'string' ? event.data : '';
		bytes += text.length;
		const tick = Number(text.slice(5, text.indexOf(',')));
		if (!tickFirst.has(tick)) tickFirst.set(tick, now);
		tickLast.set(tick, now);
		tickCount.set(tick, (tickCount.get(tick) ?? 0) + 1);
	};
	clients.push(ws);
}

const input = JSON.stringify({ t: 'input', mx: 0.5, mz: -0.25, aim: 1.57, fire: false });
const inputTimer = setInterval(() => {
	for (const ws of clients) {
		if (ws.readyState === WebSocket.OPEN) {
			ws.send(input);
			sent++;
		}
	}
}, 1000 / inputHz);

let lastFrames = 0;
let lastBytes = 0;
let lastSent = 0;
const report = setInterval(() => {
	const spreads: number[] = [];
	let complete = 0;
	for (const [tick, first] of tickFirst) {
		const count = tickCount.get(tick) ?? 0;
		if (performance.now() - first > 500) {
			spreads.push((tickLast.get(tick) ?? first) - first);
			if (count >= open) complete++;
			tickFirst.delete(tick);
			tickLast.delete(tick);
			tickCount.delete(tick);
		}
	}
	spreads.sort((a, b) => a - b);
	const p = (q: number) => (spreads.length ? spreads[Math.min(spreads.length - 1, Math.floor(q * spreads.length))].toFixed(2) : '-');
	console.log(
		`client open=${open} failed=${failed} closed=${closed} frames=${frames - lastFrames}/s ` +
			`in=${((bytes - lastBytes) / 1024).toFixed(0)}KiB/s sent=${sent - lastSent}/s ` +
			`ticksComplete=${complete}/${spreads.length} fanoutSpread p50=${p(0.5)}ms p99=${p(0.99)}ms max=${p(1)}ms`
	);
	lastFrames = frames;
	lastBytes = bytes;
	lastSent = sent;
}, 1000);

setTimeout(() => {
	clearInterval(inputTimer);
	clearInterval(report);
	for (const ws of clients) ws.close(1000, 'done');
	setTimeout(() => {
		console.log(`client done in ${((performance.now() - started) / 1000).toFixed(1)}s closed=${closed}`);
		process.exit(0);
	}, 1000);
}, seconds * 1000);
