# Elmer - 12 text snippets, each bound to Ctrl+Shift+F1 through Ctrl+Shift+F12.
#
# Run with:  powershell -ExecutionPolicy Bypass -File Elmer.ps1
#        or: double-click Elmer.cmd
#
# Snippets are saved, encrypted, to snippets.dat next to this script.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# --- Native hotkey plumbing -------------------------------------------------
# A hidden message-only window owns the hotkey registrations and raises an
# event when one fires. Doing this in C# avoids hand-rolling a WndProc
# delegate with ref parameters from PowerShell.

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class HotkeyListener : NativeWindow, IDisposable {
    public event Action<int> HotkeyPressed;
    private const int WM_HOTKEY = 0x0312;

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, int fsModifiers, int vk);
    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    public HotkeyListener() {
        CreateHandle(new CreateParams());
    }

    public bool Register(int id, int modifiers, int vk) {
        return RegisterHotKey(this.Handle, id, modifiers, vk);
    }

    public void Unregister(int id) {
        UnregisterHotKey(this.Handle, id);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            Action<int> handler = HotkeyPressed;
            if (handler != null) { handler((int)m.WParam); }
        }
        base.WndProc(ref m);
    }

    // True while any modifier key is physically held down. Typing while Ctrl or
    // Shift are still down turns the snippet into a burst of shortcuts.
    public static bool ModifiersDown() {
        int[] keys = { 0x10, 0x11, 0x12, 0x5B, 0x5C }; // Shift, Ctrl, Alt, LWin, RWin
        foreach (int k in keys) {
            if ((GetAsyncKeyState(k) & 0x8000) != 0) { return true; }
        }
        return false;
    }

    public void Dispose() {
        DestroyHandle();
    }
}
'@

# --- Typing -----------------------------------------------------------------
# SendInput with hardware scan codes, rather than SendKeys.
#
# SendKeys delivers one key at a time and drops them when the target app is slow
# to drain its queue; it also parses + ^ % ~ ( ) { } [ ] as control characters.
#
# Scan codes rather than KEYEVENTF_UNICODE, because Unicode injection is not a
# keystroke - it is a character, delivered as VK_PACKET. Apps that read WM_CHAR
# accept it, but anything reading raw keyboard input ignores it: remote consoles
# (vSphere, VMware Remote Console, RDP, VNC) translate scan codes to forward to
# the guest and have nothing to forward for a VK_PACKET. Scan codes are what a
# real keyboard sends, so they work in both worlds.
#
# The catch is that scan codes are layout-dependent: a character has to exist on
# the target window's active layout to have one. Characters that do not fall
# back to a Unicode packet, which still works everywhere except remote consoles.

Add-Type @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public class TypeResult {
    public int Sent;
    public int Total;
    public int Fallbacks;      // chars sent as Unicode packets (not on the layout)
    public bool Ok { get { return Sent == Total; } }
}

public class Typer {
    private const uint INPUT_KEYBOARD        = 1;
    private const uint KEYEVENTF_KEYUP       = 0x0002;
    private const uint KEYEVENTF_UNICODE     = 0x0004;
    private const uint KEYEVENTF_SCANCODE    = 0x0008;
    private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;

    // Scan codes are set 1 make codes, identical across layouts for these keys.
    private const ushort SC_LSHIFT = 0x2A;
    private const ushort SC_LCTRL  = 0x1D;
    private const ushort SC_LALT   = 0x38;
    private const ushort SC_ENTER  = 0x1C;
    private const ushort SC_TAB    = 0x0F;

    // Shift state bits returned in the high byte of VkKeyScanEx.
    private const int ST_SHIFT = 1;
    private const int ST_CTRL  = 2;
    private const int ST_ALT   = 4;

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData;
        public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT {
        public ushort wVk; public ushort wScan; public uint dwFlags;
        public uint time; public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT {
        public uint uMsg; public ushort wParamL; public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public INPUTUNION u;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    private static extern short VkKeyScanEx(char ch, IntPtr hkl);
    [DllImport("user32.dll")]
    private static extern uint MapVirtualKeyEx(uint uCode, uint uMapType, IntPtr hkl);
    [DllImport("user32.dll")]
    private static extern IntPtr GetKeyboardLayout(uint idThread);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    private const uint MAPVK_VK_TO_VSC = 0;

    // The layout that matters is the one the target window is using, not ours.
    private static IntPtr ForegroundLayout() {
        IntPtr hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) { return GetKeyboardLayout(0); }
        return GetKeyboardLayout(GetWindowThreadProcessId(hwnd, IntPtr.Zero));
    }

    private static void AddScan(List<INPUT> list, ushort scan, bool keyUp, bool extended) {
        INPUT e = new INPUT();
        e.type = INPUT_KEYBOARD;
        e.u.ki.wVk = 0;                 // ignored for KEYEVENTF_SCANCODE
        e.u.ki.wScan = scan;
        e.u.ki.dwFlags = KEYEVENTF_SCANCODE;
        if (keyUp) { e.u.ki.dwFlags |= KEYEVENTF_KEYUP; }
        if (extended) { e.u.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY; }
        list.Add(e);
    }

    private static void AddUnicode(List<INPUT> list, char c) {
        INPUT down = new INPUT();
        down.type = INPUT_KEYBOARD;
        down.u.ki.wScan = c;
        down.u.ki.dwFlags = KEYEVENTF_UNICODE;
        list.Add(down);

        INPUT up = down;
        up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        list.Add(up);
    }

    // Bring the held modifiers from "cur" to "want", emitting only the changes
    // so a run of capitals holds Shift down instead of tapping it per letter.
    private static int Shift(List<INPUT> list, int want, int cur) {
        if ((want & ST_SHIFT) != (cur & ST_SHIFT)) { AddScan(list, SC_LSHIFT, (want & ST_SHIFT) == 0, false); }
        if ((want & ST_CTRL)  != (cur & ST_CTRL))  { AddScan(list, SC_LCTRL,  (want & ST_CTRL)  == 0, false); }
        if ((want & ST_ALT)   != (cur & ST_ALT))   { AddScan(list, SC_LALT,   (want & ST_ALT)   == 0, false); }
        return want;
    }

    public static TypeResult TypeText(string text, int delayMs) {
        TypeResult r = new TypeResult();
        if (string.IsNullOrEmpty(text)) { return r; }

        IntPtr hkl = ForegroundLayout();
        List<INPUT[]> groups = new List<INPUT[]>();
        List<INPUT> g = new List<INPUT>();
        int state = 0;

        foreach (char c in text) {
            g.Clear();

            if (c == '\r') { continue; }   // \r\n arrives as two chars
            else if (c == '\n') { state = Shift(g, 0, state); AddScan(g, SC_ENTER, false, false); AddScan(g, SC_ENTER, true, false); }
            else if (c == '\t') { state = Shift(g, 0, state); AddScan(g, SC_TAB, false, false); AddScan(g, SC_TAB, true, false); }
            else {
                short vks = VkKeyScanEx(c, hkl);
                uint scan = 0;
                int want = 0;
                if (vks != -1) {
                    want = (vks >> 8) & 0xFF;
                    scan = MapVirtualKeyEx((uint)(vks & 0xFF), MAPVK_VK_TO_VSC, hkl);
                }
                if (vks == -1 || scan == 0) {
                    // Not reachable on this layout - fall back to a packet.
                    state = Shift(g, 0, state);
                    AddUnicode(g, c);
                    r.Fallbacks++;
                }
                else {
                    // Only Shift/Ctrl/Alt are reachable; anything else (Kana, etc.)
                    // is not something we can synthesize.
                    state = Shift(g, want & (ST_SHIFT | ST_CTRL | ST_ALT), state);
                    AddScan(g, (ushort)scan, false, false);
                    AddScan(g, (ushort)scan, true, false);
                }
            }

            if (g.Count > 0) { groups.Add(g.ToArray()); }
        }

        // Never leave a modifier stuck down.
        if (state != 0) {
            g.Clear();
            Shift(g, 0, state);
            groups.Add(g.ToArray());
        }

        foreach (INPUT[] grp in groups) { r.Total += grp.Length; }
        if (r.Total == 0) { return r; }

        int size = Marshal.SizeOf(typeof(INPUT));
        if (delayMs <= 0) {
            // Fast path: the whole snippet in one call.
            List<INPUT> all = new List<INPUT>(r.Total);
            foreach (INPUT[] grp in groups) { all.AddRange(grp); }
            INPUT[] flat = all.ToArray();
            r.Sent = (int)SendInput((uint)flat.Length, flat, size);
        }
        else {
            // Paced: one key at a time. Remote consoles relay keystrokes to a
            // guest over the network and can drop a fast burst.
            foreach (INPUT[] grp in groups) {
                r.Sent += (int)SendInput((uint)grp.Length, grp, size);
                Thread.Sleep(delayMs);
            }
        }
        return r;
    }
}
'@

$MOD_CONTROL = 0x0002
$MOD_SHIFT   = 0x0004
$VK_F1       = 0x70
$SLOT_COUNT  = 12

# Row geometry. The chip column has to clear "Ctrl+Shift+F12" at Consolas 12
# (~92px of glyphs) plus the chip's 16px padding and 10px right margin.
$CHIP_WIDTH  = 130
$LABEL_WIDTH = 170

# Per-key pause in "Slow" mode. Roughly a fast human typist; slow enough for a
# remote console to relay each keystroke to the guest.
$SLOW_DELAY_MS = 12

# --- Interface --------------------------------------------------------------

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Elmer" Height="720" Width="780" MinWidth="660" MinHeight="420"
        WindowStartupLocation="CenterScreen"
        Background="#FF16161E"
        TextOptions.TextFormattingMode="Display"
        UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Field" TargetType="TextBox">
      <Setter Property="Background" Value="#FF23232E"/>
      <Setter Property="Foreground" Value="#FFE6E6F0"/>
      <Setter Property="BorderBrush" Value="#FF33333F"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="CaretBrush" Value="#FFE6E6F0"/>
      <Setter Property="SelectionBrush" Value="#FF7C6CF0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="#FF7C6CF0"/>
        </Trigger>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="#FF4A4A5A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- A TextBox cannot mask its content, so hidden snippets live in a real
         PasswordBox. Same look as Field, different control. -->
    <Style x:Key="FieldMasked" TargetType="PasswordBox">
      <Setter Property="Background" Value="#FF23232E"/>
      <Setter Property="Foreground" Value="#FFE6E6F0"/>
      <Setter Property="BorderBrush" Value="#FF33333F"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="CaretBrush" Value="#FFE6E6F0"/>
      <Setter Property="SelectionBrush" Value="#FF7C6CF0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="#FF7C6CF0"/>
        </Trigger>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="BorderBrush" Value="#FF4A4A5A"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Eye icon. Drawn as vector paths rather than an icon font, so it cannot
         turn into a missing-glyph box. Unchecked = hidden = plain eye ("click
         to reveal"); checked = revealed = struck-through eye ("click to hide"). -->
    <Style x:Key="EyeToggle" TargetType="ToggleButton">
      <Setter Property="Foreground" Value="#FFE6E6F0"/>
      <Setter Property="Background" Value="#FF2A2A38"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    CornerRadius="6" Padding="12,6">
              <StackPanel Orientation="Horizontal">
                <Viewbox Width="17" Height="17" VerticalAlignment="Center">
                  <Canvas Width="24" Height="24">
                    <Path x:Name="Lid" Stroke="#FFE6E6F0" StrokeThickness="1.6"
                          Data="M 2,12 C 5,6.5 8.5,4 12,4 C 15.5,4 19,6.5 22,12 C 19,17.5 15.5,20 12,20 C 8.5,20 5,17.5 2,12 Z"/>
                    <Path x:Name="Pupil" Fill="#FFE6E6F0"
                          Data="M 8.7,12 A 3.3,3.3 0 1 0 15.3,12 A 3.3,3.3 0 1 0 8.7,12 Z"/>
                    <Path x:Name="Slash" Stroke="#FFE6E6F0" StrokeThickness="1.6"
                          StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                          Visibility="Collapsed" Data="M 3.5,3.5 L 20.5,20.5"/>
                  </Canvas>
                </Viewbox>
                <TextBlock x:Name="Lbl" Text="Show" Margin="8,0,0,0"
                           VerticalAlignment="Center"
                           Foreground="{TemplateBinding Foreground}"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Slash" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Lbl" Property="Text" Value="Hide"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF3A3A4C"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="Background" Value="#FF2A2A38"/>
      <Setter Property="CornerRadius" Value="5"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="ChipText" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF9A9AB8"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="HorizontalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="ColumnHeader" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FF6A6A85"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="Action" TargetType="Button">
      <Setter Property="Foreground" Value="#FFE6E6F0"/>
      <Setter Property="Background" Value="#FF2A2A38"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF3A3A4C"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#FF7C6CF0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <DockPanel Margin="22,18,22,18">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,16">
      <TextBlock Text="Elmer" FontSize="24" FontWeight="SemiBold" Foreground="#FFE6E6F0"/>
      <TextBlock Text="Focus any app, press a shortcut, and the matching snippet types itself."
                 FontSize="12" Foreground="#FF7A7A95" Margin="0,4,0,0" TextWrapping="Wrap"/>
    </StackPanel>

    <!-- Column widths track $CHIP_WIDTH / $LABEL_WIDTH; the 8px right margin
         matches the ScrollViewer padding below so headers line up with rows. -->
    <Grid x:Name="HeaderRow" DockPanel.Dock="Top" Margin="0,0,8,6">
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="HeaderChipCol"/>
        <ColumnDefinition x:Name="HeaderLabelCol"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TextBlock Grid.Column="0" Text="SHORTCUT" Style="{StaticResource ColumnHeader}"/>
      <TextBlock Grid.Column="1" Text="LABEL" Style="{StaticResource ColumnHeader}"/>
      <TextBlock Grid.Column="2" Text="SNIPPET" Style="{StaticResource ColumnHeader}"/>
    </Grid>

    <Border DockPanel.Dock="Bottom" Margin="0,14,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="StatusText" Grid.Column="0" Text="Ready."
                   Foreground="#FF7A7A95" FontSize="12" VerticalAlignment="Center"
                   Margin="0,0,12,0" TextWrapping="Wrap"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <CheckBox x:Name="SlowBox" Content="Slow" Foreground="#FF9A9AB8" FontSize="12"
                    VerticalAlignment="Center" Margin="0,0,14,0"
                    ToolTip="Type one key at a time. Use for remote consoles (vSphere, RDP, VNC) that drop a fast burst of keystrokes."/>
          <ToggleButton x:Name="ShowButton" Style="{StaticResource EyeToggle}" Margin="0,0,8,0"
                        ToolTip="Show or hide the snippet text. Snippets are hidden whenever Elmer starts."/>
          <Button x:Name="ClearButton" Content="Clear all" Style="{StaticResource Action}" Margin="0,0,8,0"/>
          <Button x:Name="SaveButton" Content="Save" Style="{StaticResource Action}"/>
        </StackPanel>
      </Grid>
    </Border>

    <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="0,0,8,0">
      <StackPanel x:Name="RowsPanel"/>
    </ScrollViewer>
  </DockPanel>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$rowsPanel   = $window.FindName('RowsPanel')
$statusText  = $window.FindName('StatusText')
$saveButton  = $window.FindName('SaveButton')
$clearButton = $window.FindName('ClearButton')
$slowBox     = $window.FindName('SlowBox')
$showButton  = $window.FindName('ShowButton')

$fieldStyle  = $window.FindResource('Field')
$maskedStyle = $window.FindResource('FieldMasked')
$chipStyle   = $window.FindResource('Chip')
$chipText    = $window.FindResource('ChipText')

# Keep the header columns in step with the rows built below.
$window.FindName('HeaderChipCol').Width  = New-Object System.Windows.GridLength $CHIP_WIDTH
$window.FindName('HeaderLabelCol').Width = New-Object System.Windows.GridLength $LABEL_WIDTH

# Build the 12 rows: shortcut chip | label | snippet.
# Each snippet cell holds a PasswordBox and a TextBox on top of each other; the
# eye toggle decides which one is visible. Whichever is visible is the live
# value, so the two are synced whenever the toggle flips.
$boxes = New-Object 'System.Collections.Generic.List[System.Windows.Controls.TextBox]'
$masks = New-Object 'System.Collections.Generic.List[System.Windows.Controls.PasswordBox]'
$notes = New-Object 'System.Collections.Generic.List[System.Windows.Controls.TextBox]'
for ($i = 1; $i -le $SLOT_COUNT; $i++) {
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8

    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength $CHIP_WIDTH
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $c2.Width = New-Object System.Windows.GridLength $LABEL_WIDTH
    $c3 = New-Object System.Windows.Controls.ColumnDefinition
    $c3.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)
    $grid.ColumnDefinitions.Add($c3)

    $chip = New-Object System.Windows.Controls.Border
    $chip.Style = $chipStyle
    $chip.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Style = $chipText
    $label.Text = "Ctrl+Shift+F$i"
    $chip.Child = $label
    [System.Windows.Controls.Grid]::SetColumn($chip, 0)
    $grid.Children.Add($chip) | Out-Null

    $note = New-Object System.Windows.Controls.TextBox
    $note.Style = $fieldStyle
    $note.Tag = $i
    $note.Margin = New-Object System.Windows.Thickness 0, 0, 10, 0
    $note.ToolTip = "A label for slot F$i - for your reference only, never typed."
    [System.Windows.Controls.Grid]::SetColumn($note, 1)
    $grid.Children.Add($note) | Out-Null

    $mask = New-Object System.Windows.Controls.PasswordBox
    $mask.Style = $maskedStyle
    $mask.Tag = $i
    [System.Windows.Controls.Grid]::SetColumn($mask, 2)
    $grid.Children.Add($mask) | Out-Null

    $box = New-Object System.Windows.Controls.TextBox
    $box.Style = $fieldStyle
    $box.Tag = $i
    $box.Visibility = [System.Windows.Visibility]::Collapsed   # hidden is the default
    [System.Windows.Controls.Grid]::SetColumn($box, 2)
    $grid.Children.Add($box) | Out-Null

    $rowsPanel.Children.Add($grid) | Out-Null
    $boxes.Add($box)
    $masks.Add($mask)
    $notes.Add($note)
}

# --- Masking -----------------------------------------------------------------

$script:Revealed = $false

function Get-SlotText {
    param([int]$Index)
    if ($script:Revealed) { return $boxes[$Index].Text }
    return $masks[$Index].Password
}

function Set-SlotText {
    param([int]$Index, [string]$Value)
    $boxes[$Index].Text = $Value
    $masks[$Index].Password = $Value
}

function Set-Revealed {
    param([bool]$On)
    for ($i = 0; $i -lt $SLOT_COUNT; $i++) {
        # Copy from whichever control was live before the flip.
        if ($On) { $boxes[$i].Text = $masks[$i].Password }
        else     { $masks[$i].Password = $boxes[$i].Text }

        if ($On) {
            $boxes[$i].Visibility = [System.Windows.Visibility]::Visible
            $masks[$i].Visibility = [System.Windows.Visibility]::Collapsed
        }
        else {
            $boxes[$i].Visibility = [System.Windows.Visibility]::Collapsed
            $masks[$i].Visibility = [System.Windows.Visibility]::Visible
        }
    }
    $script:Revealed = $On
}

# --- Snippet persistence ----------------------------------------------------
# Snippets are secrets, so they are encrypted at rest with DPAPI at CurrentUser
# scope: the key is derived from the Windows account, so only this user on this
# machine can decrypt snippets.dat. Copied to another machine or read by another
# account it is just noise. The extra entropy below ties the blob to Elmer, so
# another app's DPAPI call cannot unwrap it either.
#
# What this does not defend against: code already running as you. DPAPI unwraps
# for anything in your session, and the snippets are plain strings in memory
# while Elmer runs. This raises the bar for a stolen disk or a synced folder,
# not for malware on your account.

Add-Type -AssemblyName System.Security

$script:StoreFile  = Join-Path $PSScriptRoot 'snippets.dat'
$script:LegacyFile = Join-Path $PSScriptRoot 'snippets.json'
$script:Entropy    = [System.Text.Encoding]::UTF8.GetBytes('Elmer/snippets/v1')

function Protect-Json {
    param([string]$Plain)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    try {
        $blob = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $script:Entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Convert]::ToBase64String($blob)
    }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Unprotect-Json {
    param([string]$Base64)
    $blob = [Convert]::FromBase64String($Base64.Trim())
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $blob, $script:Entropy,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [System.Text.Encoding]::UTF8.GetString($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

# A slot is stored as { "note": ..., "text": ... }. Files written before labels
# existed hold a bare string per slot, which still loads as the snippet text.
function Read-Saved {
    param($Saved)

    if ($Saved.PSObject.Properties.Name -contains 'settings') {
        $s = $Saved.settings
        if ($null -ne $s -and $s.PSObject.Properties.Name -contains 'slow') {
            $slowBox.IsChecked = [bool]$s.slow
        }
    }

    for ($i = 0; $i -lt $SLOT_COUNT; $i++) {
        $key = "F$($i + 1)"
        if ($Saved.PSObject.Properties.Name -notcontains $key) { continue }

        $value = $Saved.$key
        if ($null -eq $value) { continue }

        if ($value -is [string]) {
            Set-SlotText $i $value
            continue
        }

        $fields = $value.PSObject.Properties.Name
        if ($fields -contains 'text' -and $null -ne $value.text) {
            Set-SlotText $i ([string]$value.text)
        }
        if ($fields -contains 'note' -and $null -ne $value.note) {
            $notes[$i].Text = [string]$value.note
        }
    }
}

function Load-Snippets {
    if (Test-Path $script:StoreFile) {
        try {
            $json = Unprotect-Json (Get-Content $script:StoreFile -Raw -Encoding UTF8)
            Read-Saved ($json | ConvertFrom-Json)
        }
        catch {
            # Most likely a different Windows account or machine than the one
            # that wrote it. Do not clobber the file - the user may want it back.
            Set-Status "Could not decrypt snippets.dat - it belongs to a different Windows account or machine. $($_.Exception.Message)"
        }
        return
    }

    # One-time migration of the old plaintext store.
    if (Test-Path $script:LegacyFile) {
        try {
            Read-Saved (Get-Content $script:LegacyFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        catch {
            Set-Status "Could not read snippets.json: $($_.Exception.Message)"
            return
        }

        if (-not (Save-Snippets)) { return }   # keep the plaintext if the write failed
        try {
            Remove-Item $script:LegacyFile -Force
            Set-Status "Imported snippets.json into the encrypted snippets.dat and deleted the plaintext file."
        }
        catch {
            Set-Status "Encrypted to snippets.dat, but could not delete the plaintext snippets.json: $($_.Exception.Message)"
        }
    }
}

function Save-Snippets {
    $data = [ordered]@{}
    for ($i = 0; $i -lt $SLOT_COUNT; $i++) {
        $data["F$($i + 1)"] = [ordered]@{
            note = $notes[$i].Text
            text = Get-SlotText $i
        }
    }
    $data['settings'] = [ordered]@{ slow = [bool]$slowBox.IsChecked }
    try {
        $json = $data | ConvertTo-Json -Depth 3
        Set-Content -Path $script:StoreFile -Value (Protect-Json $json) -Encoding UTF8
        Set-Status "Saved to snippets.dat (encrypted)."
        return $true
    }
    catch {
        Set-Status "Save failed: $($_.Exception.Message)"
        return $false
    }
}

function Set-Status {
    param([string]$Message)
    $statusText.Text = $Message
}

# --- Typing -----------------------------------------------------------------

$script:PendingText  = $null
$script:PendingSlot  = 0
$script:Waited       = 0
$script:OwnHwnd      = [IntPtr]::Zero

$POLL_MS   = 10
$WAIT_MAX  = 5000

$typeTimer = New-Object System.Windows.Threading.DispatcherTimer
$typeTimer.Interval = [TimeSpan]::FromMilliseconds($POLL_MS)

$typeTimer.add_Tick({
    # Hold off until the user lets go of Ctrl+Shift, otherwise the snippet is
    # delivered as shortcuts (Ctrl+O opens a dialog, and so on). Give up after
    # 5s so a stuck key cannot wedge things permanently.
    if ([HotkeyListener]::ModifiersDown() -and $script:Waited -lt $WAIT_MAX) {
        $script:Waited += $POLL_MS
        return
    }
    $typeTimer.Stop()

    $text = $script:PendingText
    $slot = $script:PendingSlot
    $script:PendingText = $null
    if ([string]::IsNullOrEmpty($text)) { return }

    if ([HotkeyListener]::GetForegroundWindow() -eq $script:OwnHwnd) {
        Set-Status "Elmer is focused - click into another app, then press the shortcut."
        return
    }

    $delay = 0
    if ($slowBox.IsChecked) { $delay = $SLOW_DELAY_MS }

    $r = [Typer]::TypeText($text, $delay)
    if (-not $r.Ok) {
        # Short of Total means something blocked the input queue partway - most
        # often a window running elevated while Elmer is not.
        Set-Status "Ctrl+Shift+F$slot - only part of the snippet was accepted. Is the target app running as administrator?"
    }
    elseif ($r.Fallbacks -gt 0) {
        # These chars went as Unicode packets, which remote consoles ignore.
        Set-Status "Typed Ctrl+Shift+F$slot ($($text.Length) chars). $($r.Fallbacks) not on the current keyboard layout - those may not reach a remote console."
    }
    else {
        Set-Status "Typed Ctrl+Shift+F$slot ($($text.Length) chars)."
    }
})

$onHotkey = {
    param($id)
    $index = $id - 1
    if ($index -lt 0 -or $index -ge $SLOT_COUNT) { return }

    $text = Get-SlotText $index
    if ([string]::IsNullOrEmpty($text)) {
        Set-Status "Ctrl+Shift+F$($index + 1) is empty - nothing to type."
        return
    }

    $script:PendingText = $text
    $script:PendingSlot = $index + 1
    $script:Waited = 0
    $typeTimer.Start()
}

# --- Wire up ----------------------------------------------------------------

$script:Listener = New-Object HotkeyListener
$script:Listener.add_HotkeyPressed($onHotkey)

$saveButton.add_Click({ Save-Snippets })
$clearButton.add_Click({
    for ($i = 0; $i -lt $SLOT_COUNT; $i++) { Set-SlotText $i '' }
    foreach ($n in $notes) { $n.Text = '' }
    Set-Status "Cleared. Press Save to write that to disk."
})

$showButton.add_Click({ Set-Revealed ([bool]$showButton.IsChecked) })

$window.add_SourceInitialized({
    $script:OwnHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle

    $failed = @()
    for ($i = 1; $i -le $SLOT_COUNT; $i++) {
        $vk = $VK_F1 + ($i - 1)
        if (-not $script:Listener.Register($i, ($MOD_CONTROL -bor $MOD_SHIFT), $vk)) {
            $failed += "F$i"
        }
    }

    if ($failed.Count -gt 0) {
        Set-Status "Registered, except $($failed -join ', ') - another app owns those."
    }
    else {
        Set-Status "Listening on Ctrl+Shift+F1 through F$SLOT_COUNT."
    }
})

$window.add_Closing({
    Save-Snippets
    for ($i = 1; $i -le $SLOT_COUNT; $i++) { $script:Listener.Unregister($i) }
    $script:Listener.Dispose()
})

Load-Snippets
$window.ShowDialog() | Out-Null
