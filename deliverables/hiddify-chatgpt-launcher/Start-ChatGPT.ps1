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

function Connection-Button($Process, $Names) {
    $Process.Refresh()
    if ($Process.HasExited -or $Process.MainWindowHandle -eq 0) { return $null }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
    $items = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($item in $items) {
        if ($Names -contains $item.Current.Name -and $item.Current.IsEnabled -and !$item.Current.IsOffscreen) {
            if ($item.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) { return $item }
        }
    }
    return $null
}

function Click-Button($Button, $Process) {
    $pattern = $null
    if ($Button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        $pattern.Invoke()
        return
    }
    [NativeClick]::ShowWindow($Process.MainWindowHandle, 9) | Out-Null
    if (![NativeClick]::SetForegroundWindow($Process.MainWindowHandle)) { throw 'Cannot focus Hiddify.' }
    Start-Sleep -Milliseconds 300
    $point = $Button.GetClickablePoint()
    if (![NativeClick]::SetCursorPos([int]$point.X, [int]$point.Y)) { throw 'Cannot position pointer.' }
    [NativeClick]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [NativeClick]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

if ($Helper) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$admin) { throw 'Administrator privileges required for the Hiddify helper.' }
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeClick {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr extra);
}
'@
    $off = @('Tap to connect', 'Нажмите для подключения', 'Connect', 'Подключить')
    $on = @('Connected', 'Подключено', 'Disconnect', 'Отключить')
    $h = $null
    try {
        if (Get-Process -Name Hiddify -ErrorAction SilentlyContinue) {
            throw 'Close the existing Hiddify instance before starting this launcher.'
        }
        $exe = Find-Program $HiddifyPath @(
            "$env:ProgramFiles\Hiddify\Hiddify.exe",
            "${env:ProgramFiles(x86)}\Hiddify\Hiddify.exe",
            "$env:LOCALAPPDATA\Programs\Hiddify\Hiddify.exe")
        $h = Start-Process -FilePath $exe -PassThru
        $deadline = (Get-Date).AddSeconds(60)
        $clicked = $false
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            if (Test-Path "$Session\stop") { throw 'Launch cancelled.' }
            $h.Refresh()
            if ($h.HasExited) { throw 'Hiddify exited during startup.' }
            if (Connection-Button $h $on) { $ready = $true; break }
            $button = Connection-Button $h $off
            if ($button -and !$clicked) { Click-Button $button $h; $clicked = $true }
            Start-Sleep -Milliseconds 500
        }
        if (!$ready) {
            throw 'Cannot confirm connection through Hiddify UI. Check profile, visible Home screen and UI Automation support.'
        }
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
                $button = Connection-Button $h $on
                if ($button) { Click-Button $button $h }
                $deadline = (Get-Date).AddSeconds(30)
                while (!(Connection-Button $h $off)) {
                    if ((Get-Date) -gt $deadline) { throw 'Disconnection not confirmed. Disconnect and exit Hiddify manually.' }
                    Start-Sleep -Milliseconds 500
                }
                if (!$h.CloseMainWindow()) { throw 'Cannot close Hiddify. Exit it manually using its tray menu.' }
                if (!$h.WaitForExit(15000)) {
                    throw 'Hiddify did not exit. Set its window-close action to Exit, then exit it manually.'
                }
            } catch {
                Add-Content -LiteralPath "$Session\error" -Value $_.Exception.Message -Encoding UTF8
            }
        }
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
    Write-Host 'Starting Hiddify. Accept its administrator prompt; keep its Home screen visible.'
    $args = '-NoProfile -ExecutionPolicy Bypass -STA -File "{0}" -Helper -Session "{1}"' -f $PSCommandPath, $Session
    $helperProcess = Start-Process powershell.exe -Verb RunAs -ArgumentList $args -PassThru
    $deadline = (Get-Date).AddSeconds(90)
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
    if (Test-Path "$Session\error") {
        $failed = $true
        Write-Host (Get-Content "$Session\error" -Raw) -ForegroundColor Red
    }
}
if ($failed) { exit 1 }
Write-Host 'Hiddify connection stopped and application exited.'
