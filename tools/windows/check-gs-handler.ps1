# The /GS exception-dispatch check (docs/design/windows-crt-free-compiler.md, step 7: no security check weaker than the
# /MT build's). Two steps around the compiler link:
#
#   check-gs-handler.ps1 -Compile -Directory <dir> [-Architecture x64|arm64]
#       compiles static-compiler/gs-probe.cpp with MSVC's cl and /GS to <dir>/gs-probe.obj, and checks that the object
#       names __GSHandlerCheck (a frame the handler guards), so that the run below cannot pass without one;
#   build-static-compiler.ps1 ... -GsProbeObject <dir>/gs-probe.obj
#       links abla-gs-probe.exe as ablac.exe is linked (the same start-up, C library, cookie and handler objects);
#   check-gs-handler.ps1 -Probe <build>/abla-gs-probe.exe
#       runs it: with its cookie intact, the exception passes the guarded frame and is handled (status 1); with the
#       cookie overwritten, __GSHandlerCheck must end the process natively with STATUS_STACK_BUFFER_OVERRUN (0xC0000409)
#       before the handler runs.
[CmdletBinding(DefaultParameterSetName = 'Probe')]
param(
    [Parameter(ParameterSetName = 'Compile', Mandatory)][switch]$Compile,
    [Parameter(ParameterSetName = 'Compile', Mandatory)][string]$Directory,
    [Parameter(ParameterSetName = 'Compile')][ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [Parameter(ParameterSetName = 'Probe', Mandatory)][string]$Probe
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

if ($Compile) {
    & (Join-Path $PSScriptRoot 'msvc-env.ps1') -Architecture $Architecture
    $output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Directory)
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $object = Join-Path $output 'gs-probe.obj'
    $source = Join-Path $PSScriptRoot 'static-compiler/gs-probe.cpp'
    # /MT: the probe names the same default libraries ablac's objects do; the abla link drops them as it drops ablac's.
    cl.exe /nologo /c /O2 /GS /MT /EHs-c- "/Fo$object" $source
    $symbols = (& dumpbin.exe /nologo /symbols $object) -join "`n"
    # dumpbin's symbol lines end "| <name>"; the plain handler, not only its _SEH/_EH forms.
    if ($symbols -notmatch '(?m)\|\s+__GSHandlerCheck\s*$') {
        Write-Host $symbols
        throw 'cl gave the /GS probe no frame guarded by __GSHandlerCheck'
    }
    Write-Host "gs-probe.obj ($Architecture) names __GSHandlerCheck"
    return
}

$exe = (Resolve-Path -LiteralPath $Probe).Path
$overrun = -1073740791 # 0xC0000409, STATUS_STACK_BUFFER_OVERRUN, as a signed exit code
function Invoke-Probe([string]$Mode) {
    $PSNativeCommandUseErrorActionPreference = $false
    & $exe $Mode | Out-Host
    $status = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    return $status
}
$intact = Invoke-Probe 'intact'
if ($intact -ne 1) { throw "abla-gs-probe intact exited $intact, not 1: the exception did not reach its handler" }
$corrupt = Invoke-Probe 'corrupt'
if ($corrupt -ne $overrun) {
    throw ("abla-gs-probe corrupt exited {0} (0x{0:X8}), not 0xC0000409: the frame cookie check did not end the process" -f $corrupt)
}
Write-Host 'abla-gs-probe: intact frame handled (1); corrupted cookie ended the process with 0xC0000409'
