# Describe the already-selected patched LLVM; this never builds LLVM itself.
# Unlike portable archives, these symlinks point into immutable Nix outputs.
{ pkgs, llvmTools }:
pkgs.runCommand "abla-xtensa-llvm-cohort" {
  nativeBuildInputs = [ pkgs.nodejs ];
} ''
  mkdir -p "$out/bin" "$out/lib"
  export ABLA_COHORT_OUT="$out"
  export ABLA_COHORT_TOOLS="${llvmTools}/bin"
  export ABLA_COHORT_LIB="${pkgs.lib.getLib llvmTools}/lib"
  export ABLA_COHORT_HOST="${if pkgs.stdenv.hostPlatform.isAarch64 then "arm64" else "x86_64"}-${if pkgs.stdenv.hostPlatform.isDarwin then "macos" else "linux"}"
  node - <<'JS'
const crypto = require("crypto"), fs = require("fs"), path = require("path"), cp = require("child_process");
const root = process.env.ABLA_COHORT_OUT, tools = process.env.ABLA_COHORT_TOOLS;
for (const name of ["opt", "llc"]) fs.symlinkSync(path.join(tools, name), path.join(root, "bin", name));
const library = process.env.ABLA_COHORT_LIB;
for (const name of fs.readdirSync(library).filter((n) => n.startsWith("libLLVM")).sort()) {
  const file = path.join(library, name);
  if (fs.statSync(file).isFile() && (name.includes(".so") || name.endsWith(".dylib"))) fs.symlinkSync(file, path.join(root, "lib", name));
}
const sha = (data) => crypto.createHash("sha256").update(data).digest("hex");
const walk = (directory) => fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
  const target = path.join(directory, entry.name);
  return entry.isDirectory() ? walk(target) : [target];
});
const files = {};
for (const file of walk(root).sort()) {
  if (fs.statSync(file).isFile()) files[path.relative(root, file)] = sha(fs.readFileSync(file));
}
if (!Object.keys(files).some((name) => name.startsWith("lib/libLLVM"))) throw new Error("no libLLVM in the cohort");
const versionText = cp.execFileSync(path.join(tools, "opt"), ["--version"], { encoding: "utf8" });
const version = /LLVM version ([0-9]+\.[0-9]+\.[0-9]+)/.exec(versionText)[1];
const sorted = (x) => (x !== null && typeof x === "object" && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, sorted(x[k])])) : x);
const manifest = { schema: 1, origin: "nix-store", version: "abla-xtensa-llvm-nix-" + sha(tools), platform: process.env.ABLA_COHORT_HOST, llvmVersion: version, files };
fs.writeFileSync(path.join(root, "manifest.json"), JSON.stringify(sorted(manifest), null, 2) + "\n");
JS
''
