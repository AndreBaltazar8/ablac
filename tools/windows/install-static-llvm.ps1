# Install the published LLVM and lld SDK after checking its pinned release hash.
param(
    [Parameter(Mandatory)][string]$Destination,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $true

$root = Join-Path $PSScriptRoot '../..'
$pinPath = if ($Architecture -eq 'arm64') { 'nix/llvm-windows-arm64-static-pin.json' } else { 'nix/llvm-windows-static-pin.json' }
$target = if ($Architecture -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
$pin = Get-Content -LiteralPath (Join-Path $root $pinPath) -Raw | ConvertFrom-Json
if ($pin.target -cne $target -or $pin.sha256 -cnotmatch '^[0-9a-f]{64}$') {
    throw 'Invalid Windows LLVM pin'
}
$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw "SDK destination already exists: $Destination" }
$parent = Split-Path -Parent $Destination
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$temp = Join-Path $parent ('.llvm-' + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $archive = Join-Path $temp 'llvm.tar.xz'
    Invoke-WebRequest $pin.url -OutFile $archive
    if ((Get-FileHash -Algorithm SHA256 $archive).Hash -ine $pin.sha256) {
        throw 'Windows LLVM archive does not match the pinned SHA-256'
    }
    $sdk = Join-Path $temp 'sdk'
    New-Item -ItemType Directory -Path $sdk | Out-Null
    & "$env:SystemRoot/System32/tar.exe" -xf $archive -C $sdk --strip-components 1
    $source = Get-Content (Join-Path $sdk 'SOURCE')
    if ("fdiv-patch-sha256=$($pin.patchSha256)" -cnotin $source -or
        "opt-utf8-patch-sha256=$($pin.optUtf8PatchSha256)" -cnotin $source -or
        "target=$target" -cnotin $source -or 'crt=MT' -cnotin $source) {
        throw 'Windows LLVM archive has unexpected target, patch or CRT metadata'
    }
    Move-Item -LiteralPath $sdk -Destination $Destination
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
