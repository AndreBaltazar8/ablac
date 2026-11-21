#!/usr/bin/env bash
set -euo pipefail
file=$1
printf '# Abla language benchmarks\n\n'
jq -r '"Source `\(.metadata.sourceCommit)`. Smoke: \(.metadata.smoke). CPU \(.metadata.cpu), \(.metadata.rounds) runtime samples and \(.metadata.compileRounds) cold builds per arm. Status: \(.status)."' "$file"
printf '\nRatios are language / C; smaller is less time/memory/size. Times are process wall seconds including the GNU-time launcher. Startup excludes that launcher and includes fork/exec/wait overhead. These are measurements on a shared machine, not isolated hardware.\n\n'
printf '| Program | Language | Wall s | /C | RSS MiB | /C | Stripped bytes | /C | Compile s | /C |\n|---|---|---:|---:|---:|---:|---:|---:|---:|---:|\n'
jq -r '.programs|to_entries[]|.key as $p|.value.languages|to_entries[]|[$p,.key,(.value.wallSeconds.median|tostring),(.value.ratiosToC.wallSeconds|tostring),(.value.rssBytes.median/1048576|tostring),(.value.ratiosToC.rssBytes|tostring),(.value.strippedBytes|tostring),(.value.ratiosToC.strippedBytes|tostring),(.value.compileSeconds.median|tostring),(.value.ratiosToC.compileSeconds|tostring)]|"| "+join(" | ")+" |"' "$file"
printf '\nCPU-workload geometric means (binary-trees, fannkuch, n-body, spectral-norm, mandelbrot, fasta only):\n\n'
jq -r '[.programs|to_entries[]|select(.key|IN("binary-trees","fannkuch","n-body","spectral-norm","mandelbrot","fasta"))|.value.languages|to_entries[]|{language:.key,ratio:.value.ratiosToC.wallSeconds}]|group_by(.language)[]|"- \(.[0].language): \(map(.ratio|log)|add/length|exp)x C (\(length) workloads)"' "$file"
printf '\nStartup seconds per hello process (batch median, includes process-launch overhead):\n\n'
jq -r '.programs.hello.languages // {}|to_entries[]|"- \(.key): \(.value.startupSeconds.median)"' "$file"
printf '\nHTTP requests/second (one blocking server, concurrency 1, fresh connection per request):\n\n'
jq -r '.programs["http-echo"].languages // {}|to_entries[]|"- \(.key): \(.value.requestsPerSecond.median)"' "$file"
printf '\nJSON and regex compare library paths: json-c/PCRE2 via FFI in C, Rust and Zig; native libraries in Abla and Go. JSON values are compared after key-order canonicalization. Floating outputs allow absolute + relative tolerance 1e-8. All other complete outputs match byte for byte. HTTP checks echo bytes before/after load and timed response counts/length/status.\n\nRSS is child GNU-time peak RSS (KiB converted to bytes), or live server VmHWM for HTTP. Zero means unavailable, never a zero-memory claim. Binary sizes exclude shared-library closures. Compile time uses fresh application and Go/Zig caches; preinstalled toolchain libraries and OS page cache remain warm. Min/max, individual samples, commands, source/binary hashes, tool paths, versions, CPU information and load are retained alongside the table.\n'
