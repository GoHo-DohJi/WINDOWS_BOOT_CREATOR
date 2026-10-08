# ============================================================
# Windows Boot Drive Creator
# ------------------------------------------------------------
# A PowerShell WPF utility that creates a bootable Windows
# installation drive from an ISO image on any external partition.
#
# Features:
#   - Validates that the chosen ISO is a real Windows installer
#   - Lists only external (non-system) partitions
#   - Optional quick NTFS format (4096-byte clusters) that
#     preserves the original volume label
#   - Robocopy-based copy with Copy-Item fallback
#   - Detects disconnected source/target during copy
#   - Dark title bar, modern dark UI, no PS console window
# ============================================================

# ── Self-elevate ────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process -FilePath "powershell" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ── Hide console window ─────────────────────────────────────
Add-Type -Name Win32 -Namespace Native -MemberDefinition @"
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
"@
$consoleWindow = [Native.Win32]::GetConsoleWindow()
[Native.Win32]::ShowWindow($consoleWindow, 0) | Out-Null

# ── Load WPF ────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ── DWM API for dark title bar ──────────────────────────────
Add-Type -Name DwmHelper -Namespace Dwm -MemberDefinition @"
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
"@

# ── Win32 API for removing window icon ──────────────────────
Add-Type -Name IconHelper -Namespace WindowStyle -MemberDefinition @"
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hwnd, int index, int newStyle);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr hwndInsertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);
"@

# ── XAML UI definition ──────────────────────────────────────
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Windows Boot Drive Creator"
    Width="680" Height="480"
    WindowStartupLocation="CenterScreen"
    ResizeMode="NoResize"
    Background="#1e1e2e"
    FontFamily="Segoe UI"
    SnapsToDevicePixels="True"
    UseLayoutRounding="True"
    TextOptions.TextFormattingMode="Display"
    TextOptions.TextRenderingMode="ClearType"
    RenderOptions.ClearTypeHint="Enabled">

    <Window.Resources>
        <!-- Catppuccin Mocha palette -->
        <SolidColorBrush x:Key="AccentBrush" Color="#89b4fa"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#b4d0fb"/>
        <SolidColorBrush x:Key="SurfaceBrush" Color="#313244"/>
        <SolidColorBrush x:Key="TextBrush" Color="#cdd6f4"/>
        <SolidColorBrush x:Key="SubtextBrush" Color="#a6adc8"/>

        <!-- Primary button -->
        <Style x:Key="ModernButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="#1e1e2e"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}"
                                SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              TextOptions.TextFormattingMode="Display"
                                              TextOptions.TextRenderingMode="ClearType"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="{StaticResource AccentHoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.4"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Refresh icon button -->
        <Style x:Key="RefreshIconButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Width" Value="32"/>
            <Setter Property="Height" Value="32"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                CornerRadius="6" SnapsToDevicePixels="True">
                            <Path x:Name="icon"
                                  Width="14" Height="14"
                                  Stretch="Uniform"
                                  Fill="#a6adc8"
                                  Data="M17.65,6.35 C16.2,4.9 14.21,4 12,4 C7.58,4 4,7.58 4,12 C4,16.42 7.58,20 12,20 C15.73,20 18.84,17.45 19.73,14 L17.65,14 C16.83,16.33 14.61,18 12,18 C8.69,18 6,15.31 6,12 C6,8.69 8.69,6 12,6 C13.66,6 15.14,6.69 16.22,7.78 L13,11 L20,11 L20,4 L17.65,6.35 Z"
                                  HorizontalAlignment="Center"
                                  VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#45475a"/>
                                <Setter TargetName="icon" Property="Fill" Value="#cdd6f4"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#585b70"/>
                                <Setter TargetName="icon" Property="Fill" Value="#89b4fa"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Opacity" Value="0.35"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Thin scrollbar templates -->
        <ControlTemplate x:Key="VerticalScrollBarTemplate" TargetType="ScrollBar">
            <Grid Background="Transparent" SnapsToDevicePixels="True">
                <Track x:Name="PART_Track" IsDirectionReversed="True">
                    <Track.DecreaseRepeatButton>
                        <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                        <Thumb>
                            <Thumb.Template>
                                <ControlTemplate TargetType="Thumb">
                                    <Border Background="#6c7086" CornerRadius="4" Margin="1,2"/>
                                </ControlTemplate>
                            </Thumb.Template>
                        </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                        <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                    </Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate>

        <ControlTemplate x:Key="HorizontalScrollBarTemplate" TargetType="ScrollBar">
            <Grid Background="Transparent" SnapsToDevicePixels="True">
                <Track x:Name="PART_Track">
                    <Track.DecreaseRepeatButton>
                        <RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                        <Thumb>
                            <Thumb.Template>
                                <ControlTemplate TargetType="Thumb">
                                    <Border Background="#6c7086" CornerRadius="4" Margin="2,1"/>
                                </ControlTemplate>
                            </Thumb.Template>
                        </Thumb>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                        <RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False" IsTabStop="False"/>
                    </Track.IncreaseRepeatButton>
                </Track>
            </Grid>
        </ControlTemplate>

        <Style x:Key="ThinScrollBar" TargetType="ScrollBar">
            <Setter Property="SnapsToDevicePixels" Value="True"/>
            <Setter Property="OverridesDefaultStyle" Value="True"/>
            <Setter Property="Background" Value="Transparent"/>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Vertical">
                    <Setter Property="Width" Value="8"/>
                    <Setter Property="MinWidth" Value="8"/>
                    <Setter Property="Template" Value="{StaticResource VerticalScrollBarTemplate}"/>
                </Trigger>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Height" Value="8"/>
                    <Setter Property="MinHeight" Value="8"/>
                    <Setter Property="Template" Value="{StaticResource HorizontalScrollBarTemplate}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <TextBlock Grid.Row="0" FontSize="22" FontWeight="Bold"
                   Foreground="{StaticResource AccentBrush}"
                   HorizontalAlignment="Center" Margin="0,0,0,20"
                   Text="Windows Boot Drive Creator"/>

        <!-- ISO card -->
        <Border Grid.Row="1" Background="{StaticResource SurfaceBrush}"
                CornerRadius="8" Padding="16" Margin="0,0,0,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock Text="Windows ISO Image" FontSize="14" FontWeight="SemiBold"
                               Foreground="{StaticResource TextBrush}"/>
                    <TextBlock x:Name="TxtIsoPath" Text="No image selected"
                               FontSize="12" Foreground="{StaticResource SubtextBrush}"
                               TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
                    <TextBlock x:Name="TxtIsoSize" Text=""
                               FontSize="12" Foreground="{StaticResource SubtextBrush}"
                               Margin="0,2,0,0"/>
                </StackPanel>
                <Button x:Name="BtnSelectIso" Grid.Column="1"
                        Content="Browse..." Style="{StaticResource ModernButton}"
                        VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Drive card -->
        <Border Grid.Row="2" Background="{StaticResource SurfaceBrush}"
                CornerRadius="8" Padding="16" Margin="0,0,0,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                    <TextBlock Text="BOOT Partition" FontSize="14" FontWeight="SemiBold"
                               Foreground="{StaticResource TextBrush}"/>
                    <TextBlock x:Name="TxtDriveInfo"
                               Text="Select the partition for Windows Setup files"
                               FontSize="12" Foreground="{StaticResource SubtextBrush}"
                               TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
                </StackPanel>
                <Button x:Name="BtnRefreshDrives" Grid.Column="1"
                        Style="{StaticResource RefreshIconButton}"
                        Visibility="Collapsed"
                        Margin="0,0,8,0" VerticalAlignment="Center"/>
                <Button x:Name="BtnSelectDrive" Grid.Column="2"
                        Content="Select Drive" Style="{StaticResource ModernButton}"
                        VerticalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Floating dropdown overlay -->
        <Border x:Name="DropdownBorder" Grid.Row="3"
                Background="#45475a" CornerRadius="8"
                Padding="4" Panel.ZIndex="100"
                VerticalAlignment="Top" MaxHeight="168"
                Visibility="Collapsed"
                BorderBrush="#6c7086" BorderThickness="1"
                SnapsToDevicePixels="True" UseLayoutRounding="True">
            <ListBox x:Name="LstDrives"
                     MaxHeight="156"
                     Background="#45475a"
                     Foreground="{StaticResource TextBrush}"
                     BorderThickness="0"
                     FontFamily="Segoe UI"
                     FontSize="13"
                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"
                     ScrollViewer.CanContentScroll="False"
                     VirtualizingPanel.IsVirtualizing="False"
                     RenderOptions.ClearTypeHint="Enabled">
                <ListBox.Resources>
                    <Style TargetType="ScrollBar" BasedOn="{StaticResource ThinScrollBar}"/>
                </ListBox.Resources>
                <ListBox.ItemContainerStyle>
                    <Style TargetType="ListBoxItem">
                        <Setter Property="Padding" Value="10,7"/>
                        <Setter Property="Margin" Value="2,1"/>
                        <Setter Property="Cursor" Value="Hand"/>
                        <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
                        <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
                        <Setter Property="Template">
                            <Setter.Value>
                                <ControlTemplate TargetType="ListBoxItem">
                                    <Border x:Name="Bd" Background="Transparent"
                                            CornerRadius="5" Padding="{TemplateBinding Padding}"
                                            SnapsToDevicePixels="True" UseLayoutRounding="True">
                                        <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="Bd" Property="Background" Value="#585b70"/>
                                        </Trigger>
                                        <Trigger Property="IsSelected" Value="True">
                                            <Setter TargetName="Bd" Property="Background" Value="#89b4fa"/>
                                            <Setter Property="Foreground" Value="#1e1e2e"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Setter.Value>
                        </Setter>
                    </Style>
                </ListBox.ItemContainerStyle>
                <ListBox.ItemTemplate>
                    <DataTemplate>
                        <TextBlock Text="{Binding}" TextTrimming="CharacterEllipsis"
                                   FontFamily="Segoe UI" FontSize="13"
                                   TextOptions.TextFormattingMode="Display"
                                   TextOptions.TextRenderingMode="ClearType"
                                   RenderOptions.ClearTypeHint="Enabled"/>
                    </DataTemplate>
                </ListBox.ItemTemplate>
            </ListBox>
        </Border>

        <!-- Log area -->
        <Border Grid.Row="3" Background="#11111b"
                CornerRadius="8" Padding="8" Margin="0,0,0,12">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="Log" FontSize="11" FontWeight="SemiBold"
                           Foreground="{StaticResource SubtextBrush}" Margin="4,0,0,4"/>
                <ScrollViewer Grid.Row="1" x:Name="LogScroller" VerticalScrollBarVisibility="Auto">
                    <ScrollViewer.Resources>
                        <Style TargetType="ScrollBar" BasedOn="{StaticResource ThinScrollBar}"/>
                    </ScrollViewer.Resources>
                    <TextBlock x:Name="TxtLog" FontSize="12" FontFamily="Consolas"
                               Foreground="{StaticResource TextBrush}" TextWrapping="Wrap"
                               TextOptions.TextFormattingMode="Display"
                               TextOptions.TextRenderingMode="ClearType"
                               RenderOptions.ClearTypeHint="Enabled"/>
                </ScrollViewer>
                <ProgressBar x:Name="ProgressBar" Grid.Row="2"
                             Height="6" Margin="0,8,0,0"
                             Minimum="0" Maximum="100" Value="0"
                             Background="#1e1e2e" Foreground="#89b4fa"
                             BorderThickness="0" Visibility="Collapsed"/>
            </Grid>
        </Border>

        <!-- Bottom bar -->
        <Grid Grid.Row="4">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="TxtStatus" Grid.Column="0"
                       Text="" FontSize="13" FontWeight="SemiBold"
                       Foreground="{StaticResource SubtextBrush}"
                       VerticalAlignment="Center"
                       TextTrimming="CharacterEllipsis"
                       Margin="0,0,12,0"/>
            <Button x:Name="BtnStart" Grid.Column="1"
                    Content="Create Boot Drive"
                    Style="{StaticResource ModernButton}"
                    IsEnabled="False" Width="180"/>
        </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# ── Window-level tweaks: dark title bar + remove window icon ─
$window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $hwnd = $helper.Handle

        # Immersive dark title bar
        $useDark = 1
        [Dwm.DwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$useDark, 4) | Out-Null

        # Strip PowerShell icon + system menu
        $GWL_EXSTYLE         = -20
        $WS_EX_DLGMODALFRAME = 0x00000001
        $SWP_FRAMECHANGED    = 0x0020
        $SWP_NOMOVE          = 0x0002
        $SWP_NOSIZE          = 0x0001
        $SWP_NOZORDER        = 0x0004
        $WM_SETICON          = 0x0080

        $style = [WindowStyle.IconHelper]::GetWindowLong($hwnd, $GWL_EXSTYLE)
        [WindowStyle.IconHelper]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($style -bor $WS_EX_DLGMODALFRAME)) | Out-Null
        [WindowStyle.IconHelper]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_FRAMECHANGED)) | Out-Null
        [WindowStyle.IconHelper]::SendMessage($hwnd, $WM_SETICON, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        [WindowStyle.IconHelper]::SendMessage($hwnd, $WM_SETICON, [IntPtr]1,     [IntPtr]::Zero) | Out-Null
    } catch {}
})

# ── Grab controls ───────────────────────────────────────────
$BtnSelectIso     = $window.FindName("BtnSelectIso")
$BtnRefreshDrives = $window.FindName("BtnRefreshDrives")
$BtnSelectDrive   = $window.FindName("BtnSelectDrive")
$BtnStart         = $window.FindName("BtnStart")
$TxtIsoPath       = $window.FindName("TxtIsoPath")
$TxtIsoSize       = $window.FindName("TxtIsoSize")
$TxtDriveInfo     = $window.FindName("TxtDriveInfo")
$TxtLog           = $window.FindName("TxtLog")
$TxtStatus        = $window.FindName("TxtStatus")
$LstDrives        = $window.FindName("LstDrives")
$DropdownBorder   = $window.FindName("DropdownBorder")
$LogScroller      = $window.FindName("LogScroller")
$ProgressBar      = $window.FindName("ProgressBar")

# ── State ───────────────────────────────────────────────────
$script:IsoPath           = $null
$script:IsoSizeB          = 0
$script:SelectedDrive     = $null
$script:IsRunning         = $false
$script:SuppressSelection = $false
$script:DriveScanRunning  = $false
$script:ScanTimer         = $null

$brushConverter = [System.Windows.Media.BrushConverter]::new()
function Convert-Brush([string]$Color) { return $brushConverter.ConvertFromString($Color) }

# Cross-thread UI bridge
$script:sync = [hashtable]::Synchronized(@{
    Window      = $window
    TxtLog      = $TxtLog
    TxtStatus   = $TxtStatus
    LogScroller = $LogScroller
    ProgressBar = $ProgressBar
})

# ── UI helpers ──────────────────────────────────────────────
function Write-Log {
    param([string]$Message)
    $entry = "[{0}] {1}`n" -f (Get-Date -Format "HH:mm:ss"), $Message
    $TxtLog.Dispatcher.Invoke([Action]{
        $TxtLog.Text += $entry
        $LogScroller.ScrollToEnd()
    })
}

function Set-Status {
    param([string]$Text, [string]$Color = "#a6adc8")
    $TxtStatus.Dispatcher.Invoke([Action]{
        $TxtStatus.Text = $Text
        $TxtStatus.Foreground = $brushConverter.ConvertFromString($Color)
    })
}

function Update-StartButton {
    $ready = ($null -ne $script:IsoPath) -and ($null -ne $script:SelectedDrive)
    $BtnStart.IsEnabled = $ready -and (-not $script:IsRunning)
}

function Close-Dropdown {
    if ($DropdownBorder.Visibility -eq 'Visible') {
        $DropdownBorder.Visibility = 'Collapsed'
        $BtnRefreshDrives.Visibility = 'Collapsed'
        $BtnSelectDrive.Content = if ($script:SelectedDrive) { "Change Drive" } else { "Select Drive" }
    }
}

function Open-Dropdown {
    $DropdownBorder.Visibility = 'Visible'
    $BtnRefreshDrives.Visibility = 'Visible'
    $BtnSelectDrive.Content = "Hide List"
}

function Update-DriveListItems {
    param($lines)
    $script:SuppressSelection = $true
    $LstDrives.Items.Clear()
    $clean = @($lines | Where-Object { $_ -and $_.ToString().Trim().Length -gt 0 })
    if ($clean.Count -eq 0) {
        [void]$LstDrives.Items.Add("  No external partitions found.")
    } else {
        foreach ($line in $clean) { [void]$LstDrives.Items.Add([string]$line) }
    }

    if ($script:SelectedDrive) {
        $matched = $null
        foreach ($item in @($LstDrives.Items)) {
            if ($item.ToString().Trim().StartsWith($script:SelectedDrive)) { $matched = $item; break }
        }
        if ($matched) {
            $LstDrives.SelectedItem = $matched
            $TxtDriveInfo.Text = "Selected: $($matched.ToString().Trim())"
            $TxtDriveInfo.Foreground = Convert-Brush "#a6e3a1"
        } else {
            $script:SelectedDrive = $null
            $TxtDriveInfo.Text = "Select the partition for Windows Setup files"
            $TxtDriveInfo.Foreground = Convert-Brush "#a6adc8"
            $BtnSelectDrive.Content = "Select Drive"
            Update-StartButton
        }
    }
    $script:SuppressSelection = $false
}

function Request-DriveList {
    param([switch]$ShowDropdown)
    if ($script:DriveScanRunning) { return }
    $script:DriveScanRunning = $true

    $isVisible = ($DropdownBorder.Visibility -eq 'Visible')
    if ($ShowDropdown -or $isVisible) {
        Open-Dropdown
        $script:SuppressSelection = $true
        $LstDrives.Items.Clear()
        [void]$LstDrives.Items.Add("  Scanning drives...")
        $script:SuppressSelection = $false
    }

    $BtnRefreshDrives.IsEnabled = $false
    $scanPs = [powershell]::Create()
    [void]$scanPs.AddScript({
        $lines = New-Object System.Collections.Generic.List[string]
        try {
            $systemDisks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.IsSystem } | Select-Object -ExpandProperty Number)
            $disks = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { $systemDisks -notcontains $_.Number })
            foreach ($disk in $disks) {
                $parts = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                    Where-Object { $_.DriveLetter -and ($_.DriveLetter -ne "`0") })
                foreach ($part in $parts) {
                    $vol = Get-Volume -DriveLetter $part.DriveLetter -ErrorAction SilentlyContinue
                    if ($null -eq $vol) { continue }
                    $label  = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { "(No Label)" }
                    $sizeGB = [math]::Round($vol.Size / 1GB, 2)
                    $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 2)
                    $model  = if ($disk.FriendlyName) { $disk.FriendlyName } else { "Disk $($disk.Number)" }
                    [void]$lines.Add(("{0}  [{1}]  {2}  {3:N1} GB free of {4:N1} GB  ({5})" -f "$($part.DriveLetter):", $label, $vol.FileSystem, $freeGB, $sizeGB, $model))
                }
            }
        } catch { [void]$lines.Add("  Error reading drives.") }
        if ($lines.Count -eq 0) { [void]$lines.Add("  No external partitions found.") }
        Write-Output -NoEnumerate $lines.ToArray()
    })
    $handle = $scanPs.BeginInvoke()

    if ($script:ScanTimer) { $script:ScanTimer.Stop() }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Tag = @{ Handle = $handle; PS = $scanPs; KeepOpen = ($ShowDropdown -or $isVisible) }
    $script:ScanTimer = $timer
    $timer.Add_Tick({
        $state = $this.Tag
        if (-not $state.Handle.IsCompleted) { return }
        $this.Stop()
        try {
            $out = @($state.PS.EndInvoke($state.Handle))
            $lines = @()
            if ($out.Count -eq 1 -and $out[0] -is [System.Array]) { $lines = @($out[0]) } else { $lines = @($out) }
            Update-DriveListItems $lines
            if ($state.KeepOpen) { Open-Dropdown }
        } catch {
            Write-Log "ERROR scanning drives: $_"
            Update-DriveListItems @("  Error reading drives.")
        } finally {
            try { $state.PS.Dispose() } catch {}
            $script:DriveScanRunning = $false
            if (-not $script:IsRunning) { $BtnRefreshDrives.IsEnabled = $true }
        }
    })
    $timer.Start()
}

# ── Global events ───────────────────────────────────────────

# Close dropdown when clicking outside
$window.Add_PreviewMouseDown({
    param($sender, $e)
    if ($DropdownBorder.Visibility -ne 'Visible') { return }
    $current = $e.OriginalSource
    $keepOpen = $false
    while ($null -ne $current) {
        if ($current -eq $DropdownBorder -or $current -eq $BtnSelectDrive -or $current -eq $BtnRefreshDrives) {
            $keepOpen = $true; break
        }
        try { $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current) } catch { break }
    }
    if (-not $keepOpen) { Close-Dropdown }
})

$window.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape') { Close-Dropdown }
})

# ── ISO selection (with validation) ─────────────────────────
$BtnSelectIso.Add_Click({
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = "Select Windows ISO Image"
    $dialog.Filter = "ISO Image (*.iso)|*.iso"
    $dialog.InitialDirectory = [Environment]::GetFolderPath("UserProfile") + "\Downloads"
    if (-not $dialog.ShowDialog()) { return }

    $tempIso = $dialog.FileName
    Write-Log "Verifying ISO image..."
    Set-Status "Verifying ISO..." "#f9e2af"
    $BtnSelectIso.IsEnabled = $false
    $BtnStart.IsEnabled = $false

    $verifyTask = {
        param([string]$path)
        $valid = $false
        try {
            $mountResult = Mount-DiskImage -ImagePath $path -PassThru -ErrorAction Stop
            Start-Sleep -Milliseconds 1500
            $dl = ($mountResult | Get-Volume).DriveLetter
            if ($dl) {
                $root = "${dl}:\"
                $hasBoot    = Test-Path (Join-Path $root "sources\boot.wim")
                $hasInstall = (Test-Path (Join-Path $root "sources\install.wim")) -or
                              (Test-Path (Join-Path $root "sources\install.esd")) -or
                              (Test-Path (Join-Path $root "sources\install.swm"))
                if ($hasBoot -and $hasInstall) { $valid = $true }
            }
            Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null
        } catch {
            try { Dismount-DiskImage -ImagePath $path -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
        return $valid
    }

    $isWindowsIso = &$verifyTask $tempIso
    $BtnSelectIso.IsEnabled = $true

    if ($isWindowsIso) {
        $script:IsoPath  = $tempIso
        $fileInfo        = Get-Item -LiteralPath $script:IsoPath
        $script:IsoSizeB = $fileInfo.Length
        $sizeGB          = [math]::Round($script:IsoSizeB / 1GB, 2)
        $TxtIsoPath.Text = $script:IsoPath
        $TxtIsoPath.Foreground = Convert-Brush "#a6e3a1"
        $TxtIsoSize.Text = "Size: $sizeGB GB"
        $TxtIsoSize.Foreground = Convert-Brush "#a6e3a1"
        Write-Log "ISO verified: $($script:IsoPath) ($sizeGB GB)"
        Set-Status ""
        Update-StartButton
    } else {
        [System.Windows.MessageBox]::Show(
            "The selected file is not a valid Windows ISO image.`n`nRequired: sources\boot.wim and an install image.",
            "Invalid ISO", "OK", "Error") | Out-Null
        $script:IsoPath = $null; $script:IsoSizeB = 0
        $TxtIsoPath.Text = "No image selected"
        $TxtIsoPath.Foreground = Convert-Brush "#a6adc8"
        $TxtIsoSize.Text = ""
        Write-Log "ERROR: Not a valid Windows ISO."
        Set-Status ""
        Update-StartButton
    }
})

# Select Drive: toggle dropdown, always refresh when opening
$BtnSelectDrive.Add_Click({
    if ($DropdownBorder.Visibility -eq 'Collapsed') {
        Request-DriveList -ShowDropdown
    } else {
        Close-Dropdown
    }
})

# Refresh: only ever visible while dropdown is open
$BtnRefreshDrives.Add_Click({
    Request-DriveList
})

$LstDrives.Add_SelectionChanged({
    if ($script:SuppressSelection) { return }
    $selected = $LstDrives.SelectedItem
    if ($null -eq $selected) { return }
    $text = $selected.ToString()
    if ($text -like "*No external*" -or $text -like "*Scanning*" -or $text -like "*Error*") { return }

    $driveLetter = $text.Trim().Substring(0, 2)
    $script:SelectedDrive = $driveLetter
    $TxtDriveInfo.Text = "Selected: $($text.Trim())"
    $TxtDriveInfo.Foreground = Convert-Brush "#a6e3a1"
    Close-Dropdown
    Write-Log "BOOT partition selected: $driveLetter"
    Update-StartButton
})

# Initial silent scan so a selection can be restored later
Request-DriveList

# ── Main action: create boot drive ──────────────────────────
$BtnStart.Add_Click({
    if ($script:IsRunning) { return }
    Close-Dropdown

    # ISO still accessible?
    if (-not (Test-Path -LiteralPath $script:IsoPath)) {
        [System.Windows.MessageBox]::Show(
            "ISO file is no longer accessible:`n$($script:IsoPath)",
            "ISO Not Found", "OK", "Error") | Out-Null
        $script:IsoPath = $null; $script:IsoSizeB = 0
        $TxtIsoPath.Text = "No image selected"
        $TxtIsoPath.Foreground = Convert-Brush "#a6adc8"
        $TxtIsoSize.Text = ""
        Update-StartButton
        return
    }

    # Prevent copying to the same drive the ISO lives on
    $isoOn = [System.IO.Path]::GetPathRoot($script:IsoPath)
    if ($isoOn -and ($isoOn.TrimEnd('\') -eq $script:SelectedDrive.TrimEnd('\'))) {
        [System.Windows.MessageBox]::Show(
            "The ISO file is stored on the target partition.`nMove the ISO to another disk first.",
            "ISO On Target Drive", "OK", "Warning") | Out-Null
        return
    }

    # Target still available?
    $targetVol = Get-Volume -DriveLetter $script:SelectedDrive[0] -ErrorAction SilentlyContinue
    if ($null -eq $targetVol) {
        [System.Windows.MessageBox]::Show(
            "Target partition $($script:SelectedDrive) is no longer available.",
            "Drive Not Found", "OK", "Error") | Out-Null
        $script:SelectedDrive = $null
        $TxtDriveInfo.Text = "Select the partition for Windows Setup files"
        $TxtDriveInfo.Foreground = Convert-Brush "#a6adc8"
        $BtnSelectDrive.Content = "Select Drive"
        Update-StartButton
        return
    }

    $freeSpaceBytes = [int64]$targetVol.SizeRemaining
    $totalSizeBytes = [int64]$targetVol.Size
    $isoSizeGB      = [math]::Round($script:IsoSizeB / 1GB, 2)
    $freeGB         = [math]::Round($freeSpaceBytes  / 1GB, 2)
    $totalGB        = [math]::Round($totalSizeBytes  / 1GB, 2)
    $formatPartition = $false

    if ($freeSpaceBytes -lt $script:IsoSizeB) {
        if ($totalSizeBytes -lt $script:IsoSizeB) {
            [System.Windows.MessageBox]::Show(
                "Partition too small.`nRequired: $isoSizeGB GB`nPartition: $totalGB GB",
                "Too Small", "OK", "Error") | Out-Null
            return
        }
        $choice = [System.Windows.MessageBox]::Show(
            "Not enough space on $($script:SelectedDrive)`nRequired: $isoSizeGB GB | Available: $freeGB GB`n`n" +
            "Quick format to NTFS (4096-byte clusters)?`nALL files will be erased!",
            "Not Enough Space", "YesNo", "Warning")
        if ($choice -ne 'Yes') { return }
        $formatPartition = $true
    } else {
        $choice = [System.Windows.MessageBox]::Show(
            "Create boot drive on $($script:SelectedDrive)?`n`n" +
            "Format to NTFS (4096-byte clusters) first? (Recommended)`n`n" +
            "Yes = format + copy | No = copy only | Cancel = abort",
            "Format?", "YesNoCancel", "Question")
        if ($choice -eq 'Cancel') { return }
        if ($choice -eq 'Yes') { $formatPartition = $true }
    }

    # Lock UI
    $script:IsRunning = $true
    $BtnStart.IsEnabled = $false
    $BtnStart.Content = "Working..."
    $BtnSelectIso.IsEnabled = $false
    $BtnSelectDrive.IsEnabled = $false
    $BtnRefreshDrives.IsEnabled = $false
    $LstDrives.IsEnabled = $false
    $ProgressBar.Visibility = 'Visible'
    $ProgressBar.IsIndeterminate = $true
    $ProgressBar.Value = 0
    Set-Status "Starting..." "#f9e2af"

    $isoFile   = $script:IsoPath
    $bootDrive = $script:SelectedDrive

    # Background runspace for the heavy lifting
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",            $script:sync)
    $runspace.SessionStateProxy.SetVariable("isoFile",         $isoFile)
    $runspace.SessionStateProxy.SetVariable("bootDrive",       $bootDrive)
    $runspace.SessionStateProxy.SetVariable("formatPartition", $formatPartition)

    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        function UI-Log([string]$Message) {
            $entry = "[{0}] {1}`n" -f (Get-Date -Format "HH:mm:ss"), $Message
            $sync.TxtLog.Dispatcher.Invoke([Action]{
                $sync.TxtLog.Text += $entry
                $sync.LogScroller.ScrollToEnd()
            })
        }
        function UI-Status([string]$Text, [string]$Color = "#a6adc8") {
            $sync.TxtStatus.Dispatcher.Invoke([Action]{
                $sync.TxtStatus.Text = $Text
                $sync.TxtStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
            })
        }
        function UI-Progress([int]$Value) {
            $sync.ProgressBar.Dispatcher.Invoke([Action]{
                $sync.ProgressBar.IsIndeterminate = $false
                $sync.ProgressBar.Value = $Value
            })
        }
        function UI-Busy([bool]$On) {
            $sync.ProgressBar.Dispatcher.Invoke([Action]{
                $sync.ProgressBar.Visibility = 'Visible'
                $sync.ProgressBar.IsIndeterminate = $On
            })
        }

        $success = $false
        $isoRoot = $null
        try {
            UI-Log "=== Starting Boot Drive Creation ==="
            UI-Log "ISO: $isoFile"
            UI-Log "Target: $bootDrive"

            if (-not (Test-Path -LiteralPath $isoFile)) { throw "ISO file no longer accessible." }
            $letterOnly = $bootDrive.Replace(":", "").Trim()
            if (-not (Get-Volume -DriveLetter $letterOnly -ErrorAction SilentlyContinue)) { throw "Target partition not available." }

            # Format with preserved label
            if ($formatPartition) {
                UI-Status "Formatting partition..." "#f9e2af"
                UI-Busy $true
                $savedLabel = $null
                try { $savedLabel = (Get-Volume -DriveLetter $letterOnly).FileSystemLabel } catch {}
                if ($savedLabel) { $savedLabel = $savedLabel.Trim() }
                if ($savedLabel -and $savedLabel.Length -gt 32) { $savedLabel = $savedLabel.Substring(0, 32) }
                if ($savedLabel) { UI-Log "Saving volume label: $savedLabel" }

                UI-Log "Formatting ${letterOnly}: to NTFS (4096-byte clusters)..."
                $fmt = @{
                    DriveLetter        = $letterOnly
                    FileSystem         = "NTFS"
                    AllocationUnitSize = 4096
                    Confirm            = $false
                    Force              = $true
                    ErrorAction        = "Stop"
                }
                if ($savedLabel) { $fmt.NewFileSystemLabel = $savedLabel }
                Format-Volume @fmt | Out-Null
                Start-Sleep -Milliseconds 700

                if (-not (Get-Volume -DriveLetter $letterOnly -ErrorAction SilentlyContinue)) {
                    throw "Partition disappeared after formatting."
                }
                if ($savedLabel) {
                    try {
                        Set-Volume -DriveLetter $letterOnly -NewFileSystemLabel $savedLabel -ErrorAction Stop
                        UI-Log "Label restored: $savedLabel"
                    } catch { UI-Log "WARNING: Could not restore label: $_" }
                }
                UI-Log "Format completed."
                UI-Progress 5
            }

            # Mark of the Web
            UI-Status "Preparing..." "#f9e2af"
            UI-Progress 8
            try {
                Unblock-File -LiteralPath $isoFile -ErrorAction Stop
                UI-Log "Mark of the Web removed."
            } catch { UI-Log "WARNING: Could not remove MotW: $_" }

            # Mount
            UI-Status "Mounting ISO image..." "#f9e2af"
            UI-Progress 12
            UI-Log "Mounting ISO..."
            $mountResult = Mount-DiskImage -ImagePath $isoFile -PassThru -ErrorAction Stop
            Start-Sleep -Milliseconds 1500
            $driveLetter = ($mountResult | Get-Volume).DriveLetter
            if (-not $driveLetter) { throw "Could not determine mounted ISO drive letter." }
            $isoRoot = "${driveLetter}:\"
            UI-Log "ISO mounted at $isoRoot"

            # Copy
            UI-Status "Copying files (please wait, this may take up to 5 minutes)..." "#f9e2af"
            UI-Progress 15
            UI-Log "Copying all files from $isoRoot to $bootDrive\ ..."
            UI-Log "Large files like install.wim may take several minutes."
            UI-Log "Please wait patiently, the process is running."
            UI-Busy $true

            $copyOk = $false
            try {
                $robocopyArgs = @($isoRoot, "$bootDrive\", "/E", "/R:3", "/W:2", "/NP", "/NDL", "/NFL", "/NJH", "/NJS", "/MT:4")
                $robocopyProcess = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -WindowStyle Hidden -PassThru

                $copyStart = Get-Date
                $lastLog = $copyStart
                while (-not $robocopyProcess.HasExited) {
                    Start-Sleep -Milliseconds 2000
                    $elapsed = (Get-Date) - $copyStart
                    $elapsedText = "{0:mm\:ss}" -f $elapsed

                    if (((Get-Date) - $lastLog).TotalSeconds -ge 15) {
                        UI-Log "Still copying... ($elapsedText elapsed)"
                        UI-Status "Copying files... $elapsedText elapsed (please wait)" "#f9e2af"
                        $lastLog = Get-Date
                    }

                    if (-not (Test-Path "$bootDrive\")) {
                        try { $robocopyProcess.Kill() } catch {}
                        throw "Target drive disconnected during copy."
                    }
                    if (-not (Test-Path $isoRoot)) {
                        try { $robocopyProcess.Kill() } catch {}
                        throw "ISO source disappeared during copy."
                    }
                }

                $exitCode = $robocopyProcess.ExitCode
                if ($exitCode -ge 8) { throw "Robocopy failed with exit code $exitCode" }
                $totalElapsed = "{0:mm\:ss}" -f ((Get-Date) - $copyStart)
                UI-Log "Copy completed in $totalElapsed. (robocopy exit: $exitCode)"
                UI-Busy $false
                UI-Progress 90
                $copyOk = $true
            } catch {
                UI-Busy $false
                if ($_.ToString() -match "disconnected|disappeared") { throw }
                UI-Log "ERROR with robocopy: $_"
                UI-Log "Falling back to Copy-Item..."
                UI-Busy $true
                try {
                    Copy-Item -Path "$isoRoot*" -Destination "$bootDrive\" -Recurse -Force -ErrorAction Stop
                    UI-Log "Copy completed via Copy-Item."
                    UI-Busy $false
                    UI-Progress 90
                    $copyOk = $true
                } catch {
                    UI-Busy $false
                    if ($_.ToString() -match "disconnected|disappeared") { throw }
                    UI-Log "ERROR: Copy failed: $_"
                    UI-Status "File copy failed." "#f38ba8"
                }
            }

            # Dismount
            UI-Status "Dismounting ISO..." "#f9e2af"
            UI-Progress 96
            try {
                Dismount-DiskImage -ImagePath $isoFile -ErrorAction Stop
                UI-Log "ISO dismounted."
            } catch { UI-Log "WARNING: Could not dismount: $_" }

            if ($copyOk) {
                UI-Progress 100
                UI-Status "Boot drive created successfully!" "#a6e3a1"
                UI-Log "=== Completed! ==="
                UI-Log "Boot from $bootDrive to install Windows."
                $success = $true
            }
        } catch {
            UI-Log "FATAL ERROR: $_"
            UI-Status "Failed." "#f38ba8"
            UI-Busy $false
            try { if ($isoFile) { Dismount-DiskImage -ImagePath $isoFile -ErrorAction SilentlyContinue } } catch {}
        }

        $sync.Window.Dispatcher.Invoke([Action]{
            if ($success) {
                [System.Windows.MessageBox]::Show(
                    "Boot drive created successfully!`n`nDrive: $bootDrive`n`nYou can now boot from this drive to install Windows.",
                    "Success", "OK", "Information") | Out-Null
            } else {
                [System.Windows.MessageBox]::Show(
                    "Boot drive creation failed.`nCheck the log for details.",
                    "Error", "OK", "Error") | Out-Null
            }
        })
    })

    # Watch the background job and unlock UI when it finishes
    $asyncHandle = $ps.BeginInvoke()
    $jobTimer = New-Object System.Windows.Threading.DispatcherTimer
    $jobTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $jobTimer.Tag = @{ Handle = $asyncHandle; PS = $ps; Runspace = $runspace }
    $jobTimer.Add_Tick({
        $state = $this.Tag
        if (-not $state.Handle.IsCompleted) { return }
        $this.Stop()
        try { $state.PS.EndInvoke($state.Handle) } catch {}
        $state.PS.Dispose()
        $state.Runspace.Close()
        $state.Runspace.Dispose()

        $script:IsRunning = $false
        $BtnStart.Content = "Create Boot Drive"
        $BtnSelectIso.IsEnabled    = $true
        $BtnSelectDrive.IsEnabled  = $true
        $BtnRefreshDrives.IsEnabled = $true
        $LstDrives.IsEnabled       = $true
        $ProgressBar.IsIndeterminate = $false
        Update-StartButton
        Request-DriveList
    })
    $jobTimer.Start()
})

# ── Run ─────────────────────────────────────────────────────
$window.ShowDialog() | Out-Null
