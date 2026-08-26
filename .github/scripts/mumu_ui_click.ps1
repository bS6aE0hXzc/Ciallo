# MuMu installer UI driver - MUST run inside the interactive console session
# (scheduled task). Finds the MuMuPlayer installer dialog and clicks "Install now".
$ErrorActionPreference = 'Continue'
$st = 'C:\mumu\ui_status.txt'
Set-Content $st 'waiting_window'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class MumuW {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  public struct RECT { public int L, T, R, B; }
}
"@
[MumuW]::SetProcessDPIAware() | Out-Null

# launch the installer (this task IS the console session)
Start-Process C:\mumu\MuMuSetup.exe -WorkingDirectory C:\mumu

$deadline = (Get-Date).AddMinutes(10)
$wnd = [IntPtr]::Zero
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    $wnd = [MumuW]::FindWindow('PageTab', 'MuMuPlayer')
    if ($wnd -ne [IntPtr]::Zero) { break }
}
if ($wnd -eq [IntPtr]::Zero) { Set-Content $st 'no_window'; exit }

[MumuW]::ShowWindow($wnd, 9) | Out-Null        # SW_RESTORE
[MumuW]::SetForegroundWindow($wnd) | Out-Null
Start-Sleep -Seconds 3

$r = New-Object MumuW+RECT
[MumuW]::GetWindowRect($wnd, [ref]$r) | Out-Null
$x = [int](($r.L + $r.R) / 2)                  # "Install now" = horizontal center
$y = [int]($r.T + ($r.B - $r.T) * 0.64)        # ~64% down the dialog
Set-Content $st ("clicking {0},{1}" -f $x, $y)

[MumuW]::SetCursorPos($x, $y) | Out-Null
Start-Sleep -Milliseconds 500
[MumuW]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # left down
Start-Sleep -Milliseconds 120
[MumuW]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # left up
Start-Sleep -Seconds 3

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$bmp.Save('C:\mumu\ui_after_click.png', [System.Drawing.Imaging.ImageFormat]::Png)

Set-Content $st 'clicked'
