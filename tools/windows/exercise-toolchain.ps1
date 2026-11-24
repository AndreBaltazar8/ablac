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
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Fail([string]$message) { throw "windows toolchain: $message" }
function Run([string]$exe, [string[]]$arguments, [string]$step) {
    $output = & $exe @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Fail "$step failed ($LASTEXITCODE):`n$output" }
    $output
}

function Test-SharingViolation([Exception]$errorCause) {
    for ($cause = $errorCause; $null -ne $cause; $cause = $cause.InnerException) {
        # HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION).
        if ($cause -is [IO.IOException] -and $cause.HResult -in 0x80070020, 0x80070021) { return $true }
    }
    return $false
}

function Write-LockingProcesses([string]$directory) {
    $locked = @(foreach ($file in Get-ChildItem -LiteralPath $directory -File -Force -Recurse) {
        try {
            [IO.File]::Open($file.FullName, 'Open', 'Read', 'None').Dispose()
        } catch {
            if (Test-SharingViolation $_.Exception) { $file.FullName }
        }
    })
    if (!$locked.Count) {
        Write-Warning "No file under $directory failed the exclusive-open probe. The lock may have cleared or may be on a directory."
        return
    }
    foreach ($file in $locked) { Write-Warning "Cannot open without sharing: $file" }

    # Restart Manager can identify applications using the files. Query only.
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class AblaToolchainFileUsers
{
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessIdentity
    {
        public uint Pid;
        public System.Runtime.InteropServices.ComTypes.FILETIME Start;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessInfo
    {
        public ProcessIdentity Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Service;
        public uint ApplicationType, AppStatus, SessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
    }

    [DllImport("Rstrtmgr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RmStartSession(out uint session, uint flags, StringBuilder key);
    [DllImport("Rstrtmgr.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RmRegisterResources(uint session, uint fileCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] files,
        uint processCount, IntPtr processes, uint serviceCount, IntPtr services);
    [DllImport("Rstrtmgr.dll", ExactSpelling = true)]
    private static extern int RmGetList(uint session, out uint needed, ref uint count,
        [In, Out] ProcessInfo[] applications, out uint rebootReasons);
    [DllImport("Rstrtmgr.dll", ExactSpelling = true)]
    private static extern int RmEndSession(uint session);

    private static void Check(int status)
    {
        if (status != 0) throw new Win32Exception(status);
    }

    public static string[] List(string[] files)
    {
        Check(RmStartSession(out uint session, 0, new StringBuilder(33)));
        try
        {
            Check(RmRegisterResources(session, (uint)files.Length, files, 0, IntPtr.Zero, 0, IntPtr.Zero));
            uint count = 0;
            int status = RmGetList(session, out uint needed, ref count, null, out _);
            if (status == 0) return Array.Empty<string>();
            if (status != 234) Check(status); // ERROR_MORE_DATA
            count = needed;
            var applications = new ProcessInfo[count];
            Check(RmGetList(session, out _, ref count, applications, out _));
            var names = new string[count];
            for (int i = 0; i < names.Length; i++)
                names[i] = applications[i].Name + " (PID " + applications[i].Process.Pid + ")";
            return names;
        }
        finally
        {
            RmEndSession(session);
        }
    }
}
'@
    $users = @([AblaToolchainFileUsers]::List($locked))
    if (!$users.Count) { Write-Warning 'Windows Restart Manager did not identify a locking process.' }
    foreach ($user in $users) { Write-Warning "Windows Restart Manager reports: $user" }
}

function Move-Toolchain([string]$source, [string]$destination) {
    $delays = @(250, 500, 1000, 2000, 4000)
    for ($attempt = 0; ; $attempt++) {
        try {
            Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop
            return
        } catch {
            if (!(Test-SharingViolation $_.Exception)) { throw }
            if ($attempt -eq $delays.Count) {
                $moveError = $_
                try { Write-LockingProcesses $source }
                catch { Write-Warning "Could not identify locking processes: $_" }
                throw $moveError
            }
            Write-Host "Toolchain move hit a sharing violation. Retrying in $($delays[$attempt]) ms."
            Start-Sleep -Milliseconds $delays[$attempt]
        }
    }
}

$temp = Join-Path $env:RUNNER_TEMP ('toolchain-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
$first = Join-Path $temp 'first'
New-Item -ItemType Directory -Path $first | Out-Null
& "$env:SystemRoot\System32\tar.exe" -xf (Resolve-Path -LiteralPath $Archive).Path -C $first
if ($LASTEXITCODE -ne 0) { Fail 'the archive does not unpack' }
$bundleArchitecture = if ($Architecture -eq 'arm64') { 'aarch64' } else { 'x86_64' }
$top = Join-Path $first "abla-toolchain-$bundleArchitecture-windows"
if ($Architecture -eq 'arm64' -and [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
    Fail 'the ARM64 toolchain exercise requires an ARM64 operating system'
}
foreach ($required in 'bin\ablac.exe', 'bin\llvm-objcopy.exe', 'share\abla\stdlib', 'share\abla\runtime\windows\imports\kernel32.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $top $required))) { Fail "the package has no $required" }
}

# Nothing on the PATH but Windows itself: the toolchain must bring everything.
$env:PATH = "$env:SystemRoot\System32"
if ($Architecture -eq 'x64') { $env:PATH += ";$env:SystemRoot" }
foreach ($name in 'ABLA_SYSROOT', 'ABLA_HOME', 'ABLA_LLVM', 'ABLA_LLVM_TOOLS', 'ABLA_LLD') { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
foreach ($tool in 'clang', 'lld-link', 'llvm-objcopy', 'link', 'cl', 'git') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Fail "$tool is still on the PATH; the exercise would not prove the package is self-contained" }
}

function Check-Arm64Image([string]$image) {
    if ($Architecture -ne 'arm64') { return }
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($image))
    try {
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0xaa64) {
            Fail "$image is not an ARM64 PE"
        }
    } finally {
        $reader.Dispose()
    }
}

function Check-Toolchain([string]$root, [string]$label) {
    $ablac = Join-Path $root 'bin\ablac.exe'
    Check-Arm64Image $ablac
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
    Check-Arm64Image (Join-Path $work 'hello.exe')
    $said = (Run (Join-Path $work 'hello.exe') @() "$label run hello").Trim()
    if ($said -cne 'hello from abla on windows') { Fail "$label hello printed '$said'" }
    Set-Content -Path helper.ab -Encoding ascii -Value 'fun answer(): int = 41 + 1'
    Set-Content -Path project.ab -Encoding ascii -Value @'
import "abla/io"
import "helper.ab"
fun main { println("answer ${answer()}") }
'@
    Run $ablac @('build', 'project.ab', '-o', 'project.exe', '--no-cache') "$label build project" | Out-Null
    Check-Arm64Image (Join-Path $work 'project.exe')
    $said = (Run (Join-Path $work 'project.exe') @() "$label run project").Trim()
    if ($said -cne 'answer 42') { Fail "$label project printed '$said'" }
    Run $ablac @('build', 'hello.ab', '-o', 'hello-backtrace.exe', '--no-cache', '--backtrace') "$label build --backtrace" | Out-Null
    Check-Arm64Image (Join-Path $work 'hello-backtrace.exe')
    if ($Architecture -eq 'arm64' -and !(Test-Path -LiteralPath (Join-Path $work 'hello-backtrace.exe.debug') -PathType Leaf)) {
        Fail "$label --backtrace did not produce split debug information"
    }
    $said = (Run (Join-Path $work 'hello-backtrace.exe') @() "$label run --backtrace hello").Trim()
    if ($said -cne 'hello from abla on windows') { Fail "$label --backtrace hello printed '$said'" }
}

Check-Toolchain $top 'unpacked'
# Moved to another directory (and another name for the parent): the sysroot is found beside the image, not by where it was unpacked.
$second = Join-Path $temp 'relocated\somewhere else'
New-Item -ItemType Directory -Path (Split-Path -Parent $second) -Force | Out-Null
Move-Toolchain $top $second
Check-Toolchain $second 'moved'
Write-Host "windows toolchain: ablac $Version builds and runs programs from the unpacked and the moved toolchain with only System32 on the PATH"
