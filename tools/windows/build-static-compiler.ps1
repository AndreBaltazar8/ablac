# Build the Windows PE from an Abla compiler object and the published static SDK.
param(
    [Parameter(Mandatory)][string]$CompilerObject,
    [Parameter(Mandatory)][string]$ImportDirectory,
    [Parameter(Mandatory)][string]$LlvmRoot,
    [Parameter(Mandatory)][string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

& (Join-Path $PSScriptRoot 'msvc-env.ps1')
$llvmTools = Join-Path $env:ProgramFiles 'LLVM/bin'
$clang = Join-Path $llvmTools 'clang-cl.exe'
$linker = Join-Path $llvmTools 'lld-link.exe'
$compiler = (Resolve-Path -LiteralPath $CompilerObject).Path
$imports = (Resolve-Path -LiteralPath $ImportDirectory).Path
$llvm = (Resolve-Path -LiteralPath $LlvmRoot).Path
$build = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDirectory)
cmake -G Ninja -S (Join-Path $PSScriptRoot 'static-compiler') -B $build `
    '-DCMAKE_BUILD_TYPE=Release' "-DCMAKE_CXX_COMPILER=$clang" "-DCMAKE_LINKER=$linker" `
    "-DABLA_COMPILER_OBJECT=$compiler" "-DABLA_IMPORT_DIR=$imports" "-DABLA_LLVM_ROOT=$llvm"
cmake --build $build --target ablac

$exe = Join-Path $build 'ablac.exe'
$readobj = Join-Path $llvm 'bin/llvm-readobj.exe'
$imports = (& $readobj --file-headers --coff-imports $exe) -join "`n"
if ($imports -notmatch 'IMAGE_FILE_MACHINE_AMD64' -or
    $imports -match '(?mi)^\s+Name: (?:api-ms-win-crt-[^\s]+|ucrtbased?\.dll|msvc[pr][^\s]*\.dll|vcruntime[^\s]*\.dll)\s*$') {
    Write-Host $imports
    throw 'Expected an x64 compiler with no dynamic CRT imports'
}
