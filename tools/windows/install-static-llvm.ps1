# Install the published LLVM and lld SDK after checking its pinned release hash.
param([Parameter(Mandatory)][string]$Destination)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $true

$root = Join-Path $PSScriptRoot '../..'
$pin = Get-Content (Join-Path $root 'nix/llvm-windows-static-pin.json') -Raw | ConvertFrom-Json
if ($pin.target -cne 'x86_64-pc-windows-msvc' -or $pin.sha256 -cnotmatch '^[0-9a-f]{64}$') {
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
        "opt-utf8-patch-sha256=$($pin.optUtf8PatchSha256)" -cnotin $source -or 'crt=MT' -cnotin $source) {
        throw 'Windows LLVM archive has unexpected patch or CRT metadata'
    }
    Move-Item -LiteralPath $sdk -Destination $Destination
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
