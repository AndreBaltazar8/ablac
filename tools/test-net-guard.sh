#!/usr/bin/env bash
# The suite's network guard (tools/lib/net-guard/curl, put on every suite command's PATH by tools/run-tests.sh): curl and wget
# reach file:// and the loopback host, and refuse every other URL; gh is refused; a refused call fails the command in the real
# runner even when the test swallowed it (exit 97), unless tools/test-network-allowed.txt names the script. Nothing here leaves
# the machine: the refused URLs never reach a real curl, and the allowed case only looks at which curl it would run.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { echo "net guard: $*" >&2; exit 1; }
guard=$root/tools/lib/net-guard
log=$work/network.log
guarded() { : > "$log"; PATH="$guard:$PATH" ABLA_NET_GUARD_LOG=$log "$@"; }

# 1. The guard itself.
printf 'local bytes\n' > "$work/file.txt"
[[ $(guarded curl -s "file://$work/file.txt") == 'local bytes' ]] || fail "curl of a file:// URL did not run the real curl"
[[ ! -s $log ]] || fail "a file:// URL was logged"
# A loopback port nothing listens on: the real curl runs and fails to connect (7); the guard logs nothing.
status=0; guarded curl -s --max-time 2 http://127.0.0.1:9/ || status=$?
[[ $status == 7 && ! -s $log ]] || fail "a loopback URL was not handed to the real curl (exit $status, log: $(cat "$log"))"
status=0; guarded curl -s --max-time 2 'http://[::1]:9/' || status=$?
[[ ! -s $log ]] || fail "an IPv6 loopback URL was refused"
for url in https://example.invalid/ http://127.0.0.1.example.invalid/ http://localhost.example.invalid/x https://user@example.invalid/; do
    status=0; guarded curl -s "$url" 2> "$work/err" || status=$?
    [[ $status == 7 ]] || fail "curl $url: exit $status, not refused"
    grep -q 'net-guard: refused curl' "$work/err" || fail "curl $url: no refusal message"
    grep -qF "$url" "$log" || fail "curl $url was not logged"
done
status=0; guarded wget -q -O - https://example.invalid/ 2> /dev/null || status=$?
[[ $status == 7 && -s $log ]] || fail "wget of a remote URL was not refused"
status=0; guarded gh release list 2> /dev/null || status=$?
[[ $status == 7 ]] && grep -qx 'gh release list' "$log" || fail "gh was not refused and logged (exit $status)"
guarded curl --version > /dev/null || fail "curl --version did not run the real curl"
[[ ! -s $log ]] || fail "curl --version was logged"
# A test's own fake in front of the guard wins (the release tests' fakes keep working).
mkdir "$work/fake"; printf '#!/bin/sh\necho fake gh\n' > "$work/fake/gh"; chmod +x "$work/fake/gh"
[[ $(PATH="$work/fake:$guard:$PATH" gh run view 1) == 'fake gh' ]] || fail "a test's own fake gh lost to the guard"
echo 'net guard: file:// and loopback pass to the real curl; remote URLs, wget and gh are refused and logged'

# 2. The real runner, in a private tree.
mkdir -p "$work/tree/tools/lib" "$work/tree/build"
cp "$root/tools/"{run-tests,suite-wall-limit}.sh "$root/tools/test-fast-builds.txt" "$work/tree/tools/"
cp -R "$guard" "$work/tree/tools/lib/"
printf 'tools/test-allowed-net.sh  this fixture checks that it gets the real curl\n' > "$work/tree/tools/test-network-allowed.txt"
cat > "$work/tree/tools/test-allowed-net.sh" <<'EOF'
#!/bin/sh
case $(command -v curl) in *net-guard*) echo "the allowed test got the guard"; exit 1 ;; esac
EOF
chmod +x "$work/tree/tools/test-allowed-net.sh"
printf 'fixture compiler\n' > "$work/tree/build/ablac"
cat > "$work/commands.txt" <<EOF
curl -s https://example.invalid/ || true
gh release list || true
curl -s file://$work/file.txt
tools/test-allowed-net.sh
EOF
status=0
(cd "$work/tree" && RUN_TESTS_COMMANDS=$work/commands.txt JOBS=2 RUN_TESTS_MIN_FREE=0 RUN_TESTS_OUTPUT=$work/out \
    RUN_TESTS_FILTER= RUN_TESTS_EXCLUDE= RUN_TESTS_SHARD= RUN_TESTS_HISTORY=$work/none tools/run-tests.sh build/ablac) > "$work/runner.log" 2>&1 || status=$?
[[ $status == 1 ]] || { cat "$work/runner.log" >&2; fail "the runner exited $status, not 1"; }
result() { awk -F'\t' -v c="$1" '$4 == c { print $2 }' "$work/out/results.tsv"; }
[[ $(result 'curl -s https://example.invalid/ || true') == 97 ]] || fail "a swallowed remote curl did not fail its command with 97: $(cat "$work/out/results.tsv")"
[[ $(result 'gh release list || true') == 97 ]] || fail "a swallowed gh did not fail its command with 97"
[[ $(result "curl -s file://$work/file.txt") == 0 ]] || fail "a file:// curl failed its command"
[[ $(result 'tools/test-allowed-net.sh') == 0 ]] || fail "a script in tools/test-network-allowed.txt still got the guard"
grep -q 'reached for the network' "$work/out/1.log" || fail "the failed command's log does not say why"
echo 'net guard: the runner fails a command that reached for the network (97), and leaves file:// and the allowed list alone'
