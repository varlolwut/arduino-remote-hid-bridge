[CmdletBinding()]
param(
    [string]$Port = "",
    [int]$BaudRate = 115200,
    [switch]$ParsecMode
)

if ([string]::IsNullOrWhiteSpace($Port)) {
    $serialPorts = @(Get-CimInstance Win32_SerialPort)
    $detectedPorts = @($serialPorts | Where-Object {
        $_.Name -match "Arduino Leonardo|Pro Micro" -or
        $_.PNPDeviceID -match "VID_2341&PID_" -or
        $_.PNPDeviceID -match "VID_1B4F&PID_"
    })

    if ($detectedPorts.Count -eq 0) {
        $detectedPorts = @($serialPorts | Where-Object {
            $_.PNPDeviceID -like "USB*"
        })
    }

    if ($detectedPorts.Count -eq 1) {
        $Port = $detectedPorts[0].DeviceID
    } elseif ($detectedPorts.Count -eq 0) {
        throw "Arduino serial port not found. Specify it explicitly with -Port."
    } else {
        throw "Several possible Arduino serial ports found. Specify one explicitly with -Port."
    }
}

$source = @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Ports;
using System.Runtime.InteropServices;
using System.Threading;

public static class RemoteHidBridge
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int WM_MOUSEMOVE = 0x0200;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MBUTTONUP = 0x0208;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_QUIT = 0x0012;
    private const int LLKHF_INJECTED = 0x10;
    private const int LLMHF_INJECTED = 0x01;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll")]
    private static extern int GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostThreadMessage(int idThread, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);

    private static readonly Dictionary<uint, byte> KeyMap = CreateKeyMap();
    private static readonly HashSet<uint> PressedKeys = new HashSet<uint>();
    private static readonly Dictionary<byte, int> PendingKeyDown = new Dictionary<byte, int>();
    private static readonly Dictionary<byte, int> PendingKeyUp = new Dictionary<byte, int>();
    private static readonly int[] PendingMouseDown = new int[4];
    private static readonly int[] PendingMouseUp = new int[4];
    private static readonly object SerialSync = new object();

    private static SerialPort serial;
    private static IntPtr keyboardHookHandle = IntPtr.Zero;
    private static IntPtr mouseHookHandle = IntPtr.Zero;
    private static HookProc keyboardHookCallback;
    private static HookProc mouseHookCallback;
    private static Timer heartbeatTimer;
    private static POINT lastMousePoint;
    private static int wheelRemainder;
    private static int pendingWheelEcho;
    private static int mainThreadId;
    private static bool parsecMode;
    private static volatile bool running;

    public static void Run(string portName, int baudRate, bool parsecInputMode)
    {
        parsecMode = parsecInputMode;
        mainThreadId = GetCurrentThreadId();
        keyboardHookCallback = KeyboardHook;
        mouseHookCallback = MouseHook;

        try
        {
            serial = new SerialPort(portName, baudRate);
            serial.NewLine = "\n";
            serial.WriteTimeout = 1000;
            serial.Open();

            Thread.Sleep(2000);
            Send("R");
            GetCursorPos(out lastMousePoint);

            keyboardHookHandle = InstallHook(WH_KEYBOARD_LL, keyboardHookCallback);
            mouseHookHandle = InstallHook(WH_MOUSE_LL, mouseHookCallback);

            Console.CancelKeyPress += ConsoleCancel;
            running = true;
            heartbeatTimer = new Timer(Heartbeat, null, 0, 500);

            Console.WriteLine("Remote HID bridge is running on " + portName + ".");
            Console.WriteLine("Keyboard: A-Z, 0-9, arrows, F1-F12, Space, Enter, Esc, Tab, Shift, Ctrl, Alt.");
            Console.WriteLine("Mouse: cursor movement passes through; left/right/middle buttons and wheel use Arduino.");
            Console.WriteLine(parsecMode
                ? "Parsec mode: virtual HID input is captured with Arduino echo protection."
                : "Standard mode: only remote injected input is captured.");
            Console.WriteLine("Press Ctrl+C here to stop and release controls.");

            MSG message;
            while (running)
            {
                int result = GetMessage(out message, IntPtr.Zero, 0, 0);
                if (result == 0)
                {
                    break;
                }
                if (result == -1)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
        }
        finally
        {
            running = false;

            if (heartbeatTimer != null)
            {
                heartbeatTimer.Dispose();
            }

            if (keyboardHookHandle != IntPtr.Zero)
            {
                UnhookWindowsHookEx(keyboardHookHandle);
                keyboardHookHandle = IntPtr.Zero;
            }

            if (mouseHookHandle != IntPtr.Zero)
            {
                UnhookWindowsHookEx(mouseHookHandle);
                mouseHookHandle = IntPtr.Zero;
            }

            lock (SerialSync)
            {
                if (serial != null)
                {
                    try
                    {
                        if (serial.IsOpen)
                        {
                            serial.WriteLine("R");
                            serial.Close();
                        }
                    }
                    catch (Exception error)
                    {
                        Console.WriteLine("Could not send final release: " + error.Message);
                    }
                    finally
                    {
                        serial.Dispose();
                    }
                }
            }
        }
    }

    private static IntPtr InstallHook(int hookType, HookProc callback)
    {
        IntPtr handle;
        using (Process process = Process.GetCurrentProcess())
        using (ProcessModule module = process.MainModule)
        {
            handle = SetWindowsHookEx(hookType, callback, GetModuleHandle(module.ModuleName), 0);
        }

        if (handle == IntPtr.Zero)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return handle;
    }

    private static Dictionary<uint, byte> CreateKeyMap()
    {
        Dictionary<uint, byte> map = new Dictionary<uint, byte>();

        for (uint key = 0x41; key <= 0x5A; key++)
        {
            map[key] = (byte)('a' + key - 0x41);
        }

        for (uint key = 0x30; key <= 0x39; key++)
        {
            map[key] = (byte)key;
        }

        for (uint key = 0; key < 12; key++)
        {
            map[0x70 + key] = (byte)(0xC1 + key);
        }

        map[0x25] = 0xD8;
        map[0x26] = 0xDA;
        map[0x27] = 0xD7;
        map[0x28] = 0xD9;
        map[0x20] = 0x20;
        map[0x0D] = 0xB0;
        map[0x1B] = 0xB1;
        map[0x09] = 0xB3;

        map[0x10] = 0x81;
        map[0xA0] = 0x81;
        map[0xA1] = 0x85;
        map[0x11] = 0x80;
        map[0xA2] = 0x80;
        map[0xA3] = 0x84;
        map[0x12] = 0x82;
        map[0xA4] = 0x82;
        map[0xA5] = 0x86;

        return map;
    }

    private static IntPtr KeyboardHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && running)
        {
            KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(
                lParam,
                typeof(KBDLLHOOKSTRUCT));

            byte hidCode;
            bool isInjected = (data.flags & LLKHF_INJECTED) != 0;
            bool isMapped = KeyMap.TryGetValue(data.vkCode, out hidCode);

            if (parsecMode)
            {
                Console.WriteLine("K vk=" + data.vkCode + " scan=" + data.scanCode
                    + " flags=" + data.flags + " msg=" + wParam.ToInt32()
                    + " hid=" + hidCode + " mapped=" + isMapped);
            }

            if (isMapped && (isInjected || parsecMode))
            {
                int message = wParam.ToInt32();
                bool isDown = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
                bool isUp = message == WM_KEYUP || message == WM_SYSKEYUP;

                if (parsecMode && !isInjected)
                {
                    if (isDown && ConsumePending(PendingKeyDown, hidCode))
                    {
                        Console.WriteLine("K echo down passed: " + hidCode);
                        return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
                    }
                    if (isUp && ConsumePending(PendingKeyUp, hidCode))
                    {
                        Console.WriteLine("K echo up passed: " + hidCode);
                        return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
                    }
                    if (isDown && PressedKeys.Contains(data.vkCode))
                    {
                        Console.WriteLine("K repeat passed: " + hidCode);
                        return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
                    }
                }

                try
                {
                    if (isDown)
                    {
                        if (PressedKeys.Add(data.vkCode))
                        {
                            AddPending(PendingKeyDown, hidCode);
                            Send("D " + hidCode);
                        }
                    }
                    else if (isUp)
                    {
                        PressedKeys.Remove(data.vkCode);
                        Thread.Sleep(80);
                        AddPending(PendingKeyUp, hidCode);
                        Send("U " + hidCode);
                    }

                    return (IntPtr)1;
                }
                catch (Exception error)
                {
                    Console.WriteLine("Serial error: " + error.Message);
                    RequestStop();
                    return (IntPtr)1;
                }
            }
        }

        return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
    }

    private static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && running)
        {
            MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(
                lParam,
                typeof(MSLLHOOKSTRUCT));

            int message = wParam.ToInt32();
            bool isInjected = (data.flags & LLMHF_INJECTED) != 0;
            int button = 0;
            bool isDown = false;
            bool isUp = false;

            if (message == WM_LBUTTONDOWN) { button = 1; isDown = true; }
            else if (message == WM_LBUTTONUP) { button = 1; isUp = true; }
            else if (message == WM_RBUTTONDOWN) { button = 2; isDown = true; }
            else if (message == WM_RBUTTONUP) { button = 2; isUp = true; }
            else if (message == WM_MBUTTONDOWN) { button = 3; isDown = true; }
            else if (message == WM_MBUTTONUP) { button = 3; isUp = true; }

            bool isWheel = message == WM_MOUSEWHEEL;
            if ((isInjected || parsecMode) && (button != 0 || isWheel))
            {
                if (parsecMode && !isInjected)
                {
                    if (isDown && ConsumeMousePending(PendingMouseDown, button))
                    {
                        return CallNextHookEx(mouseHookHandle, nCode, wParam, lParam);
                    }
                    if (isUp && ConsumeMousePending(PendingMouseUp, button))
                    {
                        return CallNextHookEx(mouseHookHandle, nCode, wParam, lParam);
                    }
                    if (isWheel && pendingWheelEcho > 0)
                    {
                        pendingWheelEcho--;
                        return CallNextHookEx(mouseHookHandle, nCode, wParam, lParam);
                    }
                }

                try
                {
                    if (button != 0)
                    {
                        if (isUp)
                        {
                            Thread.Sleep(80);
                        }
                        if (parsecMode)
                        {
                            int[] pending = isDown ? PendingMouseDown : PendingMouseUp;
                            pending[button]++;
                        }
                        Send("B " + button + (isDown ? " 1" : " 0"));
                        return (IntPtr)1;
                    }

                    short delta = (short)((data.mouseData >> 16) & 0xFFFF);
                    wheelRemainder += delta;
                    int ticks = wheelRemainder / 120;
                    wheelRemainder %= 120;
                    if (ticks != 0)
                    {
                        if (parsecMode)
                        {
                            pendingWheelEcho += Math.Abs(ticks);
                        }
                        Send("V " + ticks);
                    }
                    return (IntPtr)1;
                }
                catch (Exception error)
                {
                    Console.WriteLine("Serial error: " + error.Message);
                    RequestStop();
                    return (IntPtr)1;
                }
            }
        }

        return CallNextHookEx(mouseHookHandle, nCode, wParam, lParam);
    }

    private static void AddPending(Dictionary<byte, int> pending, byte code)
    {
        if (!parsecMode)
        {
            return;
        }

        int count;
        pending.TryGetValue(code, out count);
        pending[code] = count + 1;
    }

    private static bool ConsumePending(Dictionary<byte, int> pending, byte code)
    {
        int count;
        if (!pending.TryGetValue(code, out count) || count <= 0)
        {
            return false;
        }

        if (count == 1)
        {
            pending.Remove(code);
        }
        else
        {
            pending[code] = count - 1;
        }
        return true;
    }

    private static bool ConsumeMousePending(int[] pending, int button)
    {
        if (pending[button] <= 0)
        {
            return false;
        }

        pending[button]--;
        return true;
    }

    private static void Heartbeat(object state)
    {
        if (!running)
        {
            return;
        }

        try
        {
            Send("H");
        }
        catch (Exception error)
        {
            Console.WriteLine("Connection lost: " + error.Message);
            RequestStop();
        }
    }

    private static void Send(string command)
    {
        lock (SerialSync)
        {
            if (serial == null || !serial.IsOpen)
            {
                throw new InvalidOperationException("Serial port is not open.");
            }

            serial.WriteLine(command);
        }
    }

    private static void ConsoleCancel(object sender, ConsoleCancelEventArgs args)
    {
        args.Cancel = true;
        RequestStop();
    }

    private static void RequestStop()
    {
        if (!running)
        {
            return;
        }

        running = false;
        PostThreadMessage(mainThreadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }
}
"@

Add-Type -TypeDefinition $source -ReferencedAssemblies System.dll
[RemoteHidBridge]::Run($Port, $BaudRate, $ParsecMode.IsPresent)
