using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32.SafeHandles;

namespace SSMConnect.Windows;

/// <summary>
/// A Windows Job Object that terminates everything inside it when the last handle closes.
/// </summary>
/// <remarks>
/// This is the containment that survives an abnormal exit of the client: process handles close when
/// a process dies however it dies, so the kernel reaps the contained plugin even when no managed
/// cleanup runs. Phase 0 measured 1–5 ms after a hard <c>TerminateProcess</c> of the owner.
/// <para>
/// It is containment only. It does not terminate the AWS-side SSM session, which is a separate
/// obligation under AC-07.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed partial class KillOnCloseJob : IDisposable
{
    private readonly SafeFileHandle _handle;

    public KillOnCloseJob()
    {
        _handle = NativeMethods.CreateJobObject(IntPtr.Zero, null);
        if (_handle.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        var information = new NativeMethods.JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new NativeMethods.JobObjectBasicLimitInformation
            {
                LimitFlags = NativeMethods.JobObjectLimitKillOnJobClose,
            },
        };

        int length = Marshal.SizeOf(information);
        IntPtr pointer = Marshal.AllocHGlobal(length);
        try
        {
            Marshal.StructureToPtr(information, pointer, false);
            if (!NativeMethods.SetInformationJobObject(
                    _handle, NativeMethods.ExtendedLimitInformationClass, pointer, (uint)length))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    public void AddProcess(Process process)
    {
        if (!NativeMethods.AssignProcessToJobObject(_handle, process.Handle))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public void Dispose() => _handle.Dispose();

    private static partial class NativeMethods
    {
        internal const uint JobObjectLimitKillOnJobClose = 0x00002000;
        internal const int ExtendedLimitInformationClass = 9;

        [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", SetLastError = true,
            StringMarshalling = StringMarshalling.Utf16)]
        internal static partial SafeFileHandle CreateJobObject(IntPtr securityAttributes, string? name);

        [LibraryImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool SetInformationJobObject(
            SafeFileHandle job, int informationClass, IntPtr information, uint length);

        [LibraryImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobObjectBasicLimitInformation
        {
            internal long PerProcessUserTimeLimit;
            internal long PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal nuint MinimumWorkingSetSize;
            internal nuint MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal nuint Affinity;
            internal uint PriorityClass;
            internal uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct IoCounters
        {
            internal ulong ReadOperationCount;
            internal ulong WriteOperationCount;
            internal ulong OtherOperationCount;
            internal ulong ReadTransferCount;
            internal ulong WriteTransferCount;
            internal ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobObjectExtendedLimitInformation
        {
            internal JobObjectBasicLimitInformation BasicLimitInformation;
            internal IoCounters IoInfo;
            internal nuint ProcessMemoryLimit;
            internal nuint JobMemoryLimit;
            internal nuint PeakProcessMemoryUsed;
            internal nuint PeakJobMemoryUsed;
        }
    }
}
