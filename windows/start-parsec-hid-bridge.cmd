@echo off
setlocal

net session >nul 2>&1
if errorlevel 1 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

title Parsec Arduino HID Bridge
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0remote-hid-bridge.ps1" -ParsecMode %*
if errorlevel 1 (
    echo.
    echo Bridge stopped with an error. Check the message above.
    pause
)
