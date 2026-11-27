# Speed and size of the Windows compiler on Abla's own C library against the /MT one, on one runner
# (docs/design/windows-crt-free-compiler.md, step 7; .github/workflows/windows-crt-switch.yml). Both toolchain zips are
# unpacked, and with only System32 on the PATH, alternating between the two compilers each round:
#   - cold hello: tests/cases/libc-imports/hello.ab built --no-cache with a fresh cache directory, then run;
#   - cold JSON: tests/cases/alias-stdlib-json/main.ab the same way (it parses JSON and exits 42);
#   - self-build: src/orc_windows_main.ab compiled to its COFF object (the step that ends in the SDK link, as
#     check-compiler-fixpoint.ps1 does), with the source tree as the sysroot.
# Each time is the median of its rounds. The candidate fails when a median is more than -Tolerance slower than the
# baseline's, or its ablac.exe or zip is larger. The table goes to the job summary and measure.json to -Directory.
param(
    [Parameter(Mandatory)][string]$Baseline,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Directory,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [ValidateRange(1, 50)][int]$Rounds = 5,
    [ValidateRange(1, 10)][int]$SelfRounds = 2,
    [double]$Tolerance = 0.05
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$work = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Directory)
New-Item -ItemType Directory -Path $work | Out-Null
$bundle = if ($Architecture -eq 'arm64') { 'aarch64' } else { 'x86_64' }
$target = if ($Architecture -eq 'arm64') { 'aarch64-windows' } else { 'x86_64-windows-hosted' }

function Unpack([string]$Label, [string]$Archive) {
    $path = (Resolve-Path -LiteralPath $Archive).Path
    $destination = Join-Path $work $Label
    New-Item -ItemType Directory -Path $destination | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xf $path -C $destination
    if ($LASTEXITCODE -ne 0) { throw "could not unpack $Archive" }
    $ablac = Join-Path $destination "abla-toolchain-$bundle-windows/bin/ablac.exe"
    if (!(Test-Path -LiteralPath $ablac -PathType Leaf)) { throw "$Archive holds no bin/ablac.exe" }
    [pscustomobject]@{
        Label = $Label; Ablac = $ablac; Zip = (Get-Item $path).Length; Exe = (Get-Item $ablac).Length
        Hello = [Collections.Generic.List[double]]::new(); Json = [Collections.Generic.List[double]]::new()
        Self = [Collections.Generic.List[double]]::new()
    }
}

# One timed build with a fresh cache directory; the status must be $Expected.
function Time-Build([object]$Compiler, [string]$Sample, [string[]]$Arguments, [int]$Expected, [string]$Sysroot) {
    $cache = Join-Path $work "cache-$($Compiler.Label)-$Sample"
    $log = Join-Path $work "$($Compiler.Label)-$Sample.log"
    $env:ABLA_CACHE_DIR = $cache
    if ($Sysroot) { $env:ABLA_SYSROOT = $Sysroot } else { Remove-Item Env:ABLA_SYSROOT -ErrorAction Ignore }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    & $Compiler.Ablac @Arguments *> $log
    $clock.Stop()
    $status = $LASTEXITCODE
    Remove-Item -Recurse -Force -LiteralPath $cache -ErrorAction Ignore
    if ($status -ne $Expected) {
        Get-Content $log -Tail 30 | Out-Host
        throw "$($Compiler.Label) $Sample exited $status, not $Expected"
    }
    $clock.Elapsed.TotalSeconds
}

function Check-Run([string]$Program, [int]$Expected, [string]$Output) {
    $said = (& $Program | Out-String).Trim()
    if ($LASTEXITCODE -ne $Expected -or ($Output -and $said -cne $Output)) {
        throw "$Program exited $LASTEXITCODE with '$said'"
    }
}

function Median([Collections.Generic.List[double]]$Values) {
    $sorted = @($Values | Sort-Object)
    $middle = [math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return $sorted[$middle] }
    ($sorted[$middle - 1] + $sorted[$middle]) / 2
}

$compilers = @((Unpack 'baseline' $Baseline), (Unpack 'candidate' $Candidate))
$savedPath = $env:PATH
$env:PATH = "$env:SystemRoot\System32"
$env:ABLA_DEBUG = '0'
Push-Location $root
try {
    foreach ($compiler in $compilers) { & $compiler.Ablac --version | Out-Host }
    for ($round = 1; $round -le $Rounds; $round++) {
        # Alternate which compiler goes first, so neither always finds the other's file cache warm.
        $order = if ($round % 2) { $compilers } else { @($compilers[1], $compilers[0]) }
        foreach ($compiler in $order) {
            $hello = Join-Path $work "$($compiler.Label)-hello.exe"
            $compiler.Hello.Add((Time-Build $compiler "hello-$round" @('build', 'tests/cases/libc-imports/hello.ab', '--no-cache', '-o', $hello) 0 ''))
            Check-Run $hello 0 'hello'
            $json = Join-Path $work "$($compiler.Label)-json.exe"
            $compiler.Json.Add((Time-Build $compiler "json-$round" @('build', 'tests/cases/alias-stdlib-json/main.ab', '--no-cache', '-o', $json) 0 ''))
            Check-Run $json 42 'alias ok'
        }
    }
    for ($round = 1; $round -le $SelfRounds; $round++) {
        $order = if ($round % 2) { $compilers } else { @($compilers[1], $compilers[0]) }
        foreach ($compiler in $order) {
            $self = Join-Path $work "$($compiler.Label)-self/ablac.exe"
            New-Item -ItemType Directory -Force -Path (Split-Path $self) | Out-Null
            # Status 1: the program link stops without the compiler's CRT and LLVM, after the object (as in the fixpoint check).
            $seconds = Time-Build $compiler "self-$round" @('build', 'src/orc_windows_main.ab', '--target', $target, '--no-cache', '-o', $self) 1 $root
            if (!(Test-Path -LiteralPath "$self.o" -PathType Leaf)) { throw "$($compiler.Label) self-build wrote no object" }
            Remove-Item -Recurse -Force -LiteralPath (Split-Path $self)
            $compiler.Self.Add($seconds)
        }
    }
} finally {
    Pop-Location
    $env:PATH = $savedPath
}

$base = $compilers[0]
$cand = $compilers[1]
$rows = @(
    @{ Name = 'cold hello (s)'; Base = (Median $base.Hello); Cand = (Median $cand.Hello); Time = $true },
    @{ Name = 'cold JSON (s)'; Base = (Median $base.Json); Cand = (Median $cand.Json); Time = $true },
    @{ Name = 'self-build object (s)'; Base = (Median $base.Self); Cand = (Median $cand.Self); Time = $true },
    @{ Name = 'ablac.exe (bytes)'; Base = $base.Exe; Cand = $cand.Exe; Time = $false },
    @{ Name = 'toolchain zip (bytes)'; Base = $base.Zip; Cand = $cand.Zip; Time = $false }
)
$failures = @()
$table = @("| $Architecture | /MT | Abla C library | change | verdict |", '|---|---:|---:|---:|---|')
foreach ($row in $rows) {
    $limit = if ($row.Time) { $row.Base * (1 + $Tolerance) } else { $row.Base }
    $ok = $row.Cand -le $limit
    if (!$ok) { $failures += $row.Name }
    $change = if ($row.Base) { '{0:+0.0;-0.0;0.0}%' -f (100 * ($row.Cand - $row.Base) / $row.Base) } else { 'n/a' }
    $format = if ($row.Time) { '{0:0.000}' } else { '{0:N0}' }
    $table += "| $($row.Name) | $($format -f $row.Base) | $($format -f $row.Cand) | $change | $(if ($ok) { 'ok' } else { 'WORSE' }) |"
}
$table | Out-Host
if ($env:GITHUB_STEP_SUMMARY) { ($table + '') | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }
[ordered]@{
    architecture = $Architecture; rounds = $Rounds; selfRounds = $SelfRounds; tolerance = $Tolerance
    baseline = [ordered]@{ hello = $base.Hello; json = $base.Json; self = $base.Self; exe = $base.Exe; zip = $base.Zip }
    candidate = [ordered]@{ hello = $cand.Hello; json = $cand.Json; self = $cand.Self; exe = $cand.Exe; zip = $cand.Zip }
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $work 'measure.json')
if ($failures.Count) { throw "The Abla C library compiler is worse than /MT in: $($failures -join ', ')" }
Write-Host "Abla C library compiler ($Architecture): no worse than /MT in speed (tolerance $Tolerance) or size"
