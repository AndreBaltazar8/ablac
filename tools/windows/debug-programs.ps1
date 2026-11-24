# Run the --backtrace builds of the programs that tests/cases/windows/programs.txt marks `wine` (they fail on the Windows runner and are
# not checked there) and print everything about each: the exit status, what it printed on stdout and stderr, and, when its stack
# printed addresses, the stack symbolized to file:line (llvm-symbolizer follows the image's debug link to <name>.exe.debug).
# This only reports (it exits 0): the point is to see the failure.
# tools/windows/debug-programs.ps1 -Programs build/windows-debug
param([Parameter(Mandatory = $true)][string]$Programs)
$ErrorActionPreference = 'Continue'
$symbolizer = (Get-Command llvm-symbolizer -ErrorAction SilentlyContinue).Source
if (-not $symbolizer) { $symbolizer = 'C:\Program Files\LLVM\bin\llvm-symbolizer.exe' }
foreach ($image in (Get-ChildItem -LiteralPath $Programs -Filter '*.exe' | Sort-Object Name)) {
    $name = $image.BaseName
    "=== $name"
    $work = Join-Path $Programs "$name.run"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $stdout = Join-Path $work 'out.txt'
    $stderr = Join-Path $work 'err.txt'
    $process = Start-Process -FilePath $image.FullName -WorkingDirectory $work -PassThru -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    if (-not $process.WaitForExit(120000)) { $process.Kill(); 'killed after 120 s' }
    $code = $process.ExitCode
    "exit code $code ($('0x{0:X8}' -f ([uint32]($code -band 0xFFFFFFFF))))"
    '--- stdout'
    Get-Content -LiteralPath $stdout -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }
    '--- stderr'
    $report = @(Get-Content -LiteralPath $stderr -ErrorAction SilentlyContinue)
    $report | ForEach-Object { "  $_" }
    $loadLine = $report | Where-Object { $_ -match '^load address 0x' } | Select-Object -First 1
    $frames = @($report | Where-Object { $_ -match '^0x[0-9a-f]+ in ' })
    if ($loadLine -and $frames.Count -gt 0 -and (Test-Path -LiteralPath $symbolizer)) {
        $bytes = [IO.File]::ReadAllBytes($image.FullName)
        $header = [BitConverter]::ToInt32($bytes, 60)
        $base = [BitConverter]::ToUInt64($bytes, $header + 48)
        $load = [Convert]::ToUInt64(($loadLine -replace '^load address 0x', ''), 16)
        $addresses = $frames | ForEach-Object {
            $address = [Convert]::ToUInt64(($_ -split ' ')[0].Substring(2), 16)
            '0x{0:x}' -f ($address - $load + $base)
        }
        '--- symbolized stack'
        & $symbolizer "--obj=$($image.FullName)" --inlining --pretty-print @addresses | ForEach-Object { "  $_" }
    } elseif ($frames.Count -eq 0 -and $code -ne 0 -and $code -ne 42) {
        '(no stack on stderr: the exception handler did not run, or ran out of stack)'
    }
}
$global:LASTEXITCODE = 0
exit 0
