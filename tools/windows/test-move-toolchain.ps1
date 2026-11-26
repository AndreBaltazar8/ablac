# The toolchain move of tools/windows/move-toolchain.ps1 (used by exercise-toolchain.ps1) under a failure that Defender or an indexer causes on Windows
# (ERROR_SHARING_VIOLATION on a file of the tree):
#   - retried: two sharing violations, then the move completes: the whole tree is at the target and the source is gone (the move that was here
#     left a partial target behind, and its retry moved the source INTO it: release run 45694527287);
#   - partial: a mover that fails after copying half of the tree to the target: the partial target is removed before the retry, so the final
#     layout is the tree's own, with no nested copy;
#   - exhausted: the violation never clears: after the bounded retries the move fails, naming both paths, and the source is intact;
#   - other: an error that is not a sharing violation is thrown at once, with no retry;
#   - exists: a target that exists before the move is refused;
#   - real (Windows only): a file of the tree held open without FileShare.Delete makes Directory.Move itself fail with a sharing violation, and the
#     move completes when the handle is released between attempts.
# Run it with pwsh from anywhere; any failed check throws.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'move-toolchain.ps1')
function Check([bool]$condition, [string]$message) { if (!$condition) { throw "test-move-toolchain: $message" } }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('move-toolchain-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$fast = @(1, 1, 1, 1, 1)
function New-Tree([string]$name) {
    $top = Join-Path $temp $name
    New-Item -ItemType Directory -Path (Join-Path $top 'bin'), (Join-Path $top 'share') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $top 'bin\ablac.exe') -Value 'binary'
    Set-Content -LiteralPath (Join-Path $top 'share\stdlib.ab') -Value 'stdlib'
    $top
}
function New-Violation { [IO.IOException]::new('The process cannot access the file because it is being used by another process.', [int]0x80070020) }
try {
    # retried
    $source = New-Tree 'retried'; $target = Join-Path $temp 'relocated\retried target'
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    $script:calls = 0
    Move-Toolchain $source $target { param($from, $to) $script:calls++; if ($script:calls -le 2) { throw (New-Violation) }; [IO.Directory]::Move($from, $to) } $fast
    Check ($script:calls -eq 3) "retried: expected 3 attempts, got $($script:calls)"
    Check (Test-Path -LiteralPath (Join-Path $target 'bin\ablac.exe')) 'retried: bin\ablac.exe is not at the target'
    Check (Test-Path -LiteralPath (Join-Path $target 'share\stdlib.ab')) 'retried: share\stdlib.ab is not at the target'
    Check (!(Test-Path -LiteralPath $source)) 'retried: the source is still there'

    # partial
    $source = New-Tree 'partial'; $target = Join-Path $temp 'relocated\partial target'
    $script:calls = 0
    Move-Toolchain $source $target {
        param($from, $to)
        $script:calls++
        if ($script:calls -eq 1) {
            New-Item -ItemType Directory -Path (Join-Path $to 'bin') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $from 'bin\ablac.exe') -Destination (Join-Path $to 'bin\ablac.exe')
            throw (New-Violation)
        }
        [IO.Directory]::Move($from, $to)
    } $fast
    Check (Test-Path -LiteralPath (Join-Path $target 'bin\ablac.exe')) 'partial: bin\ablac.exe is not at the target'
    Check (Test-Path -LiteralPath (Join-Path $target 'share\stdlib.ab')) 'partial: share\stdlib.ab is not at the target'
    Check (!(Test-Path -LiteralPath (Join-Path $target 'partial'))) 'partial: the source was moved into the partial target'
    Check (!(Test-Path -LiteralPath $source)) 'partial: the source is still there'

    # exhausted
    $source = New-Tree 'exhausted'; $target = Join-Path $temp 'relocated\exhausted target'
    $script:calls = 0
    $message = ''
    try { Move-Toolchain $source $target { param($from, $to) $script:calls++; throw (New-Violation) } @(1, 1) } catch { $message = $_.Exception.Message }
    Check ($message -like '*could not move*exhausted*') "exhausted: the failure does not name the move: '$message'"
    Check ($script:calls -eq 3) "exhausted: expected 3 attempts (1 + 2 retries), got $($script:calls)"
    Check (Test-Path -LiteralPath (Join-Path $source 'bin\ablac.exe')) 'exhausted: the source is not intact'
    Check (!(Test-Path -LiteralPath $target)) 'exhausted: a target was left'

    # other
    $source = New-Tree 'other'; $target = Join-Path $temp 'relocated\other target'
    $script:calls = 0
    $message = ''
    try { Move-Toolchain $source $target { param($from, $to) $script:calls++; throw [IO.DirectoryNotFoundException]::new('gone') } $fast } catch { $message = $_.Exception.Message }
    Check ($message -eq 'gone') "other: the error was changed: '$message'"
    Check ($script:calls -eq 1) "other: retried a non-sharing error ($($script:calls) attempts)"

    # denied: what Windows throws for a directory with an open file below it
    $source = New-Tree 'denied'; $target = Join-Path $temp 'relocated\denied target'
    $script:calls = 0
    Move-Toolchain $source $target {
        param($from, $to)
        $script:calls++
        if ($script:calls -lt 3) { throw [UnauthorizedAccessException]::new('Access to the path is denied.') }
        [IO.Directory]::Move($from, $to)
    } $fast
    Check ($script:calls -eq 3) "denied: expected 3 attempts, got $($script:calls)"
    Check (Test-Path -LiteralPath (Join-Path $target 'bin\ablac.exe')) 'denied: bin\ablac.exe is not at the target'

    # denied as .NET's directory move reports it: an IOException with HRESULT ERROR_ACCESS_DENIED (the held-file case on a Windows runner)
    $source = New-Tree 'denied-io'; $target = Join-Path $temp 'relocated\denied-io target'
    $script:calls = 0
    Move-Toolchain $source $target {
        param($from, $to)
        $script:calls++
        if ($script:calls -lt 3) { throw [IO.IOException]::new('Access to the path is denied.', [int]0x80070005) }
        [IO.Directory]::Move($from, $to)
    } $fast
    Check ($script:calls -eq 3) "denied-io: expected 3 attempts, got $($script:calls)"
    Check (Test-Path -LiteralPath (Join-Path $target 'bin\ablac.exe')) 'denied-io: bin\ablac.exe is not at the target'

    # denied for good: bounded, and the failure names both paths
    $source = New-Tree 'denied-stays'; $target = Join-Path $temp 'relocated\denied-stays target'
    $script:calls = 0
    $message = ''
    try { Move-Toolchain $source $target { param($from, $to) $script:calls++; throw [UnauthorizedAccessException]::new('Access to the path is denied.') } @(1, 1) } catch { $message = $_.Exception.Message }
    Check ($message -like '*could not move*denied*') "denied-stays: the failure does not name the move: '$message'"
    Check ($script:calls -eq 3) "denied-stays: expected 3 attempts, got $($script:calls)"

    # exists
    $source = New-Tree 'exists'; $target = New-Tree 'exists-target'
    $message = ''
    try { Move-Toolchain $source $target { param($from, $to) throw 'must not run' } $fast } catch { $message = $_.Exception.Message }
    Check ($message -like '*exists before the move*') "exists: an existing target was not refused: '$message'"

    # real: Windows' own sharing violation on a held file
    if ($IsWindows) {
        $source = New-Tree 'real'; $target = Join-Path $temp 'relocated\real target'
        $script:held = [IO.File]::Open((Join-Path $source 'bin\ablac.exe'), 'Open', 'Read', 'Read')
        $script:calls = 0
        $script:sawViolation = 0
        try {
            Move-Toolchain $source $target {
                param($from, $to)
                $script:calls++
                if ($script:calls -eq 3 -and $null -ne $script:held) { $script:held.Dispose(); $script:held = $null }
                try { [IO.Directory]::Move($from, $to) }
                # `throw $_` keeps the exception chain; a bare `throw` wraps it in a ParentContainsErrorRecordException with no inner exception.
                catch {
                    $inner = $_.Exception
                    while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
                    Write-Host "real: attempt $($script:calls) failed with $($inner.GetType().FullName) HResult 0x$('{0:X8}' -f $inner.HResult): $($inner.Message)"
                    if (Test-RetryableMoveFailure $_.Exception) { $script:sawViolation++ }
                    throw $_
                }
            } @(100, 100, 100, 100)
        } finally { if ($null -ne $script:held) { $script:held.Dispose() } }
        Check ($script:sawViolation -ge 2) "real: Windows did not report a sharing violation for the held file ($($script:sawViolation))"
        Check (Test-Path -LiteralPath (Join-Path $target 'bin\ablac.exe')) 'real: bin\ablac.exe is not at the target'
        Check (!(Test-Path -LiteralPath $source)) 'real: the source is still there'
    } else {
        Write-Host 'test-move-toolchain: the real held-file case needs Windows (skipped)'
    }
    Write-Host 'test-move-toolchain: the toolchain move is retried on a sharing violation, never nests into a partial target, fails clearly when the violation stays, and is verified'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
