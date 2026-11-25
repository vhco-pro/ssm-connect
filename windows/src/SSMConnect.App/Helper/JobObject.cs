using System.Diagnostics;
using System.Runtime.InteropServices;

namespace SSMConnect.App.Helper;

/// <summary>
/// A Windows job object with kill-on-close: every process assigned to it, and every process
/// those start, ends when the job is terminated or its last handle closes. The shell holds the
/// only handle, so the helper and its plugin and SSH descendants end with the shell.
/// </summary>
public sealed partial class JobObject : IDisposable
{
    readonly IntPtr handle;

    public JobObject()
    {
        handle = CreateJobObjectW(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new InvalidOperationException($"CreateJobObject failed: {Marshal.GetLastWin32Error()}");
        var information = new JobObjectExtendedLimitInformation { BasicLimitInformation = new JobObjectBasicLimitInformation { LimitFlags = KillOnJobClose } };
        var size = Marshal.SizeOf<JobObjectExtendedLimitInformation>();
        if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformationClass, ref information, (uint)size))
            throw new InvalidOperationException($"SetInformationJobObject failed: {Marshal.GetLastWin32Error()}");
    }

    public void Assign(Process process)
    {
        if (!AssignProcessToJobObject(handle, process.Handle))
            throw new InvalidOperationException($"AssignProcessToJobObject failed: {Marshal.GetLastWin32Error()}");
    }

    public bool Contains(Process process) => IsProcessInJob(process.Handle, handle, out var result) && result;

    public int ActiveProcessCount
    {
        get
        {
            if (!QueryInformationJobObject(handle, JobObjectBasicAccountingInformationClass, out var accounting,
                    (uint)Marshal.SizeOf<JobObjectBasicAccountingInformation>(), IntPtr.Zero))
                throw new InvalidOperationException($"QueryInformationJobObject failed: {Marshal.GetLastWin32Error()}");
            return (int)accounting.ActiveProcesses;
        }
    }

    /// <summary>Terminates every process in the job and returns once the job reports none.</summary>
    public async Task TerminateAndWaitEmptyAsync(CancellationToken cancellationToken)
    {
        TerminateJobObject(handle, 1);
        while (ActiveProcessCount > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            await Task.Delay(20, cancellationToken);
        }
    }

    public void Dispose() => CloseHandle(handle);

    const uint KillOnJobClose = 0x2000;
    const int JobObjectBasicAccountingInformationClass = 1;
    const int JobObjectExtendedLimitInformationClass = 9;

    [StructLayout(LayoutKind.Sequential)]
    struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JobObjectBasicAccountingInformation
    {
        public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(IntPtr job, int informationClass, ref JobObjectExtendedLimitInformation information, uint length);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool QueryInformationJobObject(IntPtr job, int informationClass, out JobObjectBasicAccountingInformation information, uint length, IntPtr returnLength);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool result);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool TerminateJobObject(IntPtr job, uint exitCode);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(IntPtr handle);
}
