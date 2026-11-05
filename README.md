# Arduino Remote HID Bridge

Remote keyboard and mouse control for Windows through an Arduino Pro Micro (ATmega32U4) acting as a local USB HID device. Designed for Parsec, RustDesk and Moonlight.

## Requirements

- Arduino Pro Micro 5 V connected to the Windows PC being controlled.
- Arduino IDE with AVR board support.
- Windows PowerShell.

## Setup

> **Important: run the bridge as administrator.** The CMD launchers request elevation automatically; approve the UAC prompt, otherwise input may not reach elevated applications.

1. Open `firmware/RemoteHid/RemoteHid.ino` in Arduino IDE.
2. Select the board matching your Pro Micro and its COM port, then upload the sketch.
3. Start the appropriate CMD launcher from `windows/`.

The COM port is detected automatically. To specify it explicitly:

```cmd
windows\start-parsec-hid-bridge.cmd COM7
```

Keep the bridge window open while playing. Press `Ctrl+C` in that window to stop and release all controls.

## Supported input

- Keyboard: A–Z, 0–9, arrows, F1–F12, Space, Enter, Esc, Tab, Shift, Ctrl and Alt.
- Mouse: left, right and middle buttons, plus wheel. Cursor movement is passed through by the remote desktop software.

## Files

- `firmware/` — turns the Pro Micro into a USB keyboard and mouse.
- `windows/remote-hid-bridge.ps1` — captures remote input and forwards it to the Arduino.
- `windows/start-hid-bridge.cmd` — standard mode for RustDesk; captures injected remote input.
- `windows/start-parsec-hid-bridge.cmd` — Parsec/Moonlight mode; captures virtual HID input and filters out Arduino echo.
