# Set up the MSVC environment in the current PowerShell process.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64 -property installationPath
if (!$vs) { throw 'MSVC 14.44 x64 C++ toolset unavailable' }

# The runner's Clang 20 supports the 14.44 STL. Newer MSVC toolsets can require Clang 22.
$vcvars = Join-Path $vs 'VC/Auxiliary/Build/vcvarsall.bat'
$vcEnvironment = & cmd.exe /d /c ('call "{0}" amd64 -vcvars_ver=14.44 && set' -f $vcvars)
foreach ($line in $vcEnvironment) {
    if ($line -match '^([A-Za-z_][A-Za-z0-9_()]*)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}
if ($env:VCToolsVersion -notmatch '^14\.44\.' -or $env:VSCMD_ARG_TGT_ARCH -notin @('x64', 'amd64')) {
    throw 'Could not initialize the MSVC 14.44 x64 C++ toolset'
}
