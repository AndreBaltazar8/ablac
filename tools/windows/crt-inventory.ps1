# The C runtime inventory of the Windows compiler (docs/design/windows-crt-free-compiler.md): measurement only. Run after
# build-static-compiler.ps1 -CrtInventory has configured the build directory with the inventory targets. Links
# ablac-crt-map (a /lldmap map with each input section's bytes, an MSVC-style /map that names archive:member for each
# public symbol, and lld's /verbose log when the build shows it) and the four leave-one-out links (no libucrt, no libucrt
# and libcmt, no libvcruntime, no libcpmt), which are expected to fail and list every symbol the archive left out had
# provided. Writes <build>/crt-inventory/: the maps, the logs, members.tsv, symbols.tsv, bytes.tsv,
# undefined-<probe>.txt and summary.md. Never fails because a probe does not link, and exits 0.
param(
    [Parameter(Mandatory)][string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'
# A probe link is expected to fail: its exit code is recorded, not thrown (the caller turns that on for native commands).
$PSNativeCommandUseErrorActionPreference = $false
$build = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildDirectory)
$out = Join-Path $build 'crt-inventory'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# The file name from a path such as C:\...\libucrt.lib or d:\os\obj\...\malloc.obj.
function Get-LeafName([string]$path) {
    return ($path.Trim() -split '[\\/]')[-1]
}

# An archive's name as the summary shows it: lld's MSVC-style map writes "libucrt" for libucrt.lib.
function Get-ArchiveName([string]$name) {
    $leaf = (Get-LeafName $name).ToLowerInvariant()
    if (-not $leaf.EndsWith('.lib')) { $leaf += '.lib' }
    return $leaf
}

# 1. The map link.
$mapLog = Join-Path $out 'map-link.log'
& cmake --build $build --target ablac-crt-map *> $mapLog
$mapStatus = $LASTEXITCODE
"map link exit code: $mapStatus" | Out-File -Append -Encoding utf8 $mapLog

# The MSVC-style map's public symbol lines: "<sec>:<offset>  <symbol>  <rva+base>  [f] [i]  <lib>:<member>". A plain
# object file has no "<lib>:" (a drive letter is not an archive, hence two characters at least).
$memberArchives = @{}
$symbols = [System.Collections.Generic.List[object]]::new()
$msvcMap = Join-Path $out 'ablac.msvc.map'
if (Test-Path $msvcMap) {
    foreach ($line in Get-Content $msvcMap) {
        if ($line -match '^\s*[0-9a-fA-F]{4}:[0-9a-fA-F]+\s+(\S+)\s+[0-9a-fA-F]{8,16}\s+(?:[fi]\s+)*([^\s:\\/]{2,}):(\S.*?)\s*$') {
            $archive = Get-ArchiveName $Matches[2]
            $member = Get-LeafName $Matches[3]
            $symbols.Add([pscustomobject]@{ Archive = $archive; Member = $member; Symbol = $Matches[1] })
            if (-not $memberArchives.ContainsKey($member)) { $memberArchives[$member] = @{} }
            $memberArchives[$member][$archive] = $true
        }
    }
}
$symbols | ForEach-Object { "$($_.Archive)`t$($_.Member)`t$($_.Symbol)" } | Out-File -Encoding utf8 (Join-Path $out 'symbols.tsv')

# lld's /verbose says "Loaded <archive>(<member>) for <symbol>" for every member it pulls in, when the log has it
# (CMake's vs_link_exe prints a link's output only when the link fails).
$loaded = foreach ($line in Get-Content $mapLog) {
    if ($line -match 'Loaded (.+?\.lib)\((.+?)\) for (.+)$') {
        [pscustomobject]@{ Archive = (Get-ArchiveName $Matches[1]); Member = (Get-LeafName $Matches[2]); Symbol = $Matches[3].Trim() }
    }
}
$loaded | ForEach-Object { "$($_.Archive)`t$($_.Member)`t$($_.Symbol)" } | Out-File -Encoding utf8 (Join-Path $out 'members.tsv')
foreach ($entry in $loaded) {
    if (-not $memberArchives.ContainsKey($entry.Member)) { $memberArchives[$entry.Member] = @{} }
    $memberArchives[$entry.Member][$entry.Archive] = $true
}

# The /lldmap input-section lines: "<address> <size> <align>  <member>:(<section>)". lld names the member without its
# archive, so bytes go to the archive the other two lists put that member in: "(object files)" when none does, and
# "(ambiguous)" when a member name is in more than one archive.
$bytes = @{}
$map = Join-Path $out 'ablac.map'
if (Test-Path $map) {
    foreach ($line in Get-Content $map) {
        if ($line -match '^\s*[0-9a-fA-F]+\s+([0-9a-fA-F]+)\s+\d+\s+(.+?):\((.+)\)\s*$') {
            $member = Get-LeafName $Matches[2]
            $archive = '(object files)'
            if ($memberArchives.ContainsKey($member)) {
                $owners = @($memberArchives[$member].Keys)
                $archive = if ($owners.Count -eq 1) { $owners[0] } else { '(ambiguous)' }
            }
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
    '| Archive | Members with public symbols | Public symbols | Bytes in the image |', '| --- | ---: | ---: | ---: |')
$byArchive = @{}
foreach ($group in ($symbols | Group-Object Archive)) { $byArchive[$group.Name] = $group }
$archives = @($byArchive.Keys) + @($bytes.Keys) | Sort-Object -Unique | Sort-Object { -[long]$bytes[$_] }
foreach ($archive in $archives) {
    $mark = if ($crt -contains $archive) { ' (CRT)' } else { '' }
    $memberCount = 0
    $symbolCount = 0
    if ($byArchive.ContainsKey($archive)) {
        $memberCount = @($byArchive[$archive].Group | Select-Object -ExpandProperty Member -Unique).Count
        $symbolCount = $byArchive[$archive].Count
    }
    $summary += "| $archive$mark | $memberCount | $symbolCount | $([long]$bytes[$archive]) |"
}
$summary += @('', '| Link without | Undefined symbols |', '| --- | ---: |')
foreach ($probe in $probes) { $summary += "| $($probe -replace '^ablac-crt-no-', '') | $($undefined[$probe].Count) |" }
$summary += @('', 'Public symbols by archive and member: symbols.tsv. Members /verbose reported loading, and for which symbol:',
    'members.tsv (empty when the build hid the link output). Bytes per archive: bytes.tsv.',
    'Each undefined-<probe>.txt lists what that archive provided.')
$summary | Out-File -Encoding utf8 (Join-Path $out 'summary.md')
$summary | ForEach-Object { Write-Host $_ }
# The probes' failing links must not become this step's exit code.
exit 0
