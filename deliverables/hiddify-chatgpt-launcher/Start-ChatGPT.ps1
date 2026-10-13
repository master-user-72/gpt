param([switch]$Helper, [string]$Session, [switch]$Configure)
$ErrorActionPreference = 'Stop'
# Optional explicit paths for portable or custom installations.
$HiddifyPath = ''
$ChromePath = ''

function Find-Program($Explicit, $Candidates) {
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit -PathType Leaf) { return $Explicit }
        throw "Executable not found: $Explicit"
    }
    foreach ($p in $Candidates) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    throw 'Application not found. Set HiddifyPath / ChromePath at the top of Start-ChatGPT.ps1.'
}

# Read the same local core status stream that the Hiddify desktop app uses.
function Read-ConnectionState {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $PSScriptRoot 'tools\grpcurl.exe'
    $tools = Join-Path $PSScriptRoot 'tools'
    $psi.Arguments = '-plaintext -max-time 1 -emit-defaults -import-path "{0}" -proto core-status.proto -d "{{}}" 127.0.0.1:17078 hcore.Core/CoreInfoListener' -f $tools
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $rpc = New-Object System.Diagnostics.Process
    $rpc.StartInfo = $psi
    try {
        $rpc.Start() | Out-Null
        $stdoutTask = $rpc.StandardOutput.ReadToEndAsync()
        $stderrTask = $rpc.StandardError.ReadToEndAsync()
        if (!$rpc.WaitForExit(5000)) {
            $rpc.Kill()
            $script:RpcDiagnostic = 'Local status request timed out.'
            return 'UNKNOWN'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $states = [regex]::Matches($stdout, '"coreState"\s*:\s*"(STOPPED|STARTING|STARTED|STOPPING)"')
        if ($states.Count -gt 0) {
            $script:RpcDiagnostic = 'Status received; stream deadline after the response is expected.'
            $script:LastCoreState = $states[$states.Count - 1].Groups[1].Value
            switch ($script:LastCoreState) {
                'STOPPED' { return 'DISCONNECTED' }
                'STARTING' { return 'CONNECTING' }
                'STARTED' { return 'CONNECTED' }
                'STOPPING' { return 'DISCONNECTING' }
            }
        }
        # This stderr contains only a local RPC transport/status error, no profiles.
        $script:RpcDiagnostic = $stderr.Trim()
        if (!$script:RpcDiagnostic) { $script:RpcDiagnostic = 'Local API returned no status.' }
        return 'UNKNOWN'
    } catch {
        $script:RpcDiagnostic = $_.Exception.Message
        return 'UNKNOWN'
    } finally { $rpc.Dispose() }
}

function Calibrate-Button($Process, $ConfigPath) {
    Write-Host 'ONE-TIME SETUP: open Hiddify Home, hover over the large connection button, then press F8.' -ForegroundColor Yellow
    Write-Host 'Do not click it. You have 90 seconds. Keep the window at its usual size.'
    [LauncherMouse]::ShowWindow($Process.MainWindowHandle, 9) | Out-Null
    [LauncherMouse]::SetForegroundWindow($Process.MainWindowHandle) | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path "$Session\stop") { throw 'Launch cancelled.' }
        if (([LauncherMouse]::GetAsyncKeyState(0x77) -band 0x8000) -ne 0) {
            $point = New-Object LauncherMouse+POINT
            [LauncherMouse]::GetCursorPos([ref]$point) | Out-Null
            $under = [LauncherMouse]::WindowFromPoint($point)
            if ([LauncherMouse]::GetAncestor($under, 2) -ne $Process.MainWindowHandle) {
                throw 'F8 was pressed with the pointer outside Hiddify. Retry calibration.'
            }
            [LauncherMouse]::ScreenToClient($Process.MainWindowHandle, [ref]$point) | Out-Null
            $rect = New-Object LauncherMouse+RECT
            [LauncherMouse]::GetClientRect($Process.MainWindowHandle, [ref]$rect) | Out-Null
            $settings = @{ X = $point.X; Y = $point.Y; Width = $rect.Right; Height = $rect.Bottom }
            $settings | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
            Start-Sleep -Milliseconds 500
            return $settings
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Calibration timed out. Hover over the Hiddify connection button and press F8 next time.'
}

function Click-Connection($Process, $Position) {
    $Process.Refresh()
    $window = $script:HiddifyWindow
    if ($Process.HasExited -or $window -eq [IntPtr]::Zero) { throw 'Hiddify window is unavailable.' }
    $rect = New-Object LauncherMouse+RECT
    [LauncherMouse]::GetClientRect($window, [ref]$rect) | Out-Null
    if ($rect.Right -ne $Position.Width -or $rect.Bottom -ne $Position.Height) {
        throw 'Hiddify window size changed. Run Configure-Button.cmd again.'
    }
    # Deliver input directly to Flutter's hidden view, without moving the pointer.
    if (![LauncherMouse]::ClickHidden($window, [int]$Position.X, [int]$Position.Y)) {
        throw 'Cannot send input to the hidden Flutter view. See Hiddify-ui-diagnostic.txt.'
    }
}

if ($Helper) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$admin) { throw 'Administrator privileges required for the Hiddify helper.' }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LauncherMouse {
 public delegate bool EnumProc(IntPtr h, IntPtr param);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc callback, IntPtr param);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc callback, IntPtr param);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder name, int count);
 [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out UIntPtr result);
 public static IntPtr FindWindow(uint pid) {
   IntPtr found = IntPtr.Zero;
   EnumWindows((h, p) => {
     uint owner; GetWindowThreadProcessId(h, out owner);
     if (owner != pid) return true;
     StringBuilder name = new StringBuilder(256); GetClassName(h, name, 256);
     if (name.ToString().IndexOf("FLUTTER_RUNNER", StringComparison.OrdinalIgnoreCase) >= 0) {
       found = h; return false;
     }
     return true;
   }, IntPtr.Zero);
   return found;
 }
 static bool Send(IntPtr h, uint msg, IntPtr wp, IntPtr lp) {
   UIntPtr result;
   return SendMessageTimeout(h, msg, wp, lp, 2, 1000, out result) != IntPtr.Zero;
 }
 public static bool ClickHidden(IntPtr root, int x, int y) {
   IntPtr view = IntPtr.Zero;
   EnumChildWindows(root, (h, p) => {
     StringBuilder name = new StringBuilder(256); GetClassName(h, name, 256);
     if (name.ToString().Equals("FLUTTERVIEW", StringComparison.OrdinalIgnoreCase)) { view = h; return false; }
     return true;
   }, IntPtr.Zero);
   if (view == IntPtr.Zero) return false;
   POINT point = new POINT { X=x, Y=y };
   if (!ClientToScreen(root, ref point) || !ScreenToClient(view, ref point)) return false;
   RECT rect = new RECT(); GetClientRect(view, ref rect);
   if (point.X < 0 || point.Y < 0 || point.X >= rect.Right || point.Y >= rect.Bottom) return false;
   IntPtr lp = new IntPtr((point.Y << 16) | (point.X & 65535));
   return Send(view, 0x0200, IntPtr.Zero, lp) &&
          Send(view, 0x0201, new IntPtr(1), lp) && Send(view, 0x0202, IntPtr.Zero, lp);
 }
 public static bool CloseHidden(IntPtr h) { return Send(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
 [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
 [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
 [DllImport("user32.dll")] public static extern bool GetCursorPos(ref POINT p);
 [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
 [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
 [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, ref RECT r);
 [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
 [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr extra);
}
'@
    [LauncherMouse]::SetProcessDPIAware() | Out-Null
    $h = $null; $position = $null
    $script:HiddifyWindow = [IntPtr]::Zero
    $script:RpcDiagnostic = 'Not requested yet.'
    $script:LastCoreState = 'UNKNOWN'
    try {
        if (Get-Process -Name Hiddify -ErrorAction SilentlyContinue) {
            throw 'Close the existing Hiddify instance before starting this launcher.'
        }
        $exe = Find-Program $HiddifyPath @(
            "$env:ProgramFiles\Hiddify\Hiddify.exe",
            "${env:ProgramFiles(x86)}\Hiddify\Hiddify.exe",
            "$env:LOCALAPPDATA\Programs\Hiddify\Hiddify.exe")
        $grpcExe = Join-Path $PSScriptRoot 'tools\grpcurl.exe'
        $manifest = Join-Path $PSScriptRoot 'tools\grpcurl-sha256.txt'
        if (!(Test-Path -LiteralPath $grpcExe) -or !(Test-Path -LiteralPath $manifest)) {
            throw 'tools/grpcurl.exe is missing. Extract the entire ZIP, including its tools folder.'
        }
        $expectedLine = Get-Content -LiteralPath $manifest | Where-Object { $_ -like 'grpcurl.exe SHA256: *' }
        $expectedHash = ($expectedLine -replace '^grpcurl.exe SHA256: ', '').Trim()
        if ((Get-FileHash -LiteralPath $grpcExe -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'grpcurl.exe checksum mismatch. Download and extract a fresh archive.'
        }
        if (!$Configure -and !(Test-Path (Join-Path $PSScriptRoot 'Hiddify-button.json'))) {
            throw 'Сначала запустите Configure-Button.cmd для настройки кнопки Hiddify.'
        }
        if ($Configure) { $h = Start-Process -FilePath $exe -PassThru }
        else { $h = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru }
        $deadline = (Get-Date).AddSeconds(45)
        do {
            $h.Refresh()
            if ($h.HasExited) { throw 'Hiddify exited during startup.' }
            $script:HiddifyWindow = [LauncherMouse]::FindWindow([uint32]$h.Id)
            if (!$Configure -and $script:HiddifyWindow -ne [IntPtr]::Zero) {
                [LauncherMouse]::ShowWindow($script:HiddifyWindow, 0) | Out-Null
            }
            if ((Get-Date) -gt $deadline) { throw 'Hiddify native window did not initialize.' }
            Start-Sleep -Milliseconds 50
        } while ($script:HiddifyWindow -eq [IntPtr]::Zero)
        $configPath = Join-Path $PSScriptRoot 'Hiddify-button.json'
        if ($Configure) {
            [LauncherMouse]::ShowWindow($script:HiddifyWindow, 9) | Out-Null
            Start-Sleep -Seconds 2
            $position = Calibrate-Button $h $configPath
            Set-Content -LiteralPath "$Session\ready" -Value 'configured'
            return
        }
        if (Test-Path -LiteralPath $configPath) {
            $position = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        } else { throw 'Run Configure-Button.cmd first.' }
        $deadline = (Get-Date).AddSeconds(20)
        $state = Read-ConnectionState
        while ($state -eq 'UNKNOWN' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if (!$Configure) { [LauncherMouse]::ShowWindow($script:HiddifyWindow, 0) | Out-Null }
            $state = Read-ConnectionState
        }
        if ($state -eq 'UNKNOWN') {
            throw 'Cannot read the local Hiddify core API. See Hiddify-ui-diagnostic.txt for its transport error.'
        }
        if ($state -eq 'DISCONNECTED' -or $state -eq 'CONNECTION FAILURE') { Click-Connection $h $position }
        $deadline = (Get-Date).AddSeconds(60)
        $connectingSeen = $false
        do {
            if (Test-Path "$Session\stop") { throw 'Launch cancelled.' }
            if (!$Configure) { [LauncherMouse]::ShowWindow($script:HiddifyWindow, 0) | Out-Null }
            $state = Read-ConnectionState
            if ($state -eq 'CONNECTED') { break }
            if ($state -eq 'CONNECTING') { $connectingSeen = $true }
            if ($state -eq 'CONNECTION FAILURE' -and $connectingSeen) { throw 'Hiddify reported connection failure. Check the selected profile.' }
            if ((Get-Date) -gt $deadline) { throw 'Hiddify did not report CONNECTED. Check its Home screen for a dialog or profile error.' }
            Start-Sleep -Milliseconds 500
        } while ($true)
        Set-Content -LiteralPath "$Session\ready" -Value 'connected'
        while (!(Test-Path "$Session\stop")) {
            $h.Refresh()
            if ($h.HasExited) { throw 'Hiddify closed while Chrome was open.' }
            [LauncherMouse]::ShowWindow($script:HiddifyWindow, 0) | Out-Null
            Start-Sleep -Seconds 1
        }
    } catch {
        Set-Content -LiteralPath "$Session\error" -Value $_.Exception.Message -Encoding UTF8
    } finally {
        if ($h -and !$h.HasExited) {
            try {
                $disconnectSent = $false
                $deadline = (Get-Date).AddSeconds(30)
                while ((Read-ConnectionState) -notin @('DISCONNECTED', 'CONNECTION FAILURE')) {
                    if ((Read-ConnectionState) -eq 'CONNECTED' -and $position -and !$disconnectSent) {
                        Click-Connection $h $position
                        $disconnectSent = $true
                    }
                    if ((Get-Date) -gt $deadline) { throw 'Disconnection not confirmed. Disconnect and exit Hiddify manually.' }
                    Start-Sleep -Milliseconds 500
                }
                if (![LauncherMouse]::CloseHidden($script:HiddifyWindow)) { throw 'Cannot close Hiddify. Exit it manually using its tray menu.' }
                if (!$h.WaitForExit(15000)) { throw 'Hiddify did not exit. Select Exit as the window-close action, then exit manually.' }
            } catch { Add-Content -LiteralPath "$Session\error" -Value $_.Exception.Message -Encoding UTF8 }
        }
        @('Launcher mode: hidden Flutter input + local core API', "Last core state observed: $script:LastCoreState",
            "Local API diagnostic: $script:RpcDiagnostic", "Calibration available: $([bool]$position)") |
            Set-Content -LiteralPath "$Session\ui-diagnostic.txt" -Encoding UTF8
        Set-Content -LiteralPath "$Session\done" -Value 'finished'
    }
    exit
}

Add-Type -AssemblyName @('System.Windows.Forms', 'System.Drawing')
$loading = $null
if (!$Configure) {
    $loading = New-Object System.Windows.Forms.Form
    $loading.Text = 'Загрузка…'
    $loading.ClientSize = New-Object System.Drawing.Size(260, 85)
    $loading.StartPosition = 'CenterScreen'
    $loading.FormBorderStyle = 'FixedDialog'
    $loading.ControlBox = $false
    $loading.ShowInTaskbar = $false
    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Загрузка...'
    $label.Dock = 'Fill'
    $label.TextAlign = 'MiddleCenter'
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 14)
    $loading.Controls.Add($label)
    $loading.Show()
    [System.Windows.Forms.Application]::DoEvents()
}
$errorText = ''
$helperProcess = $null
$chrome = $null
$Session = Join-Path $env:TEMP ('HiddifyChatGPT-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Session | Out-Null
$failed = $false
try {
    $exe = Find-Program $ChromePath @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
    $profile = Join-Path $env:LOCALAPPDATA 'HiddifyChatGPT\ChromeProfile'
    # Prevent two sessions sharing the dedicated Chrome profile.
    $existing = Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profile) }
    if ($existing) { throw 'The dedicated ChatGPT Chrome session is already running.' }
    Write-Host 'Starting Hiddify. Accept UAC. On first run, hover over its connection button and press F8.'
    $args = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Helper -Session "{1}"' -f $PSCommandPath, $Session
    if ($Configure) { $args = $args.Replace('-WindowStyle Hidden ', '') + ' -Configure' }
    $helperProcess = Start-Process powershell.exe -Verb RunAs -ArgumentList $args -WindowStyle $(if ($Configure) { 'Normal' } else { 'Hidden' }) -PassThru
    $deadline = (Get-Date).AddSeconds(240)
    while (!(Test-Path "$Session\ready")) {
        if (Test-Path "$Session\error") { throw (Get-Content "$Session\error" -Raw) }
        if ($helperProcess.HasExited) { throw 'Hiddify helper exited before connection was established.' }
        if ((Get-Date) -gt $deadline) { throw 'Connection startup timed out.' }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
    if (!$Configure) {
    $browserArgs = '--user-data-dir="{0}" --no-first-run --no-default-browser-check --disable-background-mode --app=https://chatgpt.com' -f $profile
    $chrome = Start-Process -FilePath $exe -ArgumentList $browserArgs -PassThru
    $deadline = (Get-Date).AddSeconds(45)
    do {
        $chrome.Refresh()
        if ($chrome.HasExited) { throw 'Chrome exited before its window opened.' }
        if ((Get-Date) -gt $deadline) { throw 'Chrome window did not open.' }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    } while ($chrome.MainWindowHandle -eq 0)
    if ($loading) { $loading.Close(); $loading.Dispose(); $loading = $null }
    Write-Host 'Close the dedicated ChatGPT window to disconnect and exit Hiddify.'
    while (!$chrome.HasExited -and $chrome.MainWindowHandle -ne 0) {
        if (Test-Path "$Session\error") { throw (Get-Content "$Session\error" -Raw) }
        Start-Sleep -Seconds 1
        $chrome.Refresh()
    }
    }
} catch {
    $failed = $true
    $errorText = $_.Exception.Message
    Write-Host $errorText -ForegroundColor Red
} finally {
    if ($loading) { $loading.Close(); $loading.Dispose(); $loading = $null }
    if ($chrome -and !$chrome.HasExited) { $chrome.CloseMainWindow() | Out-Null }
    Set-Content -LiteralPath "$Session\stop" -Value 'stop'
    if ($helperProcess) {
        $deadline = (Get-Date).AddSeconds(50)
        while (!(Test-Path "$Session\done") -and !$helperProcess.HasExited -and (Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
        }
        if (!(Test-Path "$Session\done")) {
            $failed = $true
            $errorText += "`nHelper did not confirm cleanup. Check Hiddify and disconnect/exit manually."
            Write-Host $errorText -ForegroundColor Red
        }
    }
    if (Test-Path "$Session\ui-diagnostic.txt") {
        $diagnostic = Join-Path $PSScriptRoot 'Hiddify-ui-diagnostic.txt'
        try {
            Copy-Item -LiteralPath "$Session\ui-diagnostic.txt" -Destination $diagnostic -Force
            Write-Host "Diagnostic report: $diagnostic"
        } catch { Write-Host "Diagnostic report remains at: $Session\ui-diagnostic.txt" }
    }
    if (Test-Path "$Session\error") {
        $failed = $true
        $errorText += "`n" + (Get-Content "$Session\error" -Raw)
        Write-Host $errorText -ForegroundColor Red
    }
}
if ($failed) {
    [System.Windows.Forms.MessageBox]::Show($errorText.Trim(), 'Ошибка запуска', 'OK', 'Error') | Out-Null
    exit 1
}
Write-Host 'Hiddify connection stopped and application exited.'
