[CmdletBinding()]
param(
    [string]$Port = "",
    [int]$BaudRate = 115200,
    [switch]$ParsecMode
)

$autoDetectPort = [string]::IsNullOrWhiteSpace($Port)
if ($autoDetectPort) {
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
using System.Drawing;
using System.IO.Ports;
using System.Management;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

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

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

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
    private static readonly object StateSync = new object();

    private static SerialPort serial;
    private static string serialPortName;
    private static int serialBaudRate;
    private static DateTime reconnectAfter = DateTime.MinValue;
    private static DateTime serialReadyAt;
    private static bool serialWaiting;
    private static IntPtr keyboardHookHandle = IntPtr.Zero;
    private static IntPtr mouseHookHandle = IntPtr.Zero;
    private static HookProc keyboardHookCallback;
    private static HookProc mouseHookCallback;
    private static System.Threading.Timer heartbeatTimer;
    private static int heartbeatActive;
    private static NotifyIcon trayIcon;
    private static ContextMenuStrip trayMenu;
    private static ToolStripMenuItem statusMenuItem;
    private static ToolStripMenuItem pauseMenuItem;
    private static ToolStripMenuItem consoleMenuItem;
    private static bool consoleVisible = true;
    private static string trayStatus = "";
    private static POINT lastMousePoint;
    private static int wheelRemainder;
    private static int pendingWheelEcho;
    private static int mainThreadId;
    private static bool parsecMode;
    private static bool autoDetectPort;
    private static volatile bool inputPaused;
    private static volatile bool inputReady;
    private static volatile bool running;

    public static void Run(string portName, int baudRate, bool parsecInputMode, string iconPath, bool detectPortAutomatically)
    {
        parsecMode = parsecInputMode;
        autoDetectPort = detectPortAutomatically;
        serialPortName = portName;
        serialBaudRate = baudRate;
        mainThreadId = GetCurrentThreadId();
        keyboardHookCallback = KeyboardHook;
        mouseHookCallback = MouseHook;

        try
        {
            OpenSerial(false);
            Thread.Sleep(2000);
            Send("R");
            GetCursorPos(out lastMousePoint);
            InitializeTray(iconPath);
            SetConnectionStatus("Connected");

            keyboardHookHandle = InstallHook(WH_KEYBOARD_LL, keyboardHookCallback);
            mouseHookHandle = InstallHook(WH_MOUSE_LL, mouseHookCallback);

            Console.CancelKeyPress += ConsoleCancel;
            running = true;
            heartbeatTimer = new System.Threading.Timer(Heartbeat, null, 500, 500);

            Console.WriteLine("Remote HID bridge is running on " + portName + ".");
            Console.WriteLine("Keyboard: A-Z, 0-9, arrows, F1-F12, Space, Enter, Esc, Tab, Shift, Ctrl, Alt.");
            Console.WriteLine("Mouse: cursor movement passes through; left/right/middle buttons and wheel use Arduino.");
            Console.WriteLine(parsecMode
                ? "Parsec mode: virtual HID input is captured with Arduino echo protection."
                : "Standard mode: only remote injected input is captured.");
            Console.WriteLine("Emergency stop: Ctrl+Alt+F12.");
            Console.WriteLine("Use the tray icon to release controls or exit, or press Ctrl+C here.");

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

            if (trayIcon != null)
            {
                trayIcon.Visible = false;
                trayIcon.Dispose();
                trayIcon = null;
            }
            if (trayMenu != null)
            {
                trayMenu.Dispose();
                trayMenu = null;
            }

            lock (SerialSync)
            {
                try
                {
                    if (serial != null && serial.IsOpen && !serialWaiting)
                    {
                        serial.WriteLine("R");
                    }
                }
                catch (Exception error)
                {
                    Console.WriteLine("Could not send final release: " + error.Message);
                }
                finally
                {
                    CloseSerial();
                }
            }
        }
    }

    private static void InitializeTray(string iconPath)
    {
        trayMenu = new ContextMenuStrip();
        statusMenuItem = new ToolStripMenuItem("Starting");
        statusMenuItem.Enabled = false;
        trayMenu.Items.Add(statusMenuItem);
        trayMenu.Items.Add(new ToolStripSeparator());
        pauseMenuItem = new ToolStripMenuItem("Pause input", null, PauseMenuClick);
        trayMenu.Items.Add(pauseMenuItem);
        trayMenu.Items.Add("Reconnect", null, ReconnectMenuClick);
        consoleMenuItem = new ToolStripMenuItem("Hide console", null, ConsoleMenuClick);
        trayMenu.Items.Add(consoleMenuItem);
        trayMenu.Items.Add("Release controls", null, ReleaseMenuClick);
        trayMenu.Items.Add("Exit", null, ExitMenuClick);

        trayIcon = new NotifyIcon();
        trayIcon.Icon = System.IO.File.Exists(iconPath)
            ? new Icon(iconPath)
            : SystemIcons.Application;
        trayIcon.Text = "Arduino Remote HID Bridge";
        trayIcon.ContextMenuStrip = trayMenu;
        trayIcon.DoubleClick += TrayDoubleClick;
        trayIcon.Visible = true;
    }

    private static void SetConnectionStatus(string status)
    {
        inputReady = status == "Connected";
        if (trayStatus == status)
        {
            return;
        }

        trayStatus = status;
        Console.WriteLine("Status: " + status);
        UpdateStatusText();
    }

    private static void UpdateStatusText()
    {
        if (trayIcon == null)
        {
            return;
        }

        string mode = parsecMode ? "Parsec" : "Standard";
        string paused = inputPaused ? " | Paused" : "";
        string text = "HID Bridge: " + trayStatus + paused + " (" + serialPortName + ")";
        trayIcon.Text = text.Length <= 63 ? text : text.Substring(0, 63);
        statusMenuItem.Text = trayStatus + " | " + serialPortName + " | " + mode + paused;
    }

    private static void PauseMenuClick(object sender, EventArgs args)
    {
        inputPaused = !inputPaused;
        if (inputPaused)
        {
            ReleaseControls();
        }
        pauseMenuItem.Text = inputPaused ? "Resume input" : "Pause input";
        UpdateStatusText();
    }

    private static void ReconnectMenuClick(object sender, EventArgs args)
    {
        ReleaseControls();
        lock (SerialSync)
        {
            CloseSerial();
            reconnectAfter = DateTime.MinValue;
        }
        SetConnectionStatus("Reconnecting");
        Heartbeat(null);
    }

    private static void ConsoleMenuClick(object sender, EventArgs args)
    {
        IntPtr consoleWindow = GetConsoleWindow();
        if (consoleWindow == IntPtr.Zero)
        {
            return;
        }

        consoleVisible = !consoleVisible;
        ShowWindow(consoleWindow, consoleVisible ? 5 : 0);
        consoleMenuItem.Text = consoleVisible ? "Hide console" : "Show console";
    }

    private static void ReleaseMenuClick(object sender, EventArgs args)
    {
        ReleaseControls();
    }

    private static void ExitMenuClick(object sender, EventArgs args)
    {
        ReleaseControls();
        RequestStop();
    }

    private static void TrayDoubleClick(object sender, EventArgs args)
    {
        ReleaseControls();
    }

    private static void ReleaseControls()
    {
        try
        {
            Send("R");
        }
        catch (Exception error)
        {
            HandleConnectionError(error);
        }

        lock (StateSync)
        {
            ResetInputState();
        }
    }

    private static void ResetInputState()
    {
        PressedKeys.Clear();
        PendingKeyDown.Clear();
        PendingKeyUp.Clear();
        Array.Clear(PendingMouseDown, 0, PendingMouseDown.Length);
        Array.Clear(PendingMouseUp, 0, PendingMouseUp.Length);
        wheelRemainder = 0;
        pendingWheelEcho = 0;
    }

    private static string DetectArduinoPort()
    {
        List<string> arduinoPorts = new List<string>();
        List<string> usbPorts = new List<string>();

        using (ManagementObjectSearcher searcher = new ManagementObjectSearcher(
            "SELECT DeviceID, Name, PNPDeviceID FROM Win32_SerialPort"))
        using (ManagementObjectCollection results = searcher.Get())
        {
            foreach (ManagementObject port in results)
            {
                string deviceId = Convert.ToString(port["DeviceID"]);
                string name = Convert.ToString(port["Name"]);
                string pnpId = Convert.ToString(port["PNPDeviceID"]);

                if (ContainsText(name, "Arduino Leonardo") || ContainsText(name, "Pro Micro")
                    || ContainsText(pnpId, "VID_2341&PID_") || ContainsText(pnpId, "VID_1B4F&PID_"))
                {
                    arduinoPorts.Add(deviceId);
                }
                if (pnpId != null && pnpId.StartsWith("USB", StringComparison.OrdinalIgnoreCase))
                {
                    usbPorts.Add(deviceId);
                }
                port.Dispose();
            }
        }

        List<string> candidates = arduinoPorts.Count > 0 ? arduinoPorts : usbPorts;
        return candidates.Count == 1 ? candidates[0] : null;
    }

    private static bool ContainsText(string value, string fragment)
    {
        return value != null && value.IndexOf(fragment, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static void OpenSerial(bool waitForReset)
    {
        serial = new SerialPort(serialPortName, serialBaudRate);
        serial.NewLine = "\n";
        serial.WriteTimeout = 1000;
        serial.Open();
        serialWaiting = waitForReset;
        serialReadyAt = DateTime.UtcNow.AddSeconds(2);
    }

    private static void CloseSerial()
    {
        serialWaiting = false;
        if (serial == null)
        {
            return;
        }

        try
        {
            if (serial.IsOpen)
            {
                serial.Close();
            }
        }
        catch
        {
        }
        finally
        {
            serial.Dispose();
            serial = null;
        }
    }

    private static void HandleConnectionError(Exception error)
    {
        bool reportError = trayStatus == "Connected";
        lock (SerialSync)
        {
            CloseSerial();
            reconnectAfter = DateTime.UtcNow.AddSeconds(1);
        }
        lock (StateSync)
        {
            ResetInputState();
        }
        SetConnectionStatus("Reconnecting");
        if (reportError)
        {
            Console.WriteLine("Connection lost: " + error.Message);
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
            lock (StateSync)
            {
                KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(
                    lParam,
                    typeof(KBDLLHOOKSTRUCT));

                int message = wParam.ToInt32();
                if (message == WM_KEYDOWN && data.vkCode == 0x7B
                    && (GetAsyncKeyState(0x11) & 0x8000) != 0
                    && (GetAsyncKeyState(0x12) & 0x8000) != 0)
                {
                    ReleaseControls();
                    RequestStop();
                    return (IntPtr)1;
                }

                byte hidCode;
                bool isInjected = (data.flags & LLKHF_INJECTED) != 0;
                bool isMapped = KeyMap.TryGetValue(data.vkCode, out hidCode);

                if (parsecMode)
                {
                    Console.WriteLine("K vk=" + data.vkCode + " scan=" + data.scanCode
                        + " flags=" + data.flags + " msg=" + message
                        + " hid=" + hidCode + " mapped=" + isMapped);
                }

                if (isMapped && (isInjected || parsecMode))
                {
                    if (!inputReady)
                    {
                        return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
                    }
                    if (inputPaused)
                    {
                        return (IntPtr)1;
                    }

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
                        HandleConnectionError(error);
                        return (IntPtr)1;
                    }
                }
            }
        }

        return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
    }

    private static IntPtr MouseHook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 && running)
        {
            lock (StateSync)
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
                    if (!inputReady)
                    {
                        return CallNextHookEx(mouseHookHandle, nCode, wParam, lParam);
                    }
                    if (inputPaused)
                    {
                        return (IntPtr)1;
                    }

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
                        HandleConnectionError(error);
                        return (IntPtr)1;
                    }
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
        if (!running || Interlocked.Exchange(ref heartbeatActive, 1) == 1)
        {
            return;
        }

        try
        {
            lock (SerialSync)
            {
                if (!running)
                {
                    return;
                }

                if (serial == null)
                {
                    if (DateTime.UtcNow < reconnectAfter)
                    {
                        return;
                    }
                    if (autoDetectPort)
                    {
                        string detectedPort = DetectArduinoPort();
                        if (detectedPort == null)
                        {
                            reconnectAfter = DateTime.UtcNow.AddSeconds(1);
                            SetConnectionStatus("Port not found");
                            return;
                        }
                        if (serialPortName != detectedPort)
                        {
                            serialPortName = detectedPort;
                            Console.WriteLine("Arduino port: " + detectedPort);
                        }
                    }
                    OpenSerial(true);
                    SetConnectionStatus("Waiting for Arduino");
                    return;
                }

                if (serialWaiting)
                {
                    if (DateTime.UtcNow < serialReadyAt)
                    {
                        return;
                    }
                    serialWaiting = false;
                    serial.WriteLine("R");
                }

                Send("H");
            }
            SetConnectionStatus("Connected");
        }
        catch (Exception error)
        {
            HandleConnectionError(error);
        }
        finally
        {
            Interlocked.Exchange(ref heartbeatActive, 0);
        }
    }

    private static void Send(string command)
    {
        lock (SerialSync)
        {
            if (serial == null || !serial.IsOpen || serialWaiting)
            {
                throw new InvalidOperationException("Serial port is not ready.");
            }

            serial.WriteLine(command);
        }
    }

    private static void ConsoleCancel(object sender, ConsoleCancelEventArgs args)
    {
        args.Cancel = true;
        ReleaseControls();
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

Add-Type -TypeDefinition $source -ReferencedAssemblies System.dll, System.Management.dll, System.Drawing.dll, System.Windows.Forms.dll
[RemoteHidBridge]::Run($Port, $BaudRate, $ParsecMode.IsPresent, (Join-Path $PSScriptRoot 'bridge.ico'), $autoDetectPort)
