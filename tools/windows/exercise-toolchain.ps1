# Exercise the packaged Windows toolchain the way a user's runner would (release.yml, windows-exercise): unpack
# abla-toolchain-x86_64-windows.zip, then with a PATH that holds nothing but System32 (no clang, no lld-link, no LLVM, no git, no
# Windows SDK) from a directory that is not the toolchain's
#   - `bin\ablac.exe --version` prints `ablac <version>` (the version the release was built as);
#   - a hello-world program builds and runs and prints what it should;
#   - a program that imports a project module builds and runs;
#   - `--backtrace` builds (the packaged llvm-objcopy.exe is found beside ablac.exe, with no PATH to find it by);
#   - the toolchain moved to another directory still works (it finds its sysroot beside its own image).
# Any failure stops with a message naming the step.
param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Version
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Fail([string]$message) { throw "windows toolchain: $message" }
function Run([string]$exe, [string[]]$arguments, [string]$step) {
    $output = & $exe @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$step failed ($LASTEXITCODE):`n$output" }
    $output
}

$temp = Join-Path $env:RUNNER_TEMP ('toolchain-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$first = Join-Path $temp 'first'
New-Item -ItemType Directory -Path $first | Out-Null
& "$env:SystemRoot\System32\tar.exe" -xf (Resolve-Path -LiteralPath $Archive).Path -C $first
if ($LASTEXITCODE -ne 0) { Fail 'the archive does not unpack' }
$top = Join-Path $first 'abla-toolchain-x86_64-windows'
foreach ($required in 'bin\ablac.exe', 'bin\llvm-objcopy.exe', 'share\abla\stdlib', 'share\abla\runtime\windows\imports\kernel32.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $top $required))) { Fail "the package has no $required" }
}

# Nothing on the PATH but Windows itself: the toolchain must bring everything.
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
foreach ($name in 'ABLA_SYSROOT', 'ABLA_HOME', 'ABLA_LLVM', 'ABLA_LLVM_TOOLS', 'ABLA_LLD') { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
foreach ($tool in 'clang', 'lld-link', 'llvm-objcopy', 'link', 'cl', 'git') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Fail "$tool is still on the PATH; the exercise would not prove the package is self-contained" }
}

function Check-Toolchain([string]$root, [string]$label) {
    $ablac = Join-Path $root 'bin\ablac.exe'
    $reported = (Run $ablac @('--version') "$label --version").Trim()
    if ($reported -cne "ablac $Version") { Fail "$label --version printed '$reported', not 'ablac $Version'" }
    $work = Join-Path $temp "work-$label"
    New-Item -ItemType Directory -Path $work | Out-Null
    Set-Location $work
    Set-Content -Path hello.ab -Encoding ascii -Value @'
import "abla/io"
fun main { println("hello from abla on windows") }
'@
    Run $ablac @('build', 'hello.ab', '-o', 'hello.exe', '--no-cache') "$label build hello" | Out-Null
    $said = (Run (Join-Path $work 'hello.exe') @() "$label run hello").Trim()
    if ($said -cne 'hello from abla on windows') { Fail "$label hello printed '$said'" }
    Set-Content -Path helper.ab -Encoding ascii -Value 'fun answer(): int = 41 + 1'
    Set-Content -Path project.ab -Encoding ascii -Value @'
import "abla/io"
import "helper.ab"
fun main { println("answer ${answer()}") }
'@
    Run $ablac @('build', 'project.ab', '-o', 'project.exe', '--no-cache') "$label build project" | Out-Null
    $said = (Run (Join-Path $work 'project.exe') @() "$label run project").Trim()
    if ($said -cne 'answer 42') { Fail "$label project printed '$said'" }
    Run $ablac @('build', 'hello.ab', '-o', 'hello-backtrace.exe', '--no-cache', '--backtrace') "$label build --backtrace" | Out-Null
    $said = (Run (Join-Path $work 'hello-backtrace.exe') @() "$label run --backtrace hello").Trim()
    if ($said -cne 'hello from abla on windows') { Fail "$label --backtrace hello printed '$said'" }
}

Check-Toolchain $top 'unpacked'
# Moved to another directory (and another name for the parent): the sysroot is found beside the image, not by where it was unpacked.
$second = Join-Path $temp 'relocated\somewhere else'
New-Item -ItemType Directory -Path (Split-Path -Parent $second) -Force | Out-Null
Move-Item -LiteralPath $top -Destination $second
Check-Toolchain $second 'moved'
Write-Host "windows toolchain: ablac $Version builds and runs programs from the unpacked and the moved toolchain with only System32 on the PATH"
