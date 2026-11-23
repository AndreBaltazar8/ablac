# Run hosted Windows programs, cross-built on Linux, on a native Windows runner and compare each one's output with what the same program
# printed built natively for Linux (<name>.expected) and its exit status with <name>.status (0 when there is none). Two sets use it:
# tests/cases/windows/hosted (tools/test-windows-hosted.sh, with arguments) and the standard-library programs of
# tests/cases/windows/programs.txt (tools/test-windows-programs.sh). Wine runs the same images in those scripts; this is the truth for
# what Wine only approximates.
param(
    [Parameter(Mandatory)][string]$Programs,
    [string]$Logs = 'build/windows-hosted-logs',
    [string[]]$Arguments = @()
)
$ErrorActionPreference = 'Stop'
$Programs = (Resolve-Path -LiteralPath $Programs).Path
New-Item -ItemType Directory -Path $Logs -Force | Out-Null
$Logs = (Resolve-Path -LiteralPath $Logs).Path

# The images and outputs are the ones the Linux job built: every file in SHA256SUMS must match, and no image may be missing from it.
$verified = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $Programs 'SHA256SUMS')) {
    if ($line -notmatch '^([a-f0-9]{64})  ([a-z0-9.-]+)$') { throw "Invalid SHA256SUMS row $line" }
    $actual = (Get-FileHash -LiteralPath (Join-Path $Programs $Matches[2]) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Matches[1]) { throw "$($Matches[2]) hash differs from the Linux artifact" }
    $verified[$Matches[2]] = $true
}
$images = @(Get-ChildItem -LiteralPath $Programs -Filter '*.exe' | Sort-Object Name)
foreach ($image in $images) {
    if (-not $verified.ContainsKey($image.Name)) { throw "$($image.Name) has no Linux artifact hash" }
}

# The environment and arguments tools/test-windows-hosted.sh gave the Linux run.
$env:ABLA_WINDOWS_TEST = 'two words and = signs'
$env:ABLA_WINDOWS_UNICODE = 'héllo €'

$failed = @()
foreach ($image in $images) {
    # <name>.<mode>.exe prints what <name>.expected holds.
    $name = $image.BaseName -replace '\.(fast|release)$', ''
    $label = $image.BaseName
    $expectedPath = Join-Path $Programs "$name.expected"
    if (-not $verified.ContainsKey("$name.expected")) { throw "$name.expected has no Linux artifact hash" }
    $expected = [IO.File]::ReadAllText($expectedPath, [Text.UTF8Encoding]::new($false))
    $wanted = 0
    if ($verified.ContainsKey("$name.status")) { $wanted = [int](Get-Content -LiteralPath (Join-Path $Programs "$name.status") -Raw) }
    # Each program starts in a directory of its own: files.exe makes and removes one beside it.
    $directory = Join-Path $Logs $label
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $image.FullName
    $start.WorkingDirectory = $directory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill($true)
            "${label}: timed out"
            $failed += $label
            continue
        }
        $process.WaitForExit()
        $out = $stdout.GetAwaiter().GetResult().Replace("`r`n", "`n")
        $err = $stderr.GetAwaiter().GetResult().Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $Logs "$label.out"), $out)
        [IO.File]::WriteAllText((Join-Path $Logs "$label.err"), $err)
        $status = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($status -ne $wanted) {
        "${label}: exit status $status, expected $wanted. stderr: $err"
        $failed += $label
    } elseif ($out -cne $expected) {
        "${label}: the output differs from the Linux run"
        '--- expected'
        $expected
        '--- actual'
        $out
        $failed += $label
    } else {
        "${label}: ok in $([int]$timer.Elapsed.TotalMilliseconds) ms"
    }
}
if ($images.Count -eq 0) { throw 'no hosted programs in the artifact' }
if ($failed.Count -gt 0) { throw "failed: $($failed -join ', ')" }
"$($images.Count) hosted programs print what the Linux programs print"
