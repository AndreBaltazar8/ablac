#!/usr/bin/env bash
set -euo pipefail
compiler=build/ablac
if [[ $# -gt 0 ]]; then compiler=$1; fi
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
export ABLA_SYSROOT=$root

node --input-type=module - "$compiler" <<'JS'
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { existsSync, mkdtempSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const [compiler] = process.argv.slice(2);
const scratch = mkdtempSync(join(tmpdir(), "abla-git-timeout-"));
const gitConfig = join(scratch, "gitconfig");
writeFileSync(gitConfig, "[http]\n\tlowSpeedLimit = 1\n\tlowSpeedTime = 1\n");
try {
    for (const [selector, value, operation, interrupt] of [
        ["branch", "main", "ls-remote", false],
        ["rev", "0123456789abcdef0123456789abcdef01234567", "fetch", false],
        ["branch", "main", "ls-remote", true],
    ]) {
        const app = join(scratch, interrupt ? "interrupt" : selector);
        const cache = join(app, "cache");
        mkdirSync(app);
        writeFileSync(join(app, "main.ab"), "fun main: int = 0\n");

        const sockets = new Set();
        let received = false;
        const server = createServer(socket => {
            sockets.add(socket);
            socket.on("data", bytes => {
                if (received || bytes[0] !== 22) return;
                received = true;
                if (interrupt) child.kill("SIGINT");
            });
            socket.on("error", () => {});
            socket.once("close", () => sockets.delete(socket));
        });
        server.listen(0, "127.0.0.1");
        await once(server, "listening");
        const source = "https://127.0.0.1:" + server.address().port + "/silent.git";
        writeFileSync(join(app, "abla.toml"),
            'name = "app"\nversion = "0.1.0"\nentry = "main.ab"\n\n[dependencies]\n' +
            'silent = { git = "' + source + '", ' + selector + ' = "' + value + '" }\n');

        let expired = false;
        let diagnostic = "";
        const child = spawn(compiler, ["package", "update", "--project", app], {
            detached: true,
            stdio: ["ignore", "ignore", "pipe"],
            env: {
                ...process.env,
                ABLA_PACKAGE_CACHE: cache,
                ABLA_PACKAGE_GIT_TIMEOUT_SECONDS: interrupt ? "60" : "2",
                GIT_CONFIG_GLOBAL: gitConfig,
                GIT_CONFIG_NOSYSTEM: "1",
                NO_PROXY: "127.0.0.1",
                no_proxy: "127.0.0.1",
            },
        });
        child.stderr.setEncoding("utf8").on("data", data => { diagnostic += data; });
        const watchdog = setTimeout(() => {
            expired = true;
            for (const socket of sockets) socket.destroy();
            try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
                if (error.code !== "ESRCH") throw error;
            }
        }, 10000);
        try {
            const [status] = await once(child, "close");
            assert.ok(received, operation + " did not send a TLS ClientHello:\n" + diagnostic);
            assert.ok(!expired, operation + " hung until the test watchdog");
            assert.notEqual(status, 0, operation + " unexpectedly succeeded");
            if (interrupt) assert.ok(!diagnostic.includes("E_PACKAGE_GIT_TIMEOUT"), diagnostic);
            else {
                assert.ok(diagnostic.includes("error[E_PACKAGE_GIT_TIMEOUT]"), diagnostic);
                assert.ok(diagnostic.includes(operation) && diagnostic.includes(source) &&
                    diagnostic.includes("2 seconds"), diagnostic);
            }
            assert.ok(!existsSync(join(app, "abla.lock")), "failed update published a lock");
            const fetchCache = join(cache, "git", "silent");
            if (existsSync(fetchCache)) assert.deepEqual(readdirSync(fetchCache), [], "partial fetch cache");
            for (let i = 0; sockets.size > 0 && i < 100; i++) await delay(10);
            assert.equal(sockets.size, 0, operation + " left its HTTPS helper connected");
        } finally {
            clearTimeout(watchdog);
            for (const socket of sockets) socket.destroy();
            server.close();
        }
    }
} finally {
    rmSync(scratch, { recursive: true, force: true });
}
console.log("package Git deadline: silent TLS during ls-remote and fetch; timeout and interrupt stop helpers");
JS
