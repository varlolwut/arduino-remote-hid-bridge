@echo off
setlocal
set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM3"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process notepad; Start-Sleep -Seconds 1; $p = New-Object System.IO.Ports.SerialPort('%PORT%', 115200); $p.Open(); Start-Sleep -Seconds 2; $p.WriteLine('D 119'); Start-Sleep -Milliseconds 150; $p.WriteLine('U 119'); $p.Close()"

if errorlevel 1 (
    echo.
    echo Keyboard test failed. Check the COM port and the message above.
    pause
)
