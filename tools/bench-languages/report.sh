#!/usr/bin/env bash
set -euo pipefail
file=$1
printf '# Abla language benchmarks\n\n'
jq -r '"Measurement source `\(.metadata.sourceCommit)`. Smoke: \(.metadata.smoke). CPU \(.metadata.cpu), \(.metadata.rounds) runtime samples and \(.metadata.compileRounds) cold builds per language. Status: \(.status)."' "$file"
jq -r '"\nToolchains: " + ((.metadata.versions // {})|to_entries|map("\(.key): \(.value)")|join("; ")) + ".\n\nNixpkgs: `\(.metadata.nixpkgsCommit)`. Abla compiler SHA-256: `\(.metadata.compilerSha256)`."' "$file"
printf '\nRatios are language / C; smaller is less time/memory/size. Finite-workload wall seconds include the GNU-time launcher. Startup excludes that launcher and includes fork/exec/wait overhead; HTTP uses oha elapsed time. These are measurements on a shared machine, not isolated hardware.\n\n'
printf '| Program | Language | Wall s | /C | RSS MiB | /C | Stripped bytes | /C | Compile s | /C |\n|---|---|---:|---:|---:|---:|---:|---:|---:|---:|\n'
jq -r '
 def f($p): if .==null then "n/a" else pow(10;$p) as $s | ((.*$s|round)/$s|tostring) end;
 def rank: .key as $k | ["c","abla","rust","go","zig"] | index($k);
 .programs|to_entries[]|.key as $p|.value.languages|to_entries|sort_by(rank)[]|
 [$p,.key,(.value.wallSeconds.median|f(6)),(.value.ratiosToC.wallSeconds|f(3)),
 (.value.rssBytes.median/1048576|f(3)),(.value.ratiosToC.rssBytes|f(3)),
 (.value.strippedBytes|tostring),(.value.ratiosToC.strippedBytes|f(3)),
 (.value.compileSeconds.median|f(3)),(.value.ratiosToC.compileSeconds|f(3))]|"| "+join(" | ")+" |"' "$file"
printf '\nCPU-workload geometric means (binary-trees, fannkuch, n-body, spectral-norm, mandelbrot, fasta only):\n\n'
jq -r '[.programs|to_entries[]|select(.key|IN("binary-trees","fannkuch","n-body","spectral-norm","mandelbrot","fasta"))|.value.languages|to_entries[]|{language:.key,ratio:.value.ratiosToC.wallSeconds}]|group_by(.language)[]|"- \(.[0].language): \(map(.ratio|log)|add/length|exp|.*1000|round|./1000)x C (\(length) workloads)"' "$file"
printf '\nStartup milliseconds per hello process (batch median, includes process-launch overhead):\n\n| Language | ms | /C |\n|---|---:|---:|\n'
jq -r '.programs.hello.languages // {}|to_entries[]|[.key,(.value.startupSeconds.median*1e6|round|./1000|tostring),(.value.ratiosToC.startupSeconds*1000|round|./1000|tostring)]|"| "+join(" | ")+" |"' "$file"
printf '\nHTTP requests/second (one blocking server, concurrency 1, fresh connection per request; a larger throughput ratio is faster):\n\n| Language | requests/s | /C |\n|---|---:|---:|\n'
jq -r '.programs["http-echo"].languages // {}|to_entries[]|[.key,(.value.requestsPerSecond.median|round|tostring),(.value.ratiosToC.requestsPerSecond*1000|round|./1000|tostring)]|"| "+join(" | ")+" |"' "$file"
jq -r '[.samples[]|select(.program=="http-echo" and has("requestRateLimit"))|.requestRateLimit]|unique|
  if length>0 then "\nHTTP offered load caps (requests/s): \(map(tostring)|join(", ")). Throughput near a cap reflects the load limit." else empty end' "$file"
printf '\nJSON and regex compare library paths: json-c/PCRE2 via FFI in C, Rust and Zig; native libraries in Abla and Go. JSON values are compared after key-order canonicalization. Floating outputs allow absolute + relative tolerance 1e-8. All other complete outputs match byte for byte. HTTP checks echo bytes before/after load and timed response counts/length/status.\n\nRSS is child GNU-time peak RSS (KiB converted to bytes), or live server VmHWM for HTTP. Zero means unavailable, never a zero-memory claim. Binary sizes exclude shared-library closures. Compile time uses fresh application and Go/Zig caches; preinstalled toolchain libraries and OS page cache remain warm. Min/max, individual samples, commands, source/binary hashes, tool paths, versions, CPU information and load are retained alongside the table.\n'
