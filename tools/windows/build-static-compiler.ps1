# Build the Windows PE from an Abla compiler object and the published static SDK.
param(
    [Parameter(Mandatory)][string]$CompilerObject,
    [Parameter(Mandatory)][string]$ImportDirectory,
    [Parameter(Mandatory)][string]$LlvmRoot,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    # The C library ablac.exe links (docs/design/windows-crt-free-compiler.md, step 7): msvc, the static UCRT and libcmt
    # (/MT), or abla, Abla's own, which needs the object of src/orc_windows_main_crtfree.ab as -CompilerObject.
    [ValidateSet('msvc', 'abla', 'abla-heap')][string]$CLibrary = 'msvc',
    # Also link the /GS exception-dispatch probe (tools/windows/check-gs-handler.ps1): this object, gs-probe.cpp compiled by
    # cl, linked as ablac.exe is, to abla-gs-probe.exe in the build directory.
    [string]$GsProbeObject,
    # Also run the C runtime inventory links (crt-inventory.ps1) after ablac.exe; ablac.exe itself is linked as without it.
    [switch]$CrtInventory,
    # With -CrtInventory: the object of src/orc_windows_main_crtfree.ab and its import libraries, which the ablac-crt-candidate
    # link uses instead of the shipped object (decision #163, docs/design/windows-crt-free-compiler.md).
    [string]$CandidateObject,
    [string]$CandidateImportDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

& (Join-Path $PSScriptRoot 'msvc-env.ps1') -Architecture $Architecture
$llvmTools = Join-Path $env:ProgramFiles 'LLVM/bin'
$clang = Join-Path $llvmTools 'clang-cl.exe'
$linker = Join-Path $llvmTools 'lld-link.exe'
$compiler = (Resolve-Path -LiteralPath $CompilerObject).Path
$imports = (Resolve-Path -LiteralPath $ImportDirectory).Path
$llvm = (Resolve-Path -LiteralPath $LlvmRoot).Path
$build = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDirectory)
# abla-heap: the Abla C library with malloc and free on the Windows process heap (process-heap.cpp), a measurement arm.
# The outer @() keeps this an array: an `if` expression unrolls a one-element array to a string, and `+=` would then
# concatenate, and splatting the string would pass its characters to cmake one by one.
$targetOptions = @(if ($CLibrary -eq 'abla-heap') { '-DABLA_C_LIBRARY=abla', '-DABLA_WINDOWS_PROCESS_HEAP=ON' }
    else { "-DABLA_C_LIBRARY=$CLibrary" })
$machine = 'IMAGE_FILE_MACHINE_AMD64'
if ($Architecture -eq 'arm64') {
    $machine = 'IMAGE_FILE_MACHINE_ARM64'
    $targetOptions += '-DCMAKE_CXX_COMPILER_TARGET=aarch64-pc-windows-msvc'
}
$targets = @('ablac')
if ($GsProbeObject) {
    $targetOptions += "-DABLA_GS_PROBE_OBJECT=$((Resolve-Path -LiteralPath $GsProbeObject).Path)"
    $targets += 'abla-gs-probe'
}
if ($CrtInventory) { $targetOptions += '-DABLA_CRT_INVENTORY=ON' }
if ($CrtInventory -and $CandidateObject) {
    $candidate = (Resolve-Path -LiteralPath $CandidateObject).Path
    $candidateImports = (Resolve-Path -LiteralPath $CandidateImportDirectory).Path
    $targetOptions += "-DABLA_CANDIDATE_OBJECT=$candidate", "-DABLA_CANDIDATE_IMPORT_DIR=$candidateImports"
}
cmake -G Ninja -S (Join-Path $PSScriptRoot 'static-compiler') -B $build `
    '-DCMAKE_BUILD_TYPE=Release' "-DCMAKE_CXX_COMPILER=$clang" "-DCMAKE_LINKER=$linker" `
    "-DABLA_COMPILER_OBJECT=$compiler" "-DABLA_IMPORT_DIR=$imports" "-DABLA_LLVM_ROOT=$llvm" `
    "-DABLA_WINDOWS_MACHINE=$Architecture" @targetOptions
cmake --build $build --target @targets

$exe = Join-Path $build 'ablac.exe'
$readobj = Join-Path $llvm 'bin/llvm-readobj.exe'
$imports = (& $readobj --file-headers --coff-imports $exe) -join "`n"
if ($imports -notmatch "\b$machine\b" -or
    $imports -match '(?mi)^\s+Name: (?:api-ms-win-crt-[^\s]+|ucrtbased?\.dll|msvc[pr][^\s]*\.dll|vcruntime[^\s]*\.dll)\s*$') {
    Write-Host $imports
    throw "Expected a $Architecture compiler with no dynamic CRT imports"
}
if ($CrtInventory) {
    & (Join-Path $PSScriptRoot 'crt-inventory.ps1') -BuildDirectory $build
}
