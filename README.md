# Arduino Remote HID Bridge

Remote keyboard and mouse control for Windows through an Arduino Pro Micro (ATmega32U4) acting as a local USB HID device. Designed for Parsec, RustDesk and Moonlight.

## Requirements

- Arduino Pro Micro 5 V connected to the Windows PC being controlled.
- Arduino IDE with AVR board support.
- Windows PowerShell.

## Setup

1. Open `firmware/RemoteHid/RemoteHid.ino` in Arduino IDE.
2. Select the board matching your Pro Micro and its COM port, then upload the sketch.
3. Start `windows/start-parsec-hid-bridge.cmd` for Parsec or Moonlight. Use `windows/start-hid-bridge.cmd` for RustDesk.
4. Approve the administrator prompt. Administrator rights are required when the controlled application runs elevated.

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
- `windows/start-*.cmd` — launch the bridge in the appropriate mode with administrator rights.
- `windows/test-*.cmd` — optional direct-input diagnostics.
