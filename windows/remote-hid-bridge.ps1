[CmdletBinding()]
param(
    [string]$Port = "",
    [int]$BaudRate = 115200,
    [switch]$ParsecMode,
    [switch]$LineageMode
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
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO.Ports;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
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
    private static extern short GetAsyncKeyState(int virtualKey);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr windowHandle, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr windowHandle, StringBuilder text, int maximumLength);

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
    private static readonly HashSet<byte> PressedKeys = new HashSet<byte>();
    private static readonly HashSet<byte> ReleasingKeys = new HashSet<byte>();
    private static readonly Random InputRandom = new Random();
    private static readonly Dictionary<byte, int> PendingKeyDown = new Dictionary<byte, int>();
    private static readonly Dictionary<byte, int> PendingKeyUp = new Dictionary<byte, int>();
    private static readonly int[] PendingMouseDown = new int[4];
    private static readonly int[] PendingMouseUp = new int[4];
    private static readonly object SerialSync = new object();
    private static readonly object StateSync = new object();
    private static readonly object ExpectedSync = new object();
    private static readonly object LogSync = new object();
    private static readonly string LogPath = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RemoteHidBridge",
        "bridge.log");
    private static readonly byte[] ExpectedKeys = new byte[6];

    private sealed class BridgeCommand
    {
        public string Text;
        public DateTime Due;
        public long Generation;

        public BridgeCommand(string text, int delayMilliseconds, long generation)
        {
            Text = text;
            Due = DateTime.UtcNow.AddMilliseconds(delayMilliseconds);
            Generation = generation;
        }
    }

    private static readonly BlockingCollection<BridgeCommand> CommandQueue = new BlockingCollection<BridgeCommand>();
    private static Thread commandWorker;
    private static Thread serialReader;
    private static SerialPort serial;
    private static string serialPortName;
    private static int serialBaudRate;
    private static DateTime reconnectAfter = DateTime.MinValue;
    private static DateTime serialReadyAt;
    private static DateTime helloSentAt;
    private static int helloAttempts;
    private static bool serialWaiting;
    private static bool readyReceived;
    private static bool protocolReady;
    private static uint pingSequence;
    private static uint outstandingPing;
    private static DateTime pingSentAt;
    private static bool pingOutstanding;
    private static int missedPongs;
    private static int lastRttMilliseconds = -1;
    private static long inputGeneration;
    private static ulong inputRevision;
    private static ulong mismatchRevision;
    private static bool mismatchObserved;
    private static byte expectedModifiers;
    private static byte expectedButtons;
    private static volatile bool syncError;
    private static IntPtr keyboardHookHandle = IntPtr.Zero;
    private static IntPtr mouseHookHandle = IntPtr.Zero;
    private static HookProc keyboardHookCallback;
    private static HookProc mouseHookCallback;
    private static System.Threading.Timer heartbeatTimer;
    private static System.Threading.Timer windowTimer;
    private static int heartbeatActive;
    private static int windowActive;
    private static NotifyIcon trayIcon;
    private static ContextMenuStrip trayMenu;
    private static ToolStripMenuItem statusMenuItem;
    private static ToolStripMenuItem pauseMenuItem;
    private static ToolStripMenuItem lineageMenuItem;
    private static ToolStripMenuItem consoleMenuItem;
    private static bool consoleVisible = true;
    private static string trayStatus = "";
    private static int wheelRemainder;
    private static int pendingWheelEcho;
    private static int mainThreadId;
    private static bool parsecMode;
    private static bool autoDetectPort;
    private static volatile bool lineageMode;
    private static bool lineageWindowActive;
    private static volatile int desiredDisplayState;
    private static int sentDisplayState = -1;
    private static volatile bool inputPaused;
    private static volatile bool inputReady;
    private static volatile bool running;

    public static void Run(
        string portName,
        int baudRate,
        bool parsecInputMode,
        string iconPath,
        bool detectPortAutomatically,
        bool lineageInputMode)
    {
        parsecMode = parsecInputMode;
        autoDetectPort = detectPortAutomatically;
        lineageMode = lineageInputMode;
        serialPortName = portName;
        serialBaudRate = baudRate;
        mainThreadId = GetCurrentThreadId();
        keyboardHookCallback = KeyboardHook;
        mouseHookCallback = MouseHook;
        desiredDisplayState = lineageMode ? 3 : 0;

        try
        {
            Log("Starting bridge on " + serialPortName + (parsecMode ? " in Parsec mode" : " in Standard mode"));
            running = true;
            InitializeTray(iconPath);

            commandWorker = new Thread(CommandWorker);
            commandWorker.IsBackground = true;
            commandWorker.Start();

            keyboardHookHandle = InstallHook(WH_KEYBOARD_LL, keyboardHookCallback);
            mouseHookHandle = InstallHook(WH_MOUSE_LL, mouseHookCallback);

            Console.CancelKeyPress += ConsoleCancel;
            heartbeatTimer = new System.Threading.Timer(Heartbeat, null, 0, 500);
            windowTimer = new System.Threading.Timer(WindowHeartbeat, null, 0, 200);

            Console.WriteLine("Remote HID bridge is starting on " + portName + ".");
            Console.WriteLine("Protocol: HELLO 2 / READY 2, PING/PONG with HID state verification.");
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
            CommandQueue.CompleteAdding();

            if (heartbeatTimer != null)
            {
                heartbeatTimer.Dispose();
            }
            if (windowTimer != null)
            {
                windowTimer.Dispose();
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
            if (commandWorker != null)
            {
                commandWorker.Join(2000);
                commandWorker = null;
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
                    if (serial != null && serial.IsOpen && protocolReady)
                    {
                        serial.WriteLine("R");
                    }
                }
                catch (Exception error)
                {
                    Console.WriteLine("Could not send final release: " + error.Message);
                    Log("Final release failed: " + error.Message);
                }
                finally
                {
                    CloseSerial();
                }
            }
            if (serialReader != null)
            {
                serialReader.Join(500);
                serialReader = null;
            }
            Log("Bridge stopped");
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
        lineageMenuItem = new ToolStripMenuItem("Lineage mode", null, LineageMenuClick);
        lineageMenuItem.Checked = lineageMode;
        trayMenu.Items.Add(lineageMenuItem);
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

    private static void Log(string message)
    {
        try
        {
            lock (LogSync)
            {
                string directory = System.IO.Path.GetDirectoryName(LogPath);
                System.IO.Directory.CreateDirectory(directory);
                if (System.IO.File.Exists(LogPath)
                    && new System.IO.FileInfo(LogPath).Length >= 256 * 1024)
                {
                    System.IO.File.Copy(LogPath, LogPath + ".old", true);
                    System.IO.File.WriteAllText(LogPath, string.Empty);
                }
                System.IO.File.AppendAllText(
                    LogPath,
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
            }
        }
        catch
        {
        }
    }

    private static void SetConnectionStatus(string status)
    {
        inputReady = status == "Connected" && protocolReady;
        if (trayStatus == status)
        {
            return;
        }

        trayStatus = status;
        Console.WriteLine("Status: " + status);
        Log("Status: " + status + " (" + serialPortName + ")");
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
        string rtt = lastRttMilliseconds >= 0 ? " | " + lastRttMilliseconds + " ms" : "";
        string text = "HID Bridge: " + trayStatus + paused + " (" + serialPortName + ")";
        trayIcon.Text = text.Length <= 63 ? text : text.Substring(0, 63);
        statusMenuItem.Text = trayStatus + " | " + serialPortName + " | " + mode + paused + rtt;
    }

    private static void PauseMenuClick(object sender, EventArgs args)
    {
        inputPaused = !inputPaused;
        if (inputPaused)
        {
            ReleaseControls();
        }
        pauseMenuItem.Text = inputPaused ? "Resume input" : "Pause input";
        Log(inputPaused ? "Input paused" : "Input resumed");
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

    private static void LineageMenuClick(object sender, EventArgs args)
    {
        lineageMode = !lineageMode;
        lineageMenuItem.Checked = lineageMode;
        lineageWindowActive = false;
        ReleaseControls();
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

    private static long CurrentGeneration()
    {
        return Interlocked.Read(ref inputGeneration);
    }

    private static void ReleaseControls()
    {
        Interlocked.Increment(ref inputGeneration);
        lock (StateSync)
        {
            ResetInputState();
        }
        EnqueueCommand("R", 0);
    }

    private static void ResetInputState()
    {
        PressedKeys.Clear();
        ReleasingKeys.Clear();
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
        SerialPort newPort = new SerialPort(serialPortName, serialBaudRate);
        newPort.NewLine = "\n";
        newPort.DtrEnable = true;
        newPort.RtsEnable = true;
        newPort.WriteTimeout = 1000;
        newPort.ReadTimeout = 250;
        try
        {
            newPort.Open();
        }
        catch
        {
            newPort.Dispose();
            throw;
        }

        serial = newPort;
        serialWaiting = waitForReset;
        serialReadyAt = DateTime.UtcNow.AddSeconds(2);
        helloSentAt = DateTime.MinValue;
        helloAttempts = 0;
        readyReceived = false;
        protocolReady = false;
        pingOutstanding = false;
        missedPongs = 0;
        lastRttMilliseconds = -1;
        sentDisplayState = -1;
        syncError = false;
        Interlocked.Increment(ref inputGeneration);

        serialReader = new Thread(SerialReader);
        serialReader.IsBackground = true;
        serialReader.Start(newPort);
    }

    private static void CloseSerial()
    {
        serialWaiting = false;
        readyReceived = false;
        protocolReady = false;
        pingOutstanding = false;
        SerialPort oldPort = serial;
        serial = null;
        if (oldPort == null)
        {
            return;
        }

        try
        {
            if (oldPort.IsOpen)
            {
                oldPort.Close();
            }
        }
        catch
        {
        }
        finally
        {
            oldPort.Dispose();
        }
    }

    private static bool IsCurrentPort(SerialPort port)
    {
        lock (SerialSync)
        {
            return Object.ReferenceEquals(serial, port);
        }
    }

    private static void SerialReader(object state)
    {
        SerialPort readerPort = (SerialPort)state;
        while (running && IsCurrentPort(readerPort))
        {
            try
            {
                string line = readerPort.ReadLine().Trim();
                if (!IsCurrentPort(readerPort))
                {
                    return;
                }
                ProcessSerialLine(readerPort, line);
            }
            catch (TimeoutException)
            {
            }
            catch (Exception error)
            {
                if (IsCurrentPort(readerPort))
                {
                    HandleConnectionError(error);
                }
                return;
            }
        }
    }

    private static void ProcessSerialLine(SerialPort readerPort, string line)
    {
        if (line.StartsWith("READY ", StringComparison.Ordinal))
        {
            string version = line.Substring(6);
            lock (SerialSync)
            {
                if (!Object.ReferenceEquals(serial, readerPort) || !serialWaiting || helloAttempts == 0)
                {
                    return;
                }
                if (version == "2")
                {
                    readyReceived = true;
                    return;
                }
            }
            HandleProtocolMismatch(version);
            return;
        }

        string[] parts = line.Split(' ');
        if (parts.Length != 5 || parts[0] != "PONG")
        {
            return;
        }

        uint sequence;
        byte modifiers;
        byte buttons;
        if (!UInt32.TryParse(parts[1], out sequence)
            || !TryParseHexByte(parts[2], out modifiers)
            || !TryParseHexByte(parts[3], out buttons)
            || parts[4].Length != 12)
        {
            return;
        }

        byte[] keys = new byte[6];
        for (int i = 0; i < keys.Length; i++)
        {
            if (!TryParseHexByte(parts[4].Substring(i * 2, 2), out keys[i]))
            {
                return;
            }
        }
        ProcessPong(readerPort, sequence, modifiers, buttons, keys);
    }

    private static bool TryParseHexByte(string text, out byte value)
    {
        return Byte.TryParse(
            text,
            System.Globalization.NumberStyles.HexNumber,
            System.Globalization.CultureInfo.InvariantCulture,
            out value);
    }

    private static void ProcessPong(
        SerialPort readerPort,
        uint sequence,
        byte modifiers,
        byte buttons,
        byte[] keys)
    {
        lock (SerialSync)
        {
            if (!Object.ReferenceEquals(serial, readerPort)
                || !protocolReady || !pingOutstanding || sequence != outstandingPing)
            {
                return;
            }

            pingOutstanding = false;
            missedPongs = 0;
            lastRttMilliseconds = Math.Max(0, (int)(DateTime.UtcNow - pingSentAt).TotalMilliseconds);
            serial.WriteLine("T " + lastRttMilliseconds);
        }
        UpdateStatusText();
        CompareHidState(modifiers, buttons, keys);
    }

    private static void HandleProtocolMismatch(string version)
    {
        string message = "Protocol mismatch: expected READY 2, received READY " + version;
        Console.WriteLine(message);
        Log(message);
        Interlocked.Increment(ref inputGeneration);
        lock (SerialSync)
        {
            CloseSerial();
            reconnectAfter = DateTime.UtcNow.AddSeconds(2);
        }
        ResetAllState();
        SetConnectionStatus("Protocol mismatch");
    }

    private static void HandleConnectionError(Exception error)
    {
        bool reportError = trayStatus == "Connected";
        Interlocked.Increment(ref inputGeneration);
        lock (SerialSync)
        {
            CloseSerial();
            reconnectAfter = DateTime.UtcNow.AddSeconds(1);
        }
        ResetAllState();
        SetConnectionStatus("Reconnecting");
        Log("Connection lost: " + error.Message);
        if (reportError)
        {
            Console.WriteLine("Connection lost: " + error.Message);
        }
    }

    private static void ResetAllState()
    {
        lock (StateSync)
        {
            ResetInputState();
        }
        lock (ExpectedSync)
        {
            ResetExpectedState();
            mismatchObserved = false;
        }
        syncError = false;
        lastRttMilliseconds = -1;
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
                            return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
                        }
                        if (isUp && ConsumePending(PendingKeyUp, hidCode))
                        {
                            if (ReleasingKeys.Remove(hidCode))
                            {
                                PressedKeys.Remove(hidCode);
                            }
                            return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
                        }
                        if (isDown && PressedKeys.Contains(hidCode))
                        {
                            return CallNextHookEx(keyboardHookHandle, nCode, wParam, lParam);
                        }
                    }

                    if (isDown)
                    {
                        bool isRepress = ReleasingKeys.Remove(hidCode);
                        if (PressedKeys.Add(hidCode) || isRepress)
                        {
                            AddPending(PendingKeyDown, hidCode);
                            EnqueueCommand("D " + hidCode, 0);
                        }
                    }
                    else if (isUp)
                    {
                        if (parsecMode)
                        {
                            if (!PressedKeys.Contains(hidCode) || !ReleasingKeys.Add(hidCode))
                            {
                                return (IntPtr)1;
                            }
                        }
                        else
                        {
                            PressedKeys.Remove(hidCode);
                        }
                        AddPending(PendingKeyUp, hidCode);
                        EnqueueCommand("U " + hidCode, InputRandom.Next(65, 96));
                    }
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

                    if (button != 0)
                    {
                        if (parsecMode)
                        {
                            int[] pending = isDown ? PendingMouseDown : PendingMouseUp;
                            pending[button]++;
                        }
                        EnqueueCommand(
                            "B " + button + (isDown ? " 1" : " 0"),
                            isUp ? InputRandom.Next(65, 96) : 0);
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
                        EnqueueCommand("V " + ticks, 0);
                    }
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

                if (!protocolReady)
                {
                    if (readyReceived)
                    {
                        serial.WriteLine("R");
                        lock (ExpectedSync)
                        {
                            ResetExpectedState();
                            inputRevision++;
                        }
                        lock (StateSync)
                        {
                            ResetInputState();
                        }
                        Interlocked.Increment(ref inputGeneration);
                        readyReceived = false;
                        serialWaiting = false;
                        protocolReady = true;
                        pingOutstanding = false;
                        missedPongs = 0;
                        sentDisplayState = -1;
                        SetConnectionStatus("Connected");
                        return;
                    }

                    if (DateTime.UtcNow < serialReadyAt)
                    {
                        return;
                    }
                    if (helloAttempts >= 4)
                    {
                        throw new InvalidOperationException("READY 2 was not received; protocol handshake failed.");
                    }
                    if (helloAttempts == 0 || DateTime.UtcNow - helloSentAt >= TimeSpan.FromMilliseconds(500))
                    {
                        serial.WriteLine("HELLO 2");
                        helloAttempts++;
                        helloSentAt = DateTime.UtcNow;
                        SetConnectionStatus("Waiting for READY 2");
                    }
                    return;
                }

                if (pingOutstanding)
                {
                    missedPongs++;
                    if (missedPongs >= 2)
                    {
                        throw new InvalidOperationException("Two consecutive PONG responses were missed.");
                    }
                }
                pingSequence++;
                outstandingPing = pingSequence;
                pingSentAt = DateTime.UtcNow;
                pingOutstanding = true;
                serial.WriteLine("PING " + pingSequence);
            }
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

    private static void EnqueueCommand(string command, int delayMilliseconds)
    {
        if (!running)
        {
            return;
        }
        try
        {
            CommandQueue.Add(new BridgeCommand(command, delayMilliseconds, CurrentGeneration()));
        }
        catch (InvalidOperationException)
        {
        }
    }

    private static void CommandWorker()
    {
        try
        {
            foreach (BridgeCommand command in CommandQueue.GetConsumingEnumerable())
            {
                if (!running)
                {
                    break;
                }
                if (!inputReady || command.Generation != CurrentGeneration())
                {
                    continue;
                }

                TimeSpan delay = command.Due - DateTime.UtcNow;
                if (delay.TotalMilliseconds > 0)
                {
                    Thread.Sleep((int)Math.Ceiling(delay.TotalMilliseconds));
                }
                if (!running || !inputReady || command.Generation != CurrentGeneration())
                {
                    continue;
                }

                try
                {
                    lock (SerialSync)
                    {
                        Send(command.Text);
                        lock (ExpectedSync)
                        {
                            UpdateExpectedState(command.Text);
                        }
                    }
                }
                catch (Exception error)
                {
                    HandleConnectionError(error);
                }
            }
        }
        catch (Exception error)
        {
            HandleConnectionError(error);
        }
    }

    private static void Send(string command)
    {
        lock (SerialSync)
        {
            if (serial == null || !serial.IsOpen)
            {
                throw new InvalidOperationException("Serial port is not ready.");
            }
            serial.WriteLine(command);
        }
    }

    private static byte ProtocolToHidCode(byte code)
    {
        if (code >= 'a' && code <= 'z') return (byte)(0x04 + code - 'a');
        if (code >= '1' && code <= '9') return (byte)(0x1E + code - '1');
        if (code == '0') return 0x27;
        if (code == ' ') return 0x2C;
        if (code >= 0xC1 && code <= 0xCC) return (byte)(0x3A + code - 0xC1);
        switch (code)
        {
            case 0xB0: return 0x28;
            case 0xB1: return 0x29;
            case 0xB3: return 0x2B;
            case 0xD7: return 0x4F;
            case 0xD8: return 0x50;
            case 0xD9: return 0x51;
            case 0xDA: return 0x52;
            default: return 0;
        }
    }

    private static void UpdateExpectedState(string command)
    {
        string[] parts = command.Split(' ');
        lock (ExpectedSync)
        {
            if (parts[0] == "R")
            {
                ResetExpectedState();
                inputRevision++;
                return;
            }
            if (parts[0] == "D" || parts[0] == "U")
            {
                byte code = Byte.Parse(parts[1]);
                if (code >= 0x80 && code <= 0x87)
                {
                    byte mask = (byte)(1 << (code - 0x80));
                    if (parts[0] == "D") expectedModifiers |= mask;
                    else expectedModifiers &= (byte)~mask;
                }
                else
                {
                    byte hidCode = ProtocolToHidCode(code);
                    if (hidCode != 0)
                    {
                        if (parts[0] == "D") AddExpectedKey(hidCode);
                        else RemoveExpectedKey(hidCode);
                    }
                }
                inputRevision++;
                return;
            }
            if (parts[0] == "B")
            {
                int button = Int32.Parse(parts[1]);
                byte mask = (byte)(1 << (button - 1));
                if (parts[2] == "1") expectedButtons |= mask;
                else expectedButtons &= (byte)~mask;
                inputRevision++;
            }
        }
    }

    private static void AddExpectedKey(byte hidCode)
    {
        for (int i = 0; i < ExpectedKeys.Length; i++)
        {
            if (ExpectedKeys[i] == hidCode) return;
        }
        for (int i = 0; i < ExpectedKeys.Length; i++)
        {
            if (ExpectedKeys[i] == 0)
            {
                ExpectedKeys[i] = hidCode;
                return;
            }
        }
    }

    private static void RemoveExpectedKey(byte hidCode)
    {
        for (int i = 0; i < ExpectedKeys.Length; i++)
        {
            if (ExpectedKeys[i] == hidCode)
            {
                ExpectedKeys[i] = 0;
                return;
            }
        }
    }

    private static void ResetExpectedState()
    {
        expectedModifiers = 0;
        expectedButtons = 0;
        Array.Clear(ExpectedKeys, 0, ExpectedKeys.Length);
    }

    private static void CompareHidState(byte modifiers, byte buttons, byte[] keys)
    {
        bool recover = false;
        bool clearSyncError = false;
        lock (ExpectedSync)
        {
            bool matches = expectedModifiers == modifiers
                && expectedButtons == buttons
                && KeysMatch(keys);
            if (matches)
            {
                mismatchObserved = false;
                clearSyncError = syncError;
            }
            else if (!mismatchObserved || mismatchRevision != inputRevision)
            {
                mismatchObserved = true;
                mismatchRevision = inputRevision;
            }
            else
            {
                recover = true;
            }
        }

        if (recover)
        {
            RecoverHidState();
        }
        else if (clearSyncError)
        {
            syncError = false;
            lock (SerialSync)
            {
                sentDisplayState = -1;
            }
        }
    }

    private static bool KeysMatch(byte[] actualKeys)
    {
        byte[] expectedSorted = (byte[])ExpectedKeys.Clone();
        byte[] actualSorted = (byte[])actualKeys.Clone();
        Array.Sort(expectedSorted);
        Array.Sort(actualSorted);
        for (int i = 0; i < expectedSorted.Length; i++)
        {
            if (expectedSorted[i] != actualSorted[i]) return false;
        }
        return true;
    }

    private static void RecoverHidState()
    {
        Log("HID state mismatch; controls released.");
        syncError = true;
        Interlocked.Increment(ref inputGeneration);
        lock (StateSync)
        {
            ResetInputState();
        }
        lock (SerialSync)
        {
            if (serial == null || !serial.IsOpen || !protocolReady)
            {
                return;
            }
            serial.WriteLine("R");
            lock (ExpectedSync)
            {
                ResetExpectedState();
                inputRevision++;
                mismatchObserved = false;
            }
            serial.WriteLine("S 5");
            sentDisplayState = 5;
        }
    }

    private static void WindowHeartbeat(object state)
    {
        if (!running || Interlocked.Exchange(ref windowActive, 1) == 1)
        {
            return;
        }
        try
        {
            bool active = lineageMode && IsLineageWindowActive();
            if (lineageMode && lineageWindowActive && !active)
            {
                ReleaseControls();
            }
            lineageWindowActive = active;
            desiredDisplayState = GetDesiredDisplayState();

            if (!inputReady || syncError || desiredDisplayState == sentDisplayState)
            {
                return;
            }
            lock (SerialSync)
            {
                if (!inputReady || syncError || serial == null || !serial.IsOpen
                    || desiredDisplayState == sentDisplayState)
                {
                    return;
                }
                serial.WriteLine("S " + desiredDisplayState);
                sentDisplayState = desiredDisplayState;
            }
        }
        catch (Exception error)
        {
            HandleConnectionError(error);
        }
        finally
        {
            Interlocked.Exchange(ref windowActive, 0);
        }
    }

    private static int GetDesiredDisplayState()
    {
        if (!lineageMode) return inputPaused ? 1 : 0;
        if (inputPaused) return 4;
        return lineageWindowActive ? 2 : 3;
    }

    private static bool IsLineageWindowActive()
    {
        IntPtr window = GetForegroundWindow();
        if (window == IntPtr.Zero) return false;

        uint processId;
        GetWindowThreadProcessId(window, out processId);
        try
        {
            using (Process process = Process.GetProcessById((int)processId))
            {
                if (String.Equals(process.ProcessName, "l2", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }
        catch
        {
        }

        StringBuilder title = new StringBuilder(256);
        GetWindowText(window, title, title.Capacity);
        return title.ToString().IndexOf("Lineage", StringComparison.OrdinalIgnoreCase) >= 0;
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
[RemoteHidBridge]::Run(
    $Port,
    $BaudRate,
    $ParsecMode.IsPresent,
    (Join-Path $PSScriptRoot 'bridge.ico'),
    $autoDetectPort,
    $LineageMode.IsPresent)
