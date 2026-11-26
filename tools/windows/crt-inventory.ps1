# The C runtime inventory of the Windows compiler (docs/design/windows-crt-free-compiler.md): measurement only. Run after
# build-static-compiler.ps1 -CrtInventory has configured the build directory with the inventory targets. Links
# ablac-crt-map (a /lldmap map and lld's /verbose log of the archive members it loaded, and for which symbol) and the four
# leave-one-out links (no libucrt, no libucrt and libcmt, no libvcruntime, no libcpmt), which are expected to fail and
# list every symbol the archive left out had provided. Writes <build>/crt-inventory/: the logs, members.tsv, bytes.tsv,
# undefined-<probe>.txt and summary.md. Never fails because a probe does not link.
param(
    [Parameter(Mandatory)][string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'
# A probe link is expected to fail: its exit code is recorded, not thrown (the caller turns that on for native commands).
$PSNativeCommandUseErrorActionPreference = $false
$build = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDirectory)
$out = Join-Path $build 'crt-inventory'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# The archive's file name from a path such as C:\...\libucrt.lib (or the object's, for a plain object).
function Get-ArchiveName([string]$path) {
    return ($path.Trim() -split '[\\/]')[-1]
}

# 1. The map link. Its output (with /verbose) is the member log.
$mapLog = Join-Path $out 'map-link.log'
& cmake --build $build --target ablac-crt-map *> $mapLog
$mapStatus = $LASTEXITCODE
"map link exit code: $mapStatus" | Out-File -Append -Encoding utf8 $mapLog

# lld's /verbose says "Loaded <archive>(<member>) for <symbol>" for every member it pulls in.
$members = foreach ($line in Get-Content $mapLog) {
    if ($line -match 'Loaded (.+?\.lib)\((.+?)\) for (.+)$') {
        [pscustomobject]@{ Archive = (Get-ArchiveName $Matches[1]); Member = $Matches[2]; Symbol = $Matches[3].Trim() }
    }
}
$members | ForEach-Object { "$($_.Archive)`t$($_.Member)`t$($_.Symbol)" } | Out-File -Encoding utf8 (Join-Path $out 'members.tsv')

# The map's input-section lines: "<address> <size> <align>  <archive>(<member>):(<section>)"; bytes per archive.
$bytes = @{}
$map = Join-Path $out 'ablac.map'
if (Test-Path $map) {
    foreach ($line in Get-Content $map) {
        if ($line -match '^\s*[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+\d+\s+(.+?\.lib)\(.+?\):\(') {
            $archive = Get-ArchiveName $Matches[2]
            $bytes[$archive] = [long]$bytes[$archive] + [Convert]::ToInt64($Matches[1], 16)
        }
    }
}
$bytes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key)`t$($_.Value)" } |
    Out-File -Encoding utf8 (Join-Path $out 'bytes.tsv')

# 2. The leave-one-out links: "undefined symbol: <name>" for each name the archive left out had provided.
$probes = 'ablac-crt-no-ucrt', 'ablac-crt-no-ucrt-cmt', 'ablac-crt-no-vcruntime', 'ablac-crt-no-cpmt'
$undefined = @{}
foreach ($probe in $probes) {
    $log = Join-Path $out "$probe.log"
    & cmake --build $build --target $probe *> $log
    "link exit code: $LASTEXITCODE" | Out-File -Append -Encoding utf8 $log
    $names = @(Get-Content $log | ForEach-Object { if ($_ -match 'undefined symbol: (.+)$') { $Matches[1].Trim() } } | Sort-Object -Unique)
    $names | Out-File -Encoding utf8 (Join-Path $out "undefined-$probe.txt")
    $undefined[$probe] = $names
}

# 3. The summary.
$crt = 'libucrt.lib', 'libcmt.lib', 'libvcruntime.lib', 'libcpmt.lib'
$summary = @('# Windows compiler C runtime inventory', '', "Map link exit code: $mapStatus", '',
    '| Archive | Members loaded | Bytes in the image |', '| --- | ---: | ---: |')
$byArchive = $members | Group-Object Archive
foreach ($group in ($byArchive | Sort-Object { -[long]$bytes[$_.Name] })) {
    $mark = if ($crt -contains $group.Name.ToLowerInvariant()) { ' (CRT)' } else { '' }
    $summary += "| $($group.Name)$mark | $($group.Count) | $([long]$bytes[$group.Name]) |"
}
$summary += @('', '| Link without | Undefined symbols |', '| --- | ---: |')
foreach ($probe in $probes) { $summary += "| $($probe -replace '^ablac-crt-no-', '') | $($undefined[$probe].Count) |" }
$summary += @('', 'Members of the CRT archives and the symbol that pulled each in: members.tsv. Bytes per archive: bytes.tsv.',
    'Each undefined-<probe>.txt lists what that archive provided.')
$summary | Out-File -Encoding utf8 (Join-Path $out 'summary.md')
$summary | ForEach-Object { Write-Host $_ }
