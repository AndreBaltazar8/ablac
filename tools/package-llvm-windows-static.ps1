# Build the fork used by nix/llvm-fork.nix. The caller packs the checked install tree.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $true

if ($env:RUNNER_ARCH -ne 'X64' -or $env:REVISION -cnotmatch '^[1-9][0-9]*$') {
    throw 'Use an x64 Windows runner and a positive asset revision'
}

$root = Split-Path -Parent $PSScriptRoot
$asset = "llvm-23.1.3-fdiv-$env:REVISION-x86_64-windows-msvc"
$bundle = Join-Path $root $asset
$work = Join-Path $env:RUNNER_TEMP 'abla-llvm'
$source = Join-Path $work 'src'
$build = Join-Path $work 'build'
$patch = Join-Path $work 'llvm-instcombine-fdiv-zero.patch'
$pin = Get-Content (Join-Path $root 'nix/llvm-fork.nix') -Raw
if ($pin -cnotmatch 'commit = "([0-9a-f]{40})";') {
    throw 'Could not read the LLVM fork commit from nix/llvm-fork.nix'
}
$commit = $Matches[1]

& (Join-Path $PSScriptRoot 'windows/msvc-x64-env.ps1')
$llvmTools = Join-Path $env:ProgramFiles 'LLVM/bin'
$clang = Join-Path $llvmTools 'clang-cl.exe'
$linker = Join-Path $llvmTools 'lld-link.exe'
if (!(Test-Path $clang) -or !(Test-Path $linker)) {
    throw "Missing clang-cl or lld-link in $llvmTools"
}

New-Item -ItemType Directory -Path $source | Out-Null
# The Windows checkout may expand the patch to CRLF, while the fork tarball uses LF.
git -C $root cat-file blob 'HEAD:nix/llvm-instcombine-fdiv-zero.patch' > $patch
$sourceArchive = Join-Path $work 'source.tar.gz'
$prefix = "llvm-project-$commit"
Invoke-WebRequest "https://codeload.github.com/AndreBaltazar8/llvm-project/tar.gz/$commit" -OutFile $sourceArchive
# LLVM needs libc headers and lld Mach-O needs libunwind headers.
# The unused MLGO scripts have symlinks.
& "$env:SystemRoot/System32/tar.exe" -xf $sourceArchive -C $source --strip-components 1 `
    --exclude "$prefix/llvm/utils/mlgo-utils" `
    "$prefix/cmake" "$prefix/libc" "$prefix/libunwind/include" "$prefix/llvm" "$prefix/lld" "$prefix/third-party"
Remove-Item $sourceArchive
Push-Location (Join-Path $source 'llvm')
try {
    git apply --check $patch
    git apply $patch
} finally {
    Pop-Location
}

$cmakeOptions = @(
    '-DCMAKE_BUILD_TYPE=Release'
    "-DCMAKE_C_COMPILER=$clang"
    "-DCMAKE_CXX_COMPILER=$clang"
    "-DCMAKE_LINKER=$linker"
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded'
    '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON'
    '-DBUILD_SHARED_LIBS=OFF'
    '-DLLVM_BUILD_LLVM_C_DYLIB=OFF'
    '-DLLVM_ENABLE_PROJECTS=lld'
    '-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-windows-msvc'
    '-DLLVM_TARGETS_TO_BUILD=all'
    '-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=Xtensa'
    '-DLLVM_BUILD_TOOLS=OFF'
    '-DLLVM_TOOL_LTO_BUILD=OFF'
    '-DLLVM_TOOL_REMARKS_SHLIB_BUILD=OFF'
    '-DLLVM_BUILD_UTILS=OFF'
    '-DLLVM_INCLUDE_UTILS=OFF'
    '-DLLVM_INCLUDE_TESTS=OFF'
    '-DLLVM_INCLUDE_BENCHMARKS=OFF'
    '-DLLVM_INCLUDE_EXAMPLES=OFF'
    '-DLLVM_ENABLE_BINDINGS=OFF'
    '-DLLVM_ENABLE_DIA_SDK=OFF'
    '-DLLVM_ENABLE_LIBEDIT=OFF'
    '-DLLVM_ENABLE_LIBXML2=OFF'
    '-DLLVM_ENABLE_ZLIB=OFF'
    '-DLLVM_ENABLE_ZSTD=OFF'
    '-DLLVM_PARALLEL_LINK_JOBS=1'
)
cmake -G Ninja -S (Join-Path $source 'llvm') -B $build @cmakeOptions

# Check the generated compile commands, so a CMake or toolset change cannot
# silently build part of the archive with the DLL CRT.
# MASM and resource compiler invocations do not select a C runtime.
$compileCommands = Get-Content (Join-Path $build 'compile_commands.json') -Raw | ConvertFrom-Json | Where-Object {
    $_.file -notmatch '\.(?:asm|s|rc)$'
}
$wrongCrt = @($compileCommands | Where-Object {
    $_.command -notmatch '(?:^|\s)[/-]MT(?:\s|$)' -or $_.command -match '(?:^|\s)[/-]M(?:Dd?|Td)(?:\s|$)'
})
if (!$compileCommands -or $wrongCrt.Count) {
    $wrongCrt | Select-Object -First 3 | Format-List
    throw 'Expected /MT in every LLVM and lld C/C++ compile command'
}
Write-Host "Verified /MT in $($compileCommands.Count) C/C++ compile commands"

# Build the default static libraries and just the command-line tools we check/ship.
cmake --build $build --parallel 4 --target all opt llc llvm-readobj
cmake --install $build --prefix $bundle
$bin = Join-Path $bundle 'bin'
New-Item -ItemType Directory -Path $bin -Force | Out-Null
foreach ($tool in @('opt', 'llc', 'llvm-readobj')) {
    Copy-Item (Join-Path $build "bin/$tool.exe") $bin
}

foreach ($name in @(
    'LLVMCore', 'LLVMOptDriver', 'LLVMObjCopy', 'LLVMOrcJIT', 'LLVMOrcShared',
    'LLVMOrcTargetProcess', 'LLVMJITLink', 'LLVMRuntimeDyld', 'LLVMX86CodeGen',
    'LLVMAArch64CodeGen', 'LLVMRISCVCodeGen', 'LLVMWebAssemblyCodeGen', 'LLVMXtensaCodeGen',
    'lldCommon', 'lldCOFF', 'lldELF', 'lldWasm'
)) {
    if (!(Test-Path (Join-Path $bundle "lib/$name.lib") -PathType Leaf)) {
        throw "Missing static library $name.lib"
    }
}

$opt = Join-Path $bin 'opt.exe'
$llc = Join-Path $bin 'llc.exe'
$readobj = Join-Path $bin 'llvm-readobj.exe'
$fixture = Join-Path $root 'tests/cases/llvm-miscompiles/fdiv-zero-by-zero-times-value.ll'
$optimized = Join-Path $work 'fdiv-opt.ll'
$coff = Join-Path $work 'fdiv.obj'
$probeSource = Join-Path $work 'probe.c'
$probeObject = Join-Path $work 'probe.obj'
$probe = Join-Path $work 'probe.exe'
$version = (& $opt --version) -join "`n"
Write-Host $version
if ($version -notmatch '\b23\.1\.3\b') { throw 'Expected LLVM 23.1.3' }
& $opt -passes=instcombine -S $fixture -o $optimized
if ((Get-Content $optimized -Raw) -cnotmatch '(?m)^\s+ret double (?:\+qnan|0x7FF8[0-9A-Fa-f]+)\s*$') {
    Get-Content $optimized
    throw 'opt did not fold f to NaN'
}
Write-Host 'opt: fdiv fixture folds to NaN'

& $llc -O2 -mtriple=x86_64-pc-windows-msvc -filetype=obj $optimized -o $coff
@'
#include <math.h>
extern double f(long long n);
int main(void) {
    return isnan(f(5)) && isnan(f(-5)) && isnan(f(0)) ? 0 : 1;
}
'@ | Set-Content -Encoding ascii $probeSource
& $clang /nologo /MT /fp:precise /c "/Fo$probeObject" $probeSource
& $clang /nologo "/Fe$probe" $probeObject $coff -fuse-ld=lld
& $probe
Write-Host 'llc: the x64 COFF fixture returns NaN for positive, negative and zero inputs'

$shim = Join-Path $work 'abla_lld_shim.obj'
$include = Join-Path $bundle 'include'
& $clang /nologo /MT /std:c++17 /EHsc /c "/I$include" "/Fo$shim" (Join-Path $root 'runtime/abla_lld_shim.cpp')
$shimInfo = (& $readobj --file-headers --coff-directives $shim) -join "`n"
if ($shimInfo -notmatch 'IMAGE_FILE_MACHINE_AMD64' -or $shimInfo -notmatch 'DEFAULTLIB:"?libcmt\b') {
    throw 'Expected an x64 COFF shim object with the static CRT directive'
}
Write-Host 'shim: x64 COFF, static CRT'

foreach ($exe in @($probe, $opt, $llc, $readobj)) {
    $imports = (& $readobj --file-headers --coff-imports $exe) -join "`n"
    if ($imports -notmatch 'IMAGE_FILE_MACHINE_AMD64' -or $imports -notmatch '(?m)^\s+Name: .+\.dll\s*$' -or
        $imports -match '(?mi)^\s+Name: (?:api-ms-win-crt-[^\s]+|ucrtbased?\.dll|msvc[pr][^\s]*\.dll|vcruntime[^\s]*\.dll)\s*$') {
        Write-Host $imports
        throw "Expected an x64 executable with no dynamic CRT imports: $exe"
    }
}
Write-Host 'CRT: no dynamic MSVC or UCRT imports in the probe or LLVM tools'

$patchHash = (Get-FileHash -Algorithm SHA256 $patch).Hash.ToLowerInvariant()
@(
    'llvm-project=AndreBaltazar8/llvm-project'
    "commit=$commit"
    "abla-commit=$env:GITHUB_SHA"
    "fdiv-patch-sha256=$patchHash"
    'target=x86_64-pc-windows-msvc'
    'crt=MT'
    "msvc-toolset=$env:VCToolsVersion"
    "windows-sdk=$($env:WindowsSDKVersion.TrimEnd('\'))"
    "runner-image=$env:ImageOS $env:ImageVersion"
    "clang-cl=$(& $clang --version | Select-Object -First 1)"
    "cmake=$(cmake --version | Select-Object -First 1)"
    "ninja=$(ninja --version)"
) | Set-Content -Encoding utf8 (Join-Path $bundle 'SOURCE')
Get-Content (Join-Path $bundle 'SOURCE')
