# mumu_install.ps1 - headless-robust installer driver for MuMuPlayer Global.
# Runs inside an INTERACTIVE scheduled task (runneradmin) so the installer UI
# window actually exists and the "Install now" click can trigger the download.
# The download is UI/visibility-gated AND flaky on CI runners, so this script
#   1) launches the installer (normal UI mode, NOT /S - /S never starts the download),
#   2) shows + foregrounds the window and sends a coordinate click on "Install now",
#   3) keeps the window visible and re-clicks if the download stalls,
#   4) waits until the registry key + MuMuManager.exe exist, then writes C:\mumu\install_done.txt
$ErrorActionPreference = 'Continue'
$L = 'C:\mumu\install.log'
function Log($m) { $m | Out-File -FilePath $L -Append; Write-Host $m }

Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
public class W35 {
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c,string t);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  public struct RECT { public int L, T, R, B; }
}
'@

$stub = 'C:\mumu\MuMuSetup.exe'
New-Item -ItemType Directory -Force C:\mumu | Out-Null
Remove-Item C:\mumu\install_done.txt -ErrorAction SilentlyContinue

function Get-InstallLocation {
  (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^MuMuPlayer' -and $_.InstallLocation } |
    Select-Object -First 1).InstallLocation
}

function Click-InstallNow {
  $hw = [W35]::FindWindow('PageTab', 'MuMuPlayer')
  if ($hw -eq [IntPtr]::Zero) { return $false }
  # make sure it is visible / foregrounded so the download (UI-gated) can proceed
  [W35]::ShowWindow($hw, 9) | Out-Null      # SW_RESTORE
  [W35]::SetForegroundWindow($hw) | Out-Null
  Start-Sleep -Seconds 2
  $r = New-Object W35+RECT
  [W35]::GetWindowRect($hw, [ref]$r) | Out-Null
  $x = [int](($r.L + $r.R) / 2)
  $y = [int]($r.T + ($r.B - $r.T) * 0.64)
  [W35]::SetCursorPos($x, $y) | Out-Null
  [W35]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # LEFT DOWN
  Start-Sleep -Milliseconds 150
  [W35]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # LEFT UP
  Log ("clicked Install now at $x,$y")
  return $true
}

function Nemux-Downloading {
  $pids = (Get-Process nemu-downloader -ErrorAction SilentlyContinue).Id
  if (-not $pids) { return $false }
  $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
           Where-Object { $_.OwningProcess -in $pids -and $_.RemoteAddress -notmatch '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|169\.254\.)' }
  return ($conns.Count -gt 0)
}

# ---- download the official stub installer ----
if (-not (Test-Path $stub) -or (Get-Item $stub).Length -lt 1MB) {
  Log "downloading MuMu installer stub..."
  try {
    Invoke-WebRequest "https://api.mumuplayer.com/api/dl/win?channel=gw-win-download" `
      -OutFile $stub -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -MaximumRedirection 10
    Log ("stub size=" + (Get-Item $stub).Length)
  } catch { Log ("stub download error: $_") }
}

$overall = (Get-Date).AddMinutes(240)
$stallSince = $null
while ((Get-Date) -lt $overall) {
  $rp = Get-InstallLocation
  if ($rp -and (Test-Path (Join-Path $rp 'nx_main\MuMuManager.exe'))) {
    Log ("INSTALLED at $rp")
    "INSTALL_LOCATION=$rp" | Out-File -FilePath C:\mumu\install_done.txt
    break
  }
  # ensure installer process is alive (it was launched by THIS task; if it died, relaunch)
  $inst = Get-Process MuMuInstaller_Global -ErrorAction SilentlyContinue
  if (-not $inst) {
    Log "installer not running - launching..."
    Start-Process $stub
    Start-Sleep -Seconds 10
  }
  # show window + click Install now (triggers the download)
  if (Click-InstallNow) { Start-Sleep -Seconds 6 }

  # stall detection: downloader present but no real connection for >4 min -> re-click to resume
  if (Nemux-Downloading) { $stallSince = $null }
  else {
    $nd = Get-Process nemu-downloader -ErrorAction SilentlyContinue
    if ($nd) {
      if (-not $stallSince) { $stallSince = Get-Date }
      elseif (((Get-Date) - $stallSince).TotalMinutes -gt 4) {
        Log "download appears stalled ~4min - re-clicking Install now to resume"
        Click-InstallNow
        $stallSince = $null
      }
    }
  }
  Start-Sleep -Seconds 30
}

$rp2 = Get-InstallLocation
if ($rp2 -and (Test-Path (Join-Path $rp2 'nx_main\MuMuManager.exe'))) {
  "INSTALL_LOCATION=$rp2" | Out-File -FilePath C:\mumu\install_done.txt
  Log ("DONE install at $rp2")
} else {
  Log "INSTALL TIMED OUT (window may still be downloading - check C:\mumu\install.log)"
}
