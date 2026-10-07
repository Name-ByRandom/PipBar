# PipBar Windows DDC/CI probe (v9)
# READ-ONLY: never changes any setting.
#
# Run:
#   powershell -ExecutionPolicy Bypass -File ddc-probe.ps1
#
# Save output (console may be GBK, force UTF-8 on the file):
#   powershell -ExecutionPolicy Bypass -File ddc-probe.ps1 2>&1 |
#     Out-File -FilePath .\result.log -Encoding utf8

# Add-Type is not idempotent; a stale type aborts the run, so the
# type name is bumped each revision.
if (-not ('DDC9' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Text;

public class DDC9 {
    // Windows SDK, PhysicalMonitorEnumerationAPI.h:
    //   WCHAR szPhysicalMonitorDescription[128];   2 bytes each
    //   HANDLE hPhysicalMonitor;                   8 bytes
    // => sizeof == 264.  ushort[] is required (string and char[] both break it).
    [StructLayout(LayoutKind.Sequential)]
    public struct PHYSICAL_MONITOR {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 128)]
        public ushort[] szPhysicalMonitorDescription;
        public IntPtr hPhysicalMonitor;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr dwData);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprc, MonitorEnumProc cb, IntPtr dwData);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint num);

    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Unicode,
              EntryPoint = "GetPhysicalMonitorsFromHMONITOR")]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor, uint size, [Out] PHYSICAL_MONITOR[] arr);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint cur, out uint max);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitors(uint size, [In] PHYSICAL_MONITOR[] arr);

    public static int SizeOfPhysicalMonitor() {
        return Marshal.SizeOf(typeof(PHYSICAL_MONITOR));
    }

    static string Describe(PHYSICAL_MONITOR m) {
        if (m.szPhysicalMonitorDescription == null) return "<null>";
        var sb = new StringBuilder();
        foreach (var c in m.szPhysicalMonitorDescription) {
            if (c == 0) break;
            sb.Append((char)c);
        }
        return sb.Length == 0 ? "<empty>" : sb.ToString();
    }

    static bool anyOk = false;

    // The whole enumeration + read happens inside C#.  Letting PowerShell
    // own the [Out] array does not work: the API returns TRUE but the array
    // comes back all zeros, so handle stays 0x0.
    public static string[] Probe(int[] codes) {
        var outp = new List<string>();
        anyOk = false;
        int adapter = 0;

        MonitorEnumProc cb = delegate(IntPtr hMon, IntPtr hdc, IntPtr lprc, IntPtr d) {
            adapter++;
            outp.Add("[" + adapter + "] hMonitor=0x" + hMon.ToInt64().ToString("X"));

            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n)) {
                outp.Add("    physicalMonitorCount FAILED err=" + Marshal.GetLastWin32Error());
                return true;
            }
            outp.Add("    physicalMonitorCount=" + n);
            if (n == 0) return true;

            var arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) {
                outp.Add("    GetPhysicalMonitors FAILED err=" + Marshal.GetLastWin32Error());
                return true;
            }

            for (int i = 0; i < n; i++) {
                IntPtr h = arr[i].hPhysicalMonitor;
                outp.Add("    physical[" + i + "] desc=[" + Describe(arr[i]) + "] handle=0x" + h.ToInt64().ToString("X"));
                if (h == IntPtr.Zero) { outp.Add("      handle NULL - skip"); continue; }

                foreach (int code in codes) {
                    uint cur, max;
                    bool ok;
                    try { ok = GetVCPFeatureAndVCPFeatureReply(h, (byte)code, out cur, out max); }
                    catch (Exception ex) {
                        outp.Add("      0x" + code.ToString("X2") + " EXCEPTION: " + ex.Message);
                        continue;
                    }
                    if (ok) {
                        anyOk = true;
                        outp.Add("      0x" + code.ToString("X2") + " cur=" + cur + " max=" + max);
                    } else {
                        outp.Add("      0x" + code.ToString("X2") + " READ FAILED err=" + Marshal.GetLastWin32Error());
                    }
                }
            }

            DestroyPhysicalMonitors(n, arr);
            return true;
        };

        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, cb, IntPtr.Zero);
        outp.Add("ANY_VCP_READ_OK: " + anyOk);
        return outp.ToArray();
    }
}
'@
}
$ErrorActionPreference = 'Continue'

Write-Output ("sizeof(PHYSICAL_MONITOR) = {0} bytes (expected 264)" -f `
              [DDC9]::SizeOfPhysicalMonitor())

# 0x10 brightness  0x12 contrast  0x60 input  0x62 volume
# 0x8D mute        0xE8 PBP input 0xE9 PBP mode
$codes = @(0x10, 0x12, 0x60, 0x62, 0x8D, 0xE8, 0xE9)

Write-Output "Enumerating displays..."
$lines = [DDC9]::Probe($codes)
foreach ($l in $lines) { Write-Output $l }

Write-Output ""
if ($lines -contains 'ANY_VCP_READ_OK: True') {
    Write-Output "RESULT: DDC_OK"
    exit 0
}
Write-Output "RESULT: DDC_FAIL"
exit 1
