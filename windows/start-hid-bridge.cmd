@echo off
setlocal

powershell.exe -NoProfile -Command "$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent()); if ($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 } else { exit 1 }"
if errorlevel 1 (
    if "%*"=="" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -Verb RunAs } catch { Write-Host $_.Exception.Message; exit 1 }"
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -WorkingDirectory '%~dp0' -ArgumentList '%*' -Verb RunAs } catch { Write-Host $_.Exception.Message; exit 1 }"
    )
    if errorlevel 1 (
        echo.
        echo Could not request administrator rights. Right-click this file and choose Run as administrator.
        pause
    )
    exit /b
)

title Arduino Remote HID Bridge
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote-hid-bridge.ps1" %*
if errorlevel 1 (
    echo.
    echo Bridge stopped with an error. Check the message above.
    pause
)
