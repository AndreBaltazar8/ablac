# Self-build twice from the release-tested Windows package and the pinned LLVM SDK.
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$LlvmRoot,
    [Parameter(Mandatory)][string]$BuildDirectory,
    [ValidateSet('interp', 'native')][string]$Tier = 'interp'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$sdk = (Resolve-Path -LiteralPath $LlvmRoot).Path
$work = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDirectory)
$readobj = Join-Path $sdk 'bin/llvm-readobj.exe'
$expected = (Get-Content "$archivePath.sha256" -Raw).Split(' ')[0]
if ($expected -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash $archivePath).Hash -ine $expected) {
    throw 'The Windows toolchain zip does not match its SHA-256'
}

New-Item -ItemType Directory -Path $work | Out-Null
$seedRoot = Join-Path $work 'seed'
Expand-Archive -LiteralPath $archivePath -DestinationPath $seedRoot
$seed = Join-Path $seedRoot 'abla-toolchain-x86_64-windows/bin/ablac.exe'
$coff = Join-Path $work 'coff'
$link = Join-Path $work 'link'

$env:ABLA_SYSROOT = $root
$env:ABLA_COMPILE_EVAL = if ($Tier -eq 'native') { 'jit' } else { 'interp' }
$env:ABLA_COMPILE_EVAL_TRACE = if ($Tier -eq 'native') { '1' } else { '0' }
$env:ABLA_CODEGEN_UNITS = '1'
$env:ABLA_MAX_MEMORY_MB = '8192'
$env:ABLA_WINDOWS_LINK_KEEP = '1'

function Check-CompilerStack([string]$Compiler) {
    $headers = (& $readobj --file-headers $Compiler) -join "`n"
    if ($headers -notmatch '(?m)^\s*SizeOfStackReserve:\s+134217728\s*$') {
        throw "Expected a 128 MiB stack reserve in $Compiler"
    }
}

function Build-Stage([string]$Compiler, [string]$Stage) {
    New-Item -ItemType Directory -Path $coff, $Stage | Out-Null
    $output = Join-Path $coff 'ablac.exe'
    $object = "$output.o"
    $imports = "$output.imports"
    $log = Join-Path $Stage 'compile.log'
    Write-Host "Building $(Split-Path -Leaf $Stage) with $Compiler"
    # The program linker generates the COFF inputs, then fails to link the
    # compiler without its CRT and LLVM. The SDK link below supplies both.
    $PSNativeCommandUseErrorActionPreference = $false
    & $Compiler build src/orc_windows_main.ab --target x86_64-windows-hosted --no-cache -o $output *> $log
    $result = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    if ($result -ne 1 -or !(Test-Path -LiteralPath $object -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $imports 'exports.def') -PathType Leaf) -or
        !(Test-Path -LiteralPath (Join-Path $imports 'kernel32.lib') -PathType Leaf)) {
        Get-Content $log -Tail 50 | Out-Host
        throw "Self-build did not produce its COFF inputs (status $result)"
    }
    $shim = & $readobj --symbols $object |
        Select-String -CaseSensitive -Pattern '^\s*Name: abla_shim_version\s*$' -Context 0,4
    if (!($shim.Context.PostContext -match 'Section: IMAGE_SYM_UNDEFINED')) {
        throw 'The self-built COFF object does not reference the in-process shim'
    }
    & (Join-Path $PSScriptRoot 'build-static-compiler.ps1') -CompilerObject $object `
        -ImportDirectory $imports -LlvmRoot $sdk -BuildDirectory $link
    $exe = Join-Path $Stage 'ablac.exe'
    Move-Item -LiteralPath (Join-Path $link 'ablac.exe') -Destination $exe
    Check-CompilerStack $exe
    Move-Item -LiteralPath $coff -Destination (Join-Path $Stage 'coff')
}

Push-Location $root
try {
    Check-CompilerStack $seed
    $stage2 = Join-Path $work 'stage2'
    $stage3 = Join-Path $work 'stage3'
    Build-Stage $seed $stage2
    Build-Stage (Join-Path $stage2 'ablac.exe') $stage3
    $different = @()
    foreach ($file in 'coff/ablac.exe.o', 'coff/ablac.exe.imports/exports.def', 'ablac.exe') {
        $second = (Get-FileHash (Join-Path $stage2 $file)).Hash
        $third = (Get-FileHash (Join-Path $stage3 $file)).Hash
        Write-Host "$file stage2 $second, stage3 $third"
        if ($second -cne $third) { $different += $file }
    }
    if ($different.Count) {
        throw "Stage 2 and stage 3 differ in $($different -join ', ')"
    }

    $compiler = Join-Path $stage3 'ablac.exe'
    $hello = Join-Path $work 'hello.exe'
    & $compiler build tests/cases/libc-imports/hello.ab --no-cache -o $hello
    if ((& $hello | Out-String).Trim() -cne 'hello') { throw 'Stage 3 hello output differs' }

    if ($Tier -eq 'native') {
        $probe = Join-Path $work 'native-site.exe'
        $trace = Join-Path $work 'native-site.log'
        try {
            & $compiler build tests/cases/compile-eval-jit/scalars.ab --no-cache -o $probe *> $trace
        } catch {
            Get-Content $trace -Tail 50 | Out-Host
            throw
        }
        if (!(Select-String -LiteralPath $trace -Quiet -Pattern '^note\[ct-jit\]: native at ')) {
            Get-Content $trace -Tail 50 | Out-Host
            throw 'Stage 3 did not execute a native compile-time site'
        }
        $PSNativeCommandUseErrorActionPreference = $false
        & $probe
        $result = $LASTEXITCODE
        $PSNativeCommandUseErrorActionPreference = $true
        if ($result -ne 42) { throw "Stage 3 native-site probe exited $result instead of 42" }
        $global:LASTEXITCODE = 0
    }
    Write-Host "Windows stage2 == stage3 ($Tier)"
} finally {
    Pop-Location
}
