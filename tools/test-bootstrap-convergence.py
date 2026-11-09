#!/usr/bin/env python3
"""Manual Linux historical-seed convergence; never publishes or replaces a seed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time


HISTORICAL = "ca9221b0615cd419284a9e8e9f671bf8429ccd3b"  # v0.2.45
SEEDS = {
    "a": ("v0.2.45", "f30c9027a23923bcb97bb27d1b23f818e612e7aed157636d72db136aa56006f3"),
    "b": ("v0.2.44", "90a5614b3557221baf62a224160d4b42e884bcd18545af8475da22c096f03a98"),
}
# The pairs of routes the gate knows. A lineage names the tag whose source route B rebuilds (the "bridge"), the
# route A seed (that tag's own release) and the route B seed (the release before it). The default is the first
# pair the gate was built for; --lineage picks a newer one. Seeds are checksum-pinned release assets.
LINEAGES = {
    "v0.2.45": {"historical": HISTORICAL, "seeds": dict(SEEDS)},
    "v0.2.51": {
        "historical": "1758d94e64b0e7f31f22107f8556fd63dc4351c6",
        "seeds": {
            "a": ("v0.2.51", "d8e24762f3657cfc90289a6bc93ddcb6aa7b9df8338c93d4090e5b06319f4d7d"),
            "b": ("v0.2.50", "aa40e582e66f40013571b7ef1311e9079582d0fbeffa7843d57707a18205b7a9"),
        },
    },
}


def configure(lineage, root=None):
    """Select the pair of routes (the module-level HISTORICAL and SEEDS the rest of the gate reads), and where the
    candidate source sits. Both routes and the comparison must use the same root: the IR carries source paths. CI
    reserves /build/source; a local run without it names a directory it owns, such as <scratch>/build/source."""
    global HISTORICAL, SEEDS, CANONICAL_ROOT
    if lineage not in LINEAGES:
        raise ValueError(f"unknown lineage {lineage}; known: {', '.join(sorted(LINEAGES))}")
    HISTORICAL = LINEAGES[lineage]["historical"]
    SEEDS = dict(LINEAGES[lineage]["seeds"])
    CANONICAL_ROOT = root if root is not None else "/build/source"
CANONICAL_ROOT = "/build/source"
# A command put in front of every build step (a shared machine's queue); empty in CI.
WRAPPER = []
ENTRY = "src/orc_main.ab"


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def toolchain_stores(environment):
    # mkShell puts its unrealized `out` in NIX_LDFLAGS. Keep that text in the
    # provenance, but query closures of actual tool/crypto roots, not shell out.
    stores = set()
    for line in environment.splitlines():
        value = line.split("=", 1)[1] if line.startswith(("llvm_tools=", "openssl=")) else line
        if value.startswith("/nix/store/"):
            stores.add("/".join(value.split("/")[:4]))
    if not stores:
        raise ValueError("missing pinned Nix toolchain paths")
    return sorted(stores)


def same(left, right):
    """Exact comparison, with a bounded first-difference diagnostic."""
    with Path(left).open("rb") as a, Path(right).open("rb") as b:
        offset = 0
        while True:
            x, y = a.read(65536), b.read(65536)
            if x != y:
                at = next((i for i, pair in enumerate(zip(x, y)) if pair[0] != pair[1]), min(len(x), len(y)))
                raise ValueError(f"{left} differs from {right} at byte {offset + at}: "
                                 f"{x[max(0, at-40):at+80]!r} / {y[max(0, at-40):at+80]!r}")
            if not x:
                return
            offset += len(x)


def command(argv, cwd, log, env=None, output=None, timeout=1800):
    if WRAPPER:
        timeout = None  # the wrapper may queue for a slot; its time is not the build's
    print("+", shlex.join(map(str, argv)), flush=True)
    with Path(log).open("wb") as errors:
        if output is None:
            subprocess.run(argv, cwd=cwd, env=env, stdout=errors, stderr=subprocess.STDOUT,
                           check=True, timeout=timeout)
        else:
            with Path(output).open("wb") as result:
                subprocess.run(argv, cwd=cwd, env=env, stdout=result, stderr=errors,
                               check=True, timeout=timeout)


def archive(repo, revision, path):
    with path.open("wb") as stream:
        subprocess.run(["git", "archive", "--format=tar", revision], cwd=repo, stdout=stream, check=True)
    return digest(path)


def route(which, repo, output):
    if sys.platform != "linux":
        raise ValueError("Linux only")
    root = Path(CANONICAL_ROOT)
    historical = root.parent / "historical"
    # Never clean an existing checkout, even when it belongs to the caller.
    if root.exists() or historical.exists():
        raise ValueError(f"requires fresh {root} and {historical}; refusing to replace either")
    output.mkdir(parents=True, exist_ok=False)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=repo, text=True).strip()
    version, checksum = SEEDS[which]
    manifest = {"schema": 1, "route": which, "status": "incomplete",
                "candidate": {"revision": revision, "tree": tree},
                "historical_revision": HISTORICAL, "canonical_root": CANONICAL_ROOT,
                "entry": ENTRY, "representation": "raw --emit-llvm, non-debug, pre-prune",
                "seed": {"version": version, "sha256": checksum}, "builds": [], "files": {}}
    write_json(output / "manifest.json", manifest)
    source_tar, history_tar = output / "source.tar", output / "historical.tar"
    try:
        manifest["candidate"]["archive_sha256"] = archive(repo, revision, source_tar)
        manifest["historical_archive_sha256"] = archive(repo, HISTORICAL, history_tar)
        for tar, destination in [(source_tar, root), (history_tar, historical)]:
            destination.mkdir(parents=True)
            subprocess.run(["tar", "-xf", str(tar), "-C", str(destination)], check=True)
        source_tar.unlink()
        history_tar.unlink()
        for name in ["home", "tmp", "cache", "bootstrap"]:
            (root.parent / name).mkdir(exist_ok=False)
        cpus = sorted(os.sched_getaffinity(0))[:4]
        env = dict(os.environ)
        # --pure removes ambient ABLA_*, LD_*, grants and optimization overrides.
        env.update(HOME=str(root.parent / "home"), TMPDIR=str(root.parent / "tmp"))
        shell_settings = {"CI": "true", "TZ": "UTC", "LC_ALL": "C", "JOBS": str(len(cpus)),
                          "ABLA_NATIVE_JOBS": str(len(cpus)), "ABLA_CODEGEN_JOBS": str(len(cpus)),
                          "ABLA_CACHE_DIR": str(root.parent / "cache"), "ABLA_MAX_MEMORY_MB": "4096",
                          "ABLA_MAX_STACK_KB": "131072", "ABLA_RELEASE_SELFHOST_BUILD_SECONDS": "1800"}
        manifest["settings"] = {k: v for k, v in shell_settings.items() if k not in ("JOBS", "ABLA_NATIVE_JOBS", "ABLA_CODEGEN_JOBS")}
        manifest["cpus"] = cpus

        def shell(source, args, label, stdout=None):
            settings = dict(shell_settings, ABLA_SYSROOT=str(source))
            body = "ulimit -s 131072; exec env " + shlex.join([f"{k}={v}" for k, v in settings.items()] + list(map(str, args)))
            command([*WRAPPER, "taskset", "-c", ",".join(map(str, cpus)), "nix-shell", "--pure", str(source / "shell.nix"),
                     "--arg", "xtensa", "true", "--run", body], source, output / (label + ".log"), env, stdout)

        # Capture the immutable tool paths, versions and their full Nix closures.
        shell(root, ["bash", "-c", 'printf "llvm_tools=%s\\nopenssl=%s\\nldflags=%s\\n" "$ABLA_LLVM_TOOLS" "$ABLA_LINUX_OPENSSL_LIB" "$NIX_LDFLAGS"; for tool in opt llc ld.lld clang; do command -v "$tool"; "$tool" --version | sed -n "1,2p"; done'],
              "environment", output / "environment.txt")
        environment = (output / "environment.txt").read_text()
        closure = subprocess.check_output(["nix-store", "--query", "--requisites", *toolchain_stores(environment)], text=True)
        (output / "closure.txt").write_text("\n".join(sorted(set(closure.splitlines()))) + "\n")
        manifest["toolchain"] = {"environment_sha256": digest(output / "environment.txt"),
                                 "closure_sha256": digest(output / "closure.txt")}
        seed = root.parent / "bootstrap" / "seed.bin"
        url = f"https://github.com/AndreBaltazar8/ablac/releases/download/{version}/ablac-x86_64-linux"
        command(["curl", "--fail", "--location", "--retry", "3", "--output", str(seed), url], repo,
                output / "seed-download.log", env)
        if digest(seed) != checksum:
            raise ValueError("seed checksum mismatch; no fallback")
        seed.chmod(0o755)

        def build(source, compiler, binary, label):
            started = time.monotonic()
            before = digest(compiler)
            shell(source, [str(source / "tools/build-self-hosted-current.sh"), str(compiler), str(binary), ENTRY], label)
            manifest["builds"].append({"name": label, "source_revision": HISTORICAL if source == historical else revision,
                                       "input_sha256": before, "output_sha256": digest(binary),
                                       "seconds": round(time.monotonic() - started, 3)})
            write_json(output / "manifest.json", manifest)
            return binary

        compiler = seed
        if which == "b":
            for stage in [1, 2]:
                compiler = build(historical, compiler, root.parent / "bootstrap" / f"historical-{stage}.bin", f"historical-{stage}")
        for stage in [1, 2, 3]:
            compiler = build(root, compiler, root / "build" / f"stage{stage}.bin", f"stage{stage}")
        for stage in [2, 3]:
            binary = root / "build" / f"stage{stage}.bin"
            shell(root, [str(binary), "--emit-llvm", ENTRY], f"emit-stage{stage}", output / f"stage{stage}.ll")
            shell(root, ["opt", "-passes=verify", "-disable-output", str(output / f"stage{stage}.ll")], f"verify-stage{stage}")
            # Move only after all generations have finished using these outputs.
            for source, name in [(binary, f"stage{stage}.bin"), (Path(str(binary) + ".o"), f"stage{stage}.o")]:
                source.rename(output / name)
        for suffix in ["ll", "bin", "o"]:
            same(output / f"stage2.{suffix}", output / f"stage3.{suffix}")
        probe = root / "build" / "convergence-probe.ab"
        probe.write_text('fun main: int = 42\n')
        shell(root, [str(output / "stage3.bin"), "build", str(probe), "-o", str(probe.with_suffix("")), "--fast", "--no-cache"], "probe-build")
        result = subprocess.run([str(probe.with_suffix(""))], cwd=root, env=env, timeout=30)
        if result.returncode != 42:
            raise ValueError(f"native child exited {result.returncode}, expected42")
        manifest["probe_exit"] = result.returncode
        for name in ["stage2.ll", "stage3.ll", "stage2.bin", "stage3.bin", "stage2.o", "stage3.o", "environment.txt", "closure.txt"]:
            manifest["files"][name] = digest(output / name)
        manifest["status"] = "passed"
    except Exception as error:
        manifest["error"] = str(error)
        raise
    finally:
        write_json(output / "manifest.json", manifest)


def compare(a, b, output, expected_revision=None):
    output.mkdir(parents=True, exist_ok=False)
    try:
        manifests = []
        for which, directory in [("a", a), ("b", b)]:
            m = json.loads((directory / "manifest.json").read_text())
            if m["schema"] != 1 or m["route"] != which or m["status"] != "passed" or m["probe_exit"] != 42:
                raise ValueError(f"route {which}: incomplete or wrong provenance")
            version, checksum = SEEDS[which]
            if m["seed"] != {"version": version, "sha256": checksum} or m["historical_revision"] != HISTORICAL:
                raise ValueError(f"route {which}: wrong seed or bridge")
            if m["canonical_root"] != CANONICAL_ROOT or m["entry"] != ENTRY or m["representation"] != "raw --emit-llvm, non-debug, pre-prune":
                raise ValueError(f"route {which}: wrong IR contract")
            if expected_revision is not None and m["candidate"]["revision"] != expected_revision:
                raise ValueError(f"route {which}: not the dispatched source revision")
            expected = (["historical-1", "historical-2"] if which == "b" else []) + ["stage1", "stage2", "stage3"]
            if [s["name"] for s in m["builds"]] != expected:
                raise ValueError(f"route {which}: missing bootstrap stage")
            previous = checksum
            for stage in m["builds"]:
                source = HISTORICAL if stage["name"].startswith("historical-") else m["candidate"]["revision"]
                if stage["input_sha256"] != previous or stage["source_revision"] != source:
                    raise ValueError(f"route {which}: broken bootstrap chain")
                previous = stage["output_sha256"]
            names = ["stage2.ll", "stage3.ll", "stage2.bin", "stage3.bin", "stage2.o", "stage3.o", "environment.txt", "closure.txt"]
            for name in names:
                if digest(directory / name) != m["files"][name]:
                    raise ValueError(f"route {which}: artifact checksum mismatch: {name}")
            if m["toolchain"] != {"environment_sha256": m["files"]["environment.txt"], "closure_sha256": m["files"]["closure.txt"]}:
                raise ValueError(f"route {which}: inconsistent toolchain provenance")
            for stage in [2, 3]:
                record = next(s for s in m["builds"] if s["name"] == f"stage{stage}")
                if record["output_sha256"] != m["files"][f"stage{stage}.bin"]:
                    raise ValueError(f"route {which}: compiler artifact not produced by recorded stage")
            for suffix in ["ll", "bin", "o"]:
                same(directory / f"stage2.{suffix}", directory / f"stage3.{suffix}")
            manifests.append(m)
        for key in ["candidate", "historical_archive_sha256", "canonical_root", "entry", "representation", "settings", "toolchain"]:
            if manifests[0][key] != manifests[1][key]:
                raise ValueError(f"route provenance differs: {key}")
        for name in ["environment.txt", "closure.txt", "stage2.ll", "stage2.bin", "stage2.o"]:
            same(a / name, b / name)
        write_json(output / "comparison.json", {"passed": True, "candidate": manifests[0]["candidate"],
                                                "canonical_ir_sha256": manifests[0]["files"]["stage2.ll"],
                                                "claim": "historical-seed route convergence; not independent implementation"})
    except Exception as error:
        write_json(output / "comparison.json", {"passed": False, "error": str(error)})
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    run = sub.add_parser("route")
    run.add_argument("--lineage", default="v0.2.45", choices=sorted(LINEAGES))
    run.add_argument("--root", help="absolute candidate source directory (default /build/source)")
    run.add_argument("--wrap", default="", help="a command line put in front of every build step, such as a slot queue")
    run.add_argument("route", choices=["a", "b"])
    run.add_argument("output", type=Path)
    join = sub.add_parser("compare")
    join.add_argument("--lineage", default="v0.2.45", choices=sorted(LINEAGES))
    join.add_argument("--root", help="the --root the routes ran with")
    join.add_argument("a", type=Path)
    join.add_argument("b", type=Path)
    join.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.root is not None and not os.path.isabs(args.root):
        parser.error("--root must be an absolute path")
    configure(args.lineage, args.root)
    if args.mode == "route":
        WRAPPER[:] = shlex.split(args.wrap)
    if args.mode == "route":
        route(args.route, Path(__file__).absolute().parent.parent, args.output.absolute())
    else:
        repo = Path(__file__).absolute().parent.parent
        expected = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        compare(args.a, args.b, args.output, expected)


if __name__ == "__main__":
    main()
