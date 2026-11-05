@echo off
setlocal
set "PORT=%~1"
if "%PORT%"=="" set "PORT=COM3"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p = New-Object System.IO.Ports.SerialPort('%PORT%', 115200); $p.Open(); Start-Sleep -Seconds 2; $p.WriteLine('R'); Write-Host 'Switch to the game. W will be held for one second in five seconds.'; Start-Sleep -Seconds 5; $p.WriteLine('D 119'); Start-Sleep -Seconds 1; $p.WriteLine('U 119'); $p.Close()"

if errorlevel 1 (
    echo.
    echo Game input test failed. Check the COM port and the message above.
    pause
)
