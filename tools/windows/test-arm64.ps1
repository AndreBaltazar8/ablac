# Run the Linux-built ARM64 images on a native Windows runner.
param(
    [Parameter(Mandatory)][string]$Programs,
    [string]$Logs = 'build/windows-arm64-logs'
)
$ErrorActionPreference = 'Stop'
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::Arm64) {
    throw 'The Windows ARM64 tests require an ARM64 operating system'
}
$Programs = (Resolve-Path -LiteralPath $Programs).Path
New-Item -ItemType Directory -Path $Logs -Force | Out-Null
$Logs = (Resolve-Path -LiteralPath $Logs).Path
$verified = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $Programs 'SHA256SUMS')) {
    if ($line -notmatch '^([a-f0-9]{64})  ([a-z0-9.-]+)$') { throw "Invalid SHA256SUMS row $line" }
    $expected = $Matches[1]
    $file = $Matches[2]
    $actual = (Get-FileHash -LiteralPath (Join-Path $Programs $file) -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "$file hash differs from the Linux artifact" }
    $verified[$file] = $true
}
foreach ($file in 'files.expected', 'crash.exe.debug') {
    if (-not $verified.ContainsKey($file)) { throw "$file has no Linux artifact hash" }
}
$env:ABLA_WINDOWS_TEST = 'two words and = signs'
$env:ABLA_WINDOWS_UNICODE = 'héllo €'
Remove-Item Env:ABLA_WINDOWS_TEST_UNSET -ErrorAction SilentlyContinue

function Invoke-Program {
    param([string]$Name, [int]$Status, [string[]]$Arguments = @())
    $label = (@($Name) + $Arguments) -join '-'
    $label = $label -replace '[^a-z0-9.-]', '_'
    if (-not $verified.ContainsKey("$Name.exe")) { throw "$Name.exe has no Linux artifact hash" }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $Programs "$Name.exe"
    $start.WorkingDirectory = $Logs
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill($true)
            throw "$label timed out"
        }
        $out = $stdout.GetAwaiter().GetResult().Replace("`r`n", "`n")
        $err = $stderr.GetAwaiter().GetResult().Replace("`r`n", "`n")
        [IO.File]::WriteAllText((Join-Path $Logs "$label.out"), $out)
        [IO.File]::WriteAllText((Join-Path $Logs "$label.err"), $err)
        if ($process.ExitCode -ne $Status) {
            throw "$label exited $($process.ExitCode), expected $Status. stderr: $err"
        }
        Write-Host "$label exited $Status"
        return @{ Out = $out; Err = $err }
    } finally {
        $process.Dispose()
    }
}

foreach ($name in 'hello-fast', 'hello') {
    if ((Invoke-Program $name 0).Out -cne "5 item 4`n") { throw "$name output differed" }
}
if ((Invoke-Program 'args' 0 @('one', 'two words', 'three')).Out -cne "count 3`n[one]`n[two words]`n[three]`n") {
    throw 'Arguments output differed'
}
if ((Invoke-Program 'environment' 0).Out -cne "found [two words and = signs]`nother [(none)]`nunicode [héllo €]`n") {
    throw 'Environment output differed'
}
$files = Get-Content -LiteralPath (Join-Path $Programs 'files.expected') -Raw -Encoding utf8
if ((Invoke-Program 'files' 0).Out -cne $files) { throw 'Files output differed' }
if ((Invoke-Program 'threads' 0).Out -cne "workers 1 2 3`n") { throw 'Threads output differed' }
$null = Invoke-Program 'tls' 42
$null = Invoke-Program 'stack-probe' 42
if ((Invoke-Program 'stm' 42).Out -notmatch '^single thread: 0 failed,') { throw 'STM output differed' }
$fault = (Invoke-Program 'crash' -1073741819 @('store')).Err
if ($fault -notmatch '(?m)^fatal signal: a bad memory access at 0x0000000000000010$' -or
    $fault -notmatch '(?m)^0x[0-9a-f]+ in main$') {
    throw "Access violation or ARM64 unwind report differed: $fault"
}
if ((Invoke-Program 'crash' 101 @('overflow')).Err -notmatch '(?m)^panic: stack overflow$') {
    throw 'Stack overflow diagnostic differed'
}
if ((Invoke-Program 'crash' 101 @('thread-panic')).Err -notmatch '(?m)^0x[0-9a-f]+ in abla_runtime_thread_entry$') {
    throw 'Worker panic stack omitted its thread entry'
}
