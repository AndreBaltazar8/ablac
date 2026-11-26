# The toolchain move of tools/windows/exercise-toolchain.ps1, kept apart so that tools/windows/test-move-toolchain.ps1 can run it with a
# mover that fails the way Windows does (a sharing violation: Defender or an indexer holding a file of the tree).
#
# The move is one rename of a directory (Directory.Move), retried only on a sharing or lock violation, with growing waits. A rename moves
# everything or nothing, but the move that was here (Move-Item) can leave a part of the tree behind at the target when it fails, and its retry then moved
# the source INTO that target: the release run 45694527287 found `...\relocated\somewhere else\<top>\bin\ablac.exe` where it looked for
# `...\somewhere else\bin\ablac.exe`. So the target must not exist before the move (anything there afterwards is a failed attempt's, and is removed
# before the retry), and a move that "succeeds" is checked: the target is a directory and the source is gone.

function Test-SharingViolation([Exception]$errorCause) {
    for ($cause = $errorCause; $null -ne $cause; $cause = $cause.InnerException) {
        # HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION / ERROR_LOCK_VIOLATION).
        if ($cause -is [IO.IOException] -and $cause.HResult -in 0x80070020, 0x80070021) { return $true }
    }
    return $false
}

# What Windows reports for a directory rename while a file below it is open: the release run 45735219041 showed that
# [IO.Directory]::Move then throws UnauthorizedAccessException ("Access to the path ... is denied", ERROR_ACCESS_DENIED), not a sharing
# violation. A real permission problem looks the same, so the retry is bounded and the final error names both paths and the cause.
function Test-RetryableMoveFailure([Exception]$errorCause) {
    for ($cause = $errorCause; $null -ne $cause; $cause = $cause.InnerException) {
        if ($cause -is [UnauthorizedAccessException]) { return $true }
    }
    return Test-SharingViolation $errorCause
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

function Move-Toolchain(
    [string]$source,
    [string]$destination,
    [scriptblock]$mover = { param($from, $to) [IO.Directory]::Move($from, $to) },
    [int[]]$delays = @(250, 500, 1000, 2000, 4000)
) {
    if (Test-Path -LiteralPath $destination) { throw "windows toolchain: the move target $destination exists before the move" }
    for ($attempt = 0; ; $attempt++) {
        try {
            & $mover $source $destination
            break
        } catch {
            $failure = $_
            if (!(Test-RetryableMoveFailure $failure.Exception)) { throw }
            # What a failed attempt left at the target is its own (the target did not exist): never let a retry move the source into it.
            if (Test-Path -LiteralPath $destination) {
                try { Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop }
                catch { throw "windows toolchain: a failed move left a partial $destination that cannot be removed ($($_.Exception.Message)); the move error was: $($failure.Exception.Message)" }
            }
            if ($attempt -ge $delays.Count) {
                try { Write-LockingProcesses $source }
                catch { Write-Warning "Could not identify locking processes: $_" }
                throw "windows toolchain: could not move $source to $destination after $($attempt + 1) attempts: $($failure.Exception.Message)"
            }
            Write-Host "Toolchain move failed ($($failure.Exception.GetType().Name): a sharing violation or access denied, as Windows reports a held file). Retrying in $($delays[$attempt]) ms."
            Start-Sleep -Milliseconds $delays[$attempt]
        }
    }
    if (!(Test-Path -LiteralPath $destination -PathType Container)) { throw "windows toolchain: the move reported success but $destination is not a directory" }
    if (Test-Path -LiteralPath $source) { throw "windows toolchain: the move reported success but $source is still there" }
}
