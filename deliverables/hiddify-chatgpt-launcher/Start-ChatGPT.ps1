param([switch]$Helper, [string]$Session)
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

# Hiddify Flutter controls can be absent from the Windows accessibility tree.
# Use a user-calibrated button position and fresh application log events instead.
function Read-ConnectionState {
    foreach ($path in $script:LogCandidates) {
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $file = Get-Item -LiteralPath $path
            if ($file.LastWriteTime -lt $script:LaunchTime) { continue }
            $text = [IO.File]::ReadAllText($path)
            $offset = 0
            if ($script:LogBaseline.ContainsKey($path)) {
                $base = $script:LogBaseline[$path]
                if ($text.StartsWith($base.Prefix) -and $text.Length -ge $base.Length) { $offset = $base.Length }
            }
            $events = [regex]::Matches($text.Substring($offset),
                'connection status:\s*(CONNECTED|DISCONNECTED|CONNECTING|DISCONNECTING|CONNECTION FAILURE)(?![A-Z])')
            if ($events.Count -gt 0) {
                return $events[$events.Count - 1].Groups[1].Value
            }
        } catch { }
    }
    return 'UNKNOWN'
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
    if ($Process.HasExited -or $Process.MainWindowHandle -eq 0) { throw 'Hiddify window is unavailable.' }
    [LauncherMouse]::ShowWindow($Process.MainWindowHandle, 9) | Out-Null
    if (![LauncherMouse]::SetForegroundWindow($Process.MainWindowHandle)) { throw 'Cannot focus Hiddify.' }
    Start-Sleep -Milliseconds 500
    $rect = New-Object LauncherMouse+RECT
    [LauncherMouse]::GetClientRect($Process.MainWindowHandle, [ref]$rect) | Out-Null
    if ($rect.Right -ne $Position.Width -or $rect.Bottom -ne $Position.Height) {
        throw 'Hiddify window size changed. Delete Hiddify-button.json and recalibrate; disconnect manually if needed.'
    }
    $point = New-Object LauncherMouse+POINT
    $point.X = $Position.X; $point.Y = $Position.Y
    [LauncherMouse]::ClientToScreen($Process.MainWindowHandle, [ref]$point) | Out-Null
    # A different dialog must not receive the click.
    $under = [LauncherMouse]::WindowFromPoint($point)
    if ([LauncherMouse]::GetAncestor($under, 2) -ne $Process.MainWindowHandle -or
        [LauncherMouse]::GetForegroundWindow() -ne $Process.MainWindowHandle) {
        throw 'Hiddify is covered by another window. Close the dialog and retry.'
    }
    [LauncherMouse]::SetCursorPos($point.X, $point.Y) | Out-Null
    [LauncherMouse]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [LauncherMouse]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

if ($Helper) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$admin) { throw 'Administrator privileges required for the Hiddify helper.' }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LauncherMouse {
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
    $script:LogCandidates = @()
    $script:LogBaseline = @{}
    try {
        if (Get-Process -Name Hiddify -ErrorAction SilentlyContinue) {
            throw 'Close the existing Hiddify instance before starting this launcher.'
        }
        $exe = Find-Program $HiddifyPath @(
            "$env:ProgramFiles\Hiddify\Hiddify.exe",
            "${env:ProgramFiles(x86)}\Hiddify\Hiddify.exe",
            "$env:LOCALAPPDATA\Programs\Hiddify\Hiddify.exe")
        $script:LogCandidates = @(
            "$env:APPDATA\Hiddify\hiddify\app.log",
            "$env:APPDATA\Hiddify\app.log",
            "$env:LOCALAPPDATA\Hiddify\hiddify\app.log",
            (Join-Path (Split-Path $exe) 'hiddify_portable_data\app.log'))
        foreach ($root in @("$env:APPDATA\Hiddify", "$env:LOCALAPPDATA\Hiddify")) {
            if (Test-Path -LiteralPath $root) {
                $script:LogCandidates += @(Get-ChildItem -LiteralPath $root -Filter app.log -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            }
        }
        # Optional explicit log path for nonstandard / MS Store installations.
        $logOverride = Join-Path $PSScriptRoot 'Hiddify-log-path.txt'
        if (Test-Path -LiteralPath $logOverride) {
            $script:LogCandidates = @((Get-Content -LiteralPath $logOverride -Raw).Trim())
        }
        $script:LogCandidates = @($script:LogCandidates | Select-Object -Unique)
        foreach ($path in $script:LogCandidates) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $old = [IO.File]::ReadAllText($path)
                $script:LogBaseline[$path] = @{ Length = $old.Length; Prefix = $old.Substring(0, [Math]::Min(64, $old.Length)) }
            }
        }
        $script:LaunchTime = Get-Date
        $h = Start-Process -FilePath $exe -PassThru
        $deadline = (Get-Date).AddSeconds(45)
        do {
            $h.Refresh()
            if ($h.HasExited) { throw 'Hiddify exited during startup.' }
            if ((Get-Date) -gt $deadline) { throw 'Hiddify Home window did not open. Disable silent startup.' }
            Start-Sleep -Milliseconds 500
        } while ($h.MainWindowHandle -eq 0)
        $configPath = Join-Path $PSScriptRoot 'Hiddify-button.json'
        if (Test-Path -LiteralPath $configPath) {
            $position = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        } else { $position = Calibrate-Button $h $configPath }
        $deadline = (Get-Date).AddSeconds(20)
        $state = Read-ConnectionState
        while ($state -eq 'UNKNOWN' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $state = Read-ConnectionState
        }
        if ($state -eq 'UNKNOWN') {
            throw 'Cannot find fresh Hiddify app.log status. Create Hiddify-log-path.txt beside the script with the full path to app.log.'
        }
        if ($state -eq 'DISCONNECTED' -or $state -eq 'CONNECTION FAILURE') { Click-Connection $h $position }
        $deadline = (Get-Date).AddSeconds(60)
        $connectingSeen = $false
        do {
            if (Test-Path "$Session\stop") { throw 'Launch cancelled.' }
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
                if (!$h.CloseMainWindow()) { throw 'Cannot close Hiddify. Exit it manually using its tray menu.' }
                if (!$h.WaitForExit(15000)) { throw 'Hiddify did not exit. Select Exit as the window-close action, then exit manually.' }
            } catch { Add-Content -LiteralPath "$Session\error" -Value $_.Exception.Message -Encoding UTF8 }
        }
        @('Launcher mode: calibrated mouse + fresh log events', "Last state: $(Read-ConnectionState)",
            "Log candidate count: $($script:LogCandidates.Count)", "Calibration available: $([bool]$position)") |
            Set-Content -LiteralPath "$Session\ui-diagnostic.txt" -Encoding UTF8
        Set-Content -LiteralPath "$Session\done" -Value 'finished'
    }
    exit
}

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
    $args = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -Helper -Session "{1}"' -f $PSCommandPath, $Session
    $helperProcess = Start-Process powershell.exe -Verb RunAs -ArgumentList $args -PassThru
    $deadline = (Get-Date).AddSeconds(240)
    while (!(Test-Path "$Session\ready")) {
        if (Test-Path "$Session\error") { throw (Get-Content "$Session\error" -Raw) }
        if ($helperProcess.HasExited) { throw 'Hiddify helper exited before connection was established.' }
        if ((Get-Date) -gt $deadline) { throw 'Connection startup timed out.' }
        Start-Sleep -Milliseconds 500
    }
    $browserArgs = '--user-data-dir="{0}" --no-first-run --no-default-browser-check --disable-background-mode --app=https://chatgpt.com' -f $profile
    $chrome = Start-Process -FilePath $exe -ArgumentList $browserArgs -PassThru
    $deadline = (Get-Date).AddSeconds(45)
    do {
        $chrome.Refresh()
        if ($chrome.HasExited) { throw 'Chrome exited before its window opened.' }
        if ((Get-Date) -gt $deadline) { throw 'Chrome window did not open.' }
        Start-Sleep -Milliseconds 500
    } while ($chrome.MainWindowHandle -eq 0)
    Write-Host 'Close the dedicated ChatGPT window to disconnect and exit Hiddify.'
    while (!$chrome.HasExited -and $chrome.MainWindowHandle -ne 0) {
        if (Test-Path "$Session\error") { throw (Get-Content "$Session\error" -Raw) }
        Start-Sleep -Seconds 1
        $chrome.Refresh()
    }
} catch {
    $failed = $true
    Write-Host $_.Exception.Message -ForegroundColor Red
} finally {
    if ($chrome -and !$chrome.HasExited) { $chrome.CloseMainWindow() | Out-Null }
    Set-Content -LiteralPath "$Session\stop" -Value 'stop'
    if ($helperProcess) {
        $deadline = (Get-Date).AddSeconds(50)
        while (!(Test-Path "$Session\done") -and !$helperProcess.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        if (!(Test-Path "$Session\done")) {
            $failed = $true
            Write-Host 'Helper did not confirm cleanup. Check Hiddify and disconnect/exit manually.' -ForegroundColor Red
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
        Write-Host (Get-Content "$Session\error" -Raw) -ForegroundColor Red
    }
}
if ($failed) { exit 1 }
Write-Host 'Hiddify connection stopped and application exited.'
