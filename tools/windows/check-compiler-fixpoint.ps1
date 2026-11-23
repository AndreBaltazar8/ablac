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

function Get-SectionSignatures([string]$Path) {
    $description = (& $readobj --sections --section-relocations $Path) -join "`n"
    $sections = [regex]::Matches($description, '(?ms)^  Section \{\n(.*?)^  \}')
    if (!$sections.Count) { throw "No COFF sections in $Path" }

    $signatures = [Collections.Generic.Dictionary[string,Collections.Generic.List[string]]]::new()
    $file = [IO.File]::OpenRead($Path)
    try {
        foreach ($section in $sections) {
            $fields = $section.Groups[1].Value
            $name = [regex]::Match($fields, '(?m)^    Name: (.+) \([0-9A-Fa-f ]+\)$').Groups[1].Value
            $size = [regex]::Match($fields, '(?m)^    RawDataSize: (\d+)$')
            $offset = [regex]::Match($fields, '(?m)^    PointerToRawData: 0x([0-9A-Fa-f]+)$')
            if (!$name -or !$size.Success -or !$offset.Success) { throw "Incomplete section information in $Path" }

            $position = [Convert]::ToInt64($offset.Groups[1].Value, 16)
            $sizeInBytes = [int]$size.Groups[1].Value
            $hash = ''
            if ($position -ne 0 -and $sizeInBytes -ne 0) {
                $bytes = [byte[]]::new($sizeInBytes)
                $file.Position = $position
                $file.ReadExactly($bytes, 0, $bytes.Length)
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            }
            # Keep relocation records and section attributes, but ignore physical
            # file offsets that can shift when a preceding section changes size.
            $metadata = $fields -creplace '(?m)^    (?:Number|PointerTo(?:RawData|Relocations|LineNumbers)): .*\n', ''
            if (!$signatures.ContainsKey($name)) {
                $signatures[$name] = [Collections.Generic.List[string]]::new()
            }
            $signatures[$name].Add("$metadata$hash")
        }
    } finally {
        $file.Dispose()
    }
    return ,$signatures
}

function Show-SectionDifferences([string]$Name, [string]$Second, [string]$Third) {
    try {
        $left = Get-SectionSignatures $Second
        $right = Get-SectionSignatures $Third
        $names = (@($left.Keys) + @($right.Keys)) | Sort-Object -Unique -CaseSensitive
        $changed = foreach ($section in $names) {
            if (($left[$section] -join "`n") -cne ($right[$section] -join "`n")) { $section }
        }
        if ($changed) {
            Write-Host "$Name differing sections: $($changed -join ', ')"
        } else {
            Write-Host "$Name section contents and metadata match. The difference is outside the compared sections."
        }
    } catch {
        Write-Warning "Could not compare $Name sections: $_"
    }
}

function Test-NativeSite([string]$Compiler, [string]$Label) {
    $directory = Join-Path $work "native-$Label"
    New-Item -ItemType Directory -Path $directory | Out-Null
    $probe = Join-Path $directory 'scalar-site.exe'
    $trace = Join-Path $directory 'compile.log'
    try {
        & $Compiler build tests/cases/compile-eval-jit/scalars.ab --no-cache -o $probe *> $trace
    } catch {
        Get-Content $trace -Tail 50 | Out-Host
        throw
    }
    $native = @(Select-String -LiteralPath $trace -Pattern '^note\[ct-jit\]: native at ')
    if (!$native.Count) {
        Get-Content $trace -Tail 50 | Out-Host
        throw "$Label did not execute a native compile-time site"
    }
    $PSNativeCommandUseErrorActionPreference = $false
    & $probe
    $result = $LASTEXITCODE
    if ($result -ne 42) { throw "$Label native-site probe exited $result instead of 42" }
    $global:LASTEXITCODE = 0
    Write-Host "$Label executed $($native.Count) native compile-time sites"
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
    if ($Tier -eq 'native') { Test-NativeSite $seed 'seed' }
    Build-Stage $seed $stage2
    $secondCompiler = Join-Path $stage2 'ablac.exe'
    if ($Tier -eq 'native') { Test-NativeSite $secondCompiler 'stage2' }
    Build-Stage $secondCompiler $stage3
    $different = @()
    foreach ($file in 'coff/ablac.exe.o', 'coff/ablac.exe.imports/exports.def', 'ablac.exe') {
        $secondPath = Join-Path $stage2 $file
        $thirdPath = Join-Path $stage3 $file
        $second = (Get-FileHash $secondPath).Hash
        $third = (Get-FileHash $thirdPath).Hash
        Write-Host "$file stage2 $second, stage3 $third"
        if ($second -cne $third) {
            $different += $file
            if ($file -ne 'coff/ablac.exe.imports/exports.def') {
                Show-SectionDifferences $file $secondPath $thirdPath
            }
        }
    }
    if ($different.Count) {
        throw "Stage 2 and stage 3 differ in $($different -join ', ')"
    }

    $compiler = Join-Path $stage3 'ablac.exe'
    $hello = Join-Path $work 'hello.exe'
    & $compiler build tests/cases/libc-imports/hello.ab --no-cache -o $hello
    if ((& $hello | Out-String).Trim() -cne 'hello') { throw 'Stage 3 hello output differs' }

    if ($Tier -eq 'native') { Test-NativeSite $compiler 'stage3' }
    Write-Host "Windows stage2 == stage3 ($Tier)"
} finally {
    Pop-Location
}
