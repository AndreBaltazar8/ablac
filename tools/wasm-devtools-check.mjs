// tools/test-wasm-devtools.sh's browser half: headless Chrome over the DevTools protocol, doing what the DevTools
// frontend does with a module's source map (the protocol itself knows nothing of maps). It sets a breakpoint at an
// Abla line by its code offset, maps the pause back, reads the frame's name from the module's name section, applies
// the map's ignore list as blackboxed ranges and steps over, which must stay in the program's own source.
// Usage: node tools/wasm-devtools-check.mjs <directory with page.html, probe.wasm and its map> <chrome> <line>
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const [directory, chrome, lineText] = process.argv.slice(2);
const line = Number(lineText);
const fail = (message) => { console.error(`wasm devtools: ${message}`); process.exit(1); };
const types = { '.wasm': 'application/wasm', '.html': 'text/html', '.map': 'application/json' };
const server = http.createServer((request, response) => {
  const file = path.join(directory, decodeURIComponent(new URL(request.url, 'http://host').pathname));
  if (!file.startsWith(directory) || !fs.existsSync(file)) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { 'Content-Type': types[path.extname(file)] ?? 'application/octet-stream' });
  response.end(fs.readFileSync(file));
}).listen(0, '127.0.0.1');
await new Promise((resolve) => server.on('listening', resolve));
const profile = fs.mkdtempSync(path.join(directory, 'profile-'));
const browser = spawn(chrome, ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
  '--no-first-run', '--no-default-browser-check', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
// Whatever ends this script ends the browser.
process.on('exit', () => { try { browser.kill(); } catch {} });
const finish = async (code) => {
  const exited = new Promise((resolve) => browser.on('exit', resolve));
  browser.kill();
  await exited;
  server.close();
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch {}
  process.exit(code);
};
// The browser names its DevTools endpoint on standard error.
const endpoint = await new Promise((resolve) => {
  let text = '';
  browser.stderr.on('data', (chunk) => {
    text += chunk;
    const found = /DevTools listening on (ws:\/\/\S+)/.exec(text);
    if (found) resolve(found[1]);
  });
  setTimeout(() => resolve(''), 30000);
});
if (endpoint === '') { console.error('wasm devtools: the browser named no DevTools endpoint'); await finish(1); }
const port = new URL(endpoint).port;
let targets = [];
for (let tries = 0; tries < 100 && !targets.some((t) => t.type === 'page'); tries++) {
  try { targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); } catch {}
  await new Promise((resolve) => setTimeout(resolve, 100));
}
const socket = new WebSocket(targets.find((t) => t.type === 'page').webSocketDebuggerUrl);
await new Promise((resolve) => socket.addEventListener('open', resolve));
let id = 0;
const pending = new Map();
const events = [];
socket.addEventListener('message', (message) => {
  const data = JSON.parse(message.data);
  if (data.id && pending.has(data.id)) { pending.get(data.id)(data); pending.delete(data.id); } else events.push(data);
});
const send = (method, params = {}) => new Promise((resolve) => {
  pending.set(++id, resolve);
  socket.send(JSON.stringify({ id, method, params }));
});
const next = async (method) => {
  for (let tries = 0; tries < 600; tries++) {
    const index = events.findIndex((event) => event.method === method);
    if (index >= 0) return events.splice(index, 1)[0].params;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  fail(`no ${method}`);
};
await send('Debugger.enable');
await send('Runtime.enable');
await send('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/page.html` });
const ready = await send('Runtime.evaluate', { expression: 'window.ready', awaitPromise: true });
if (ready.result?.result?.value !== 'ready') fail(`the page did not load the module: ${JSON.stringify(ready)}`);
const script = events.filter((event) => event.method === 'Debugger.scriptParsed').map((event) => event.params)
  .find((parsed) => parsed.url.endsWith('probe.wasm'));
if (!script) fail('the module was not parsed');
if (script.sourceMapURL !== 'probe.wasm.map') fail(`the module names its map as ${script.sourceMapURL}`);
// The map: one generated line, whose columns are module byte offsets.
const map = JSON.parse(fs.readFileSync(path.join(directory, script.sourceMapURL), 'utf8'));
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const mappings = [];
const state = [0, 0, 0, 0];
for (const segment of map.mappings.split(',')) {
  const values = [];
  let value = 0;
  let shift = 0;
  for (const character of segment) {
    const digit = alphabet.indexOf(character);
    value += (digit & 31) << shift;
    if (digit & 32) shift += 5;
    else { values.push(value & 1 ? -(value >> 1) : value >> 1); value = 0; shift = 0; }
  }
  for (let index = 0; index < values.length && index < 4; index++) state[index] += values[index];
  if (values.length >= 4) mappings.push({ offset: state[0], source: state[1], line: state[2] + 1 });
}
const at = (offset) => mappings.filter((m) => m.offset <= offset).reduce((best, m) => (m.offset >= best.offset ? m : best), mappings[0]);
const name = (mapping) => `${path.basename(map.sources[mapping.source])}:${mapping.line}`;
const probe = map.sources.findIndex((source) => source.endsWith('/probe.ab'));
const target = mappings.filter((m) => m.source === probe && m.line === line).sort((a, b) => a.offset - b.offset)[0];
if (!target) fail(`probe.ab:${line} has no code in the map`);
const ignored = map.ignoreList ?? [];
if (ignored.length === 0 || ignored.includes(probe)) fail(`the ignore list is ${JSON.stringify(ignored)}`);
// The ignore list as DevTools applies it: the module's ranges whose source is on it, blackboxed.
const positions = [];
let inside = false;
for (const mapping of [...mappings].sort((a, b) => a.offset - b.offset)) {
  const listed = ignored.includes(mapping.source);
  if (listed !== inside) { positions.push({ lineNumber: 0, columnNumber: mapping.offset }); inside = listed; }
}
await send('Debugger.setBlackboxedRanges', { scriptId: script.scriptId, positions });
// And as the ranges a step skips (stepOver's skipList), which is how DevTools steps over ignore-listed code inlined
// into a function of the program.
const skipList = [];
for (let index = 0; index + 1 < positions.length; index += 2) {
  skipList.push({ scriptId: script.scriptId, start: positions[index], end: positions[index + 1] });
}
const set = await send('Debugger.setBreakpoint', { location: { scriptId: script.scriptId, lineNumber: 0, columnNumber: target.offset } });
if (!set.result) fail(`no breakpoint at offset ${target.offset}: ${JSON.stringify(set.error)}`);
send('Runtime.evaluate', { expression: 'window.probe.main()' });
let paused = await next('Debugger.paused');
const frame = paused.callFrames[0];
const stopped = name(at(frame.location.columnNumber));
const caller = paused.callFrames[1] ? name(at(paused.callFrames[1].location.columnNumber)) : '';
console.log(`paused in ${frame.functionName} at ${stopped}, called from ${caller}`);
if (stopped !== `probe.ab:${line}`) fail(`the pause maps to ${stopped}, not probe.ab:${line}`);
if (!frame.functionName.includes('probe.main.lambda')) fail(`the frame is named ${frame.functionName}`);
let steps = 0;
let where = stopped;
while (where === stopped && steps < 400) {
  await send('Debugger.stepOver', { skipList });
  paused = await next('Debugger.paused');
  where = name(at(paused.callFrames[0].location.columnNumber));
  steps++;
}
console.log(`stepped over (${steps} steps) to ${where} in ${paused.callFrames[0].functionName}`);
if (!where.startsWith('probe.ab:')) fail(`stepping over left the program for ${where}`);
await send('Debugger.resume');
socket.close();
await finish(0);
