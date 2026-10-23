#Requires -Version 5.1
<#
    FocusAlarm.ps1  (集中アラーム)
    Windows「クロック」のフォーカスセッションと同じ設定で、終了をアラームのように知らせるタイマー。
    Windows PowerShell 5.1 + WPF だけで動作（インストール・署名不要）。
    設定: %APPDATA%\FocusAlarm\settings.json / ログ: %APPDATA%\FocusAlarm\error.log
    ※ UTF-8 (BOM 付き) で保存すること。
#>
param()
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# WPF は STA が必要
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $psExe -ArgumentList ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
    return
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml

$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, 'Local\FocusAlarm2_SingleInstance', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.MessageBox]::Show('集中アラームはすでに起動しています。', '集中アラーム') | Out-Null
    return
}

# ---------------------------------------------------------------- パス・ログ
$AppDir       = Join-Path $env:APPDATA 'FocusAlarm'
$SettingsPath = Join-Path $AppDir 'settings2.json'
$LogPath      = Join-Path $AppDir 'error.log'
if (-not (Test-Path -LiteralPath $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- 設定
$MediaDir = Join-Path $env:SystemRoot 'Media'
$Default = @{
    TotalMinutes = 120; Breaks = $true; BreakMinutes = 5; AutoStart = $false
    Sound = 'Alarm01'; Volume = 70; SnoozeMinutes = 5; UseToast = $true
}
function Load-Settings {
    $s = @{}
    foreach ($k in $Default.Keys) { $s[$k] = $Default[$k] }
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $j = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { if ($s.ContainsKey($p.Name)) { $s[$p.Name] = $p.Value } }
        } catch { Write-AppLog ('設定の読み込みに失敗: {0}' -f $_) }
    }
    return $s
}
function Save-Settings {
    try {
        $o = New-Object PSObject
        foreach ($k in ($S.Settings.Keys | Sort-Object)) { $o | Add-Member -MemberType NoteProperty -Name $k -Value $S.Settings[$k] }
        $o | ConvertTo-Json | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
    } catch { Write-AppLog ('設定の保存に失敗: {0}' -f $_) }
}

$S = @{
    Settings = (Load-Settings); State = 'Idle'; Phase = 'Work'; Cycle = 1
    EndTime = [datetime]::MinValue; Remaining = [timespan]::Zero; PhaseTotal = [timespan]::Zero
    Pending = $null; Media = $null; AlarmWin = $null; SnoozeTimer = $null; PreviewTimer = $null; LastAlarm = $null
}

# クロックの集中セッション方式: 設定した合計時間（休憩込み）を、1回あたり約21分の集中と休憩に自動で分割する
function Update-Plan {
    $T = [int]$S.Settings.TotalMinutes; $b = [int]$S.Settings.BreakMinutes
    $n = 1
    if ([bool]$S.Settings.Breaks -and $T -gt 30) {
        $n = [math]::Max(1, [int][math]::Round($T / (21.0 + $b), [MidpointRounding]::AwayFromZero))
    }
    $focusTotal = $T - ($n - 1) * $b
    $base = [int][math]::Floor($focusTotal / $n); $rem = $focusTotal - $base * $n
    $plan = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) { [void]$plan.Add([int]($base + $(if ($i -lt $rem) { 1 } else { 0 }))) }
    $S.Plan = @($plan)
}
function Get-PlanSummary {
    $parts = @()
    foreach ($g in ($S.Plan | Group-Object | Sort-Object { [int]$_.Name } -Descending)) { $parts += ('{0}分 × {1}回' -f $g.Name, $g.Count) }
    $t = $parts -join ' ＋ '
    if ($S.Plan.Count -gt 1) { $t += ('、休憩 {0}分 × {1}回' -f $S.Settings.BreakMinutes, ($S.Plan.Count - 1)) }
    return $t
}

# ---------------------------------------------------------------- トースト通知 (WinRT)
# 送信元には Windows PowerShell 標準の AppUserModelID を使う（登録作業なしで確実に出せる）
$ToastAumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$ToastAvailable = $false
try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $ToastAvailable = $true
} catch { Write-AppLog ('トースト API を読み込めません: {0}' -f $_) }

function Show-AlarmToast {
    param([string]$Title, [string]$Body)
    if (-not $ToastAvailable) { return }
    try {
        $t = [System.Security.SecurityElement]::Escape($Title)
        $b = [System.Security.SecurityElement]::Escape($Body)
        # 音はアラームウィンドウ側で選んだ音を鳴らすので、トーストは無音
        $xml = @"
<toast scenario="alarm" duration="long">
  <visual><binding template="ToastGeneric"><text>$t</text><text>$b</text><text placement="attribution">集中アラーム</text></binding></visual>
  <audio silent="true"/>
  <actions><action activationType="system" arguments="dismiss" content="閉じる"/></actions>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
        $toast.Tag = 'focusalarm'; $toast.Group = 'focusalarm'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAumid).Show($toast)
    } catch { Write-AppLog ('トースト表示に失敗: {0}' -f $_) }
}
function Remove-AlarmToast {
    if (-not $ToastAvailable) { return }
    try { [Windows.UI.Notifications.ToastNotificationManager]::History.Remove('focusalarm', 'focusalarm', $ToastAumid) } catch { }
}

# ---------------------------------------------------------------- アラーム音（音量つきループ）
function Stop-Sound {
    if ($null -ne $S.PreviewTimer) { try { $S.PreviewTimer.Stop() } catch { }; $S.PreviewTimer = $null }
    if ($null -ne $S.Media) {
        try { $S.Media.Stop(); $S.Media.Close() } catch { }
        $S.Media = $null
    }
}
function Start-Sound {
    param([int]$PreviewSeconds = 0)
    Stop-Sound
    try {
        $path = Join-Path $MediaDir ($S.Settings.Sound + '.wav')
        if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path $MediaDir 'Alarm01.wav' }
        $m = New-Object System.Windows.Media.MediaPlayer
        $m.Volume = [double]$S.Settings.Volume / 100.0
        $m.Add_MediaEnded({ try { $S.Media.Position = [timespan]::Zero; $S.Media.Play() } catch { } })
        $m.Add_MediaFailed({ param($s, $e) Write-AppLog ('音声を再生できません: {0}' -f $e.ErrorException.Message) })
        $m.Open([Uri]$path)
        $m.Play()
        $S.Media = $m
        if ($PreviewSeconds -gt 0) {
            $pt = New-Object System.Windows.Threading.DispatcherTimer
            $pt.Interval = [timespan]::FromSeconds($PreviewSeconds)
            $pt.Add_Tick({ Stop-Sound })
            $S.PreviewTimer = $pt
            $pt.Start()
        }
    } catch {
        Write-AppLog ('アラーム音の再生に失敗: {0}' -f $_)
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    }
}

# ---------------------------------------------------------------- XAML
$StylesXaml = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <SolidColorBrush x:Key="Bg" Color="#1E1D1B"/><SolidColorBrush x:Key="Surface" Color="#272623"/>
  <SolidColorBrush x:Key="Line" Color="#383631"/><SolidColorBrush x:Key="Fg" Color="#ECE9E2"/>
  <SolidColorBrush x:Key="Muted" Color="#9A968B"/><SolidColorBrush x:Key="Accent" Color="#E08A66"/>
  <SolidColorBrush x:Key="AccentSoft" Color="#3A2B24"/><SolidColorBrush x:Key="Track" Color="#34322E"/>
  <Style x:Key="Pill" TargetType="Button">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FontSize" Value="14"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border x:Name="B" CornerRadius="20" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="22,9">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Bg}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="PillPrimary" TargetType="Button" BasedOn="{StaticResource Pill}">
    <Setter Property="Foreground" Value="#1E1D1B"/><Setter Property="FontWeight" Value="Medium"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border x:Name="B" CornerRadius="20" Background="{StaticResource Accent}" Padding="34,9">
        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.9"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Step" TargetType="Button">
    <Setter Property="Cursor" Value="Hand"/><Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
      <Border x:Name="B" Width="30" Height="30" CornerRadius="15" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1">
        <TextBlock Text="{TemplateBinding Content}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="16" Margin="0,-2,0,0"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Switch" TargetType="ToggleButton">
    <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
      <Border x:Name="T" Width="42" Height="24" CornerRadius="12" Background="{StaticResource Track}">
        <Ellipse x:Name="K" Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True">
          <Setter TargetName="T" Property="Background" Value="{StaticResource Accent}"/>
          <Setter TargetName="K" Property="Margin" Value="21,0,0,0"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
      </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="Cursor" Value="Hand"/><Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
      <Border x:Name="B" CornerRadius="14" Padding="13,4" Background="Transparent">
        <TextBlock x:Name="L" Text="{TemplateBinding Content}" FontSize="13" Foreground="{StaticResource Muted}"/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True">
          <Setter TargetName="B" Property="Background" Value="{StaticResource Surface}"/>
          <Setter TargetName="L" Property="Foreground" Value="{StaticResource Fg}"/></Trigger>
      </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="DarkItem" TargetType="ComboBoxItem">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
      <Border x:Name="B" Background="Transparent" Padding="14,6"><ContentPresenter/></Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Track}"/></Trigger>
        <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource AccentSoft}"/></Trigger>
      </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="DarkCombo" TargetType="ComboBox">
    <Setter Property="Foreground" Value="{StaticResource Fg}"/><Setter Property="ItemContainerStyle" Value="{StaticResource DarkItem}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
      <Grid>
        <Border CornerRadius="16" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="14,5,30,5">
          <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" TextElement.Foreground="{StaticResource Fg}" VerticalAlignment="Center"/></Border>
        <TextBlock Text="&#xE70D;" FontFamily="Segoe MDL2 Assets, Segoe Fluent Icons" FontSize="10" Foreground="{StaticResource Muted}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0" IsHitTestVisible="False"/>
        <ToggleButton Opacity="0" Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
        <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Fade">
          <Border MinWidth="{TemplateBinding ActualWidth}" MaxHeight="260" Margin="0,4,0,8" CornerRadius="10" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1">
            <ScrollViewer><StackPanel IsItemsHost="True"/></ScrollViewer></Border></Popup>
      </Grid></ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="RowBorder" TargetType="Border">
    <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="BorderThickness" Value="0,0,0,1"/><Setter Property="MinHeight" Value="52"/>
  </Style>
</ResourceDictionary>
'@

[xml]$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="集中アラーム" Width="900" Height="770" MinHeight="560" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" FontFamily="Yu Gothic UI" FontSize="14" Background="#1E1D1B" Foreground="#ECE9E2">
  <Window.Resources>@@STYLES@@</Window.Resources>
  <Grid Margin="24">
    <Grid.ColumnDefinitions><ColumnDefinition Width="1.1*"/><ColumnDefinition Width="20"/><ColumnDefinition Width="1*"/></Grid.ColumnDefinitions>

    <Border Grid.Column="0" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="16" Padding="28">
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock x:Name="PhaseText" Text="集中" FontSize="13" FontWeight="Medium" Foreground="{StaticResource Accent}" HorizontalAlignment="Center"/>
        <Grid Width="270" Height="270" Margin="0,16,0,16">
          <Ellipse Stroke="{StaticResource Track}" StrokeThickness="6"/>
          <Ellipse x:Name="Ring" Stroke="{StaticResource Accent}" StrokeThickness="6" StrokeDashArray="133.2 133.2" StrokeDashCap="Round"
                   RenderTransformOrigin="0.5,0.5"><Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform></Ellipse>
          <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
            <TextBlock x:Name="RemainText" Text="30:00" FontFamily="Georgia, Yu Mincho" FontSize="62" HorizontalAlignment="Center"/>
            <TextBlock x:Name="SubText" Text="" FontSize="13" Foreground="{StaticResource Muted}" HorizontalAlignment="Center"/>
          </StackPanel>
        </Grid>
        <StackPanel x:Name="Dots" Orientation="Horizontal" HorizontalAlignment="Center" Height="10"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,22,0,0">
          <Button x:Name="BtnStart" Content="開始" Style="{StaticResource PillPrimary}" Margin="4"/>
          <Button x:Name="BtnSkip" Content="スキップ" Style="{StaticResource Pill}" Margin="4"/>
          <Button x:Name="BtnReset" Content="リセット" Style="{StaticResource Pill}" Margin="4"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <Border Grid.Column="2" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="16" Padding="24,18,24,18">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel>
          <TextBlock Text="フォーカスセッション" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,0,0,4"/>
          <StackPanel x:Name="SessionPanel">
            <Border Style="{StaticResource RowBorder}"><Grid><StackPanel VerticalAlignment="Center"><TextBlock Text="合計時間"/><TextBlock Text="休憩込み・自動で分割" FontSize="12" Foreground="{StaticResource Muted}"/></StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Button x:Name="FocusMinus" Content="−" Style="{StaticResource Step}"/>
                <TextBlock x:Name="FocusVal" Width="70" TextAlignment="Center" VerticalAlignment="Center"/>
                <Button x:Name="FocusPlus" Content="+" Style="{StaticResource Step}"/></StackPanel></Grid></Border>
            <Border Style="{StaticResource RowBorder}" Padding="0,8"><StackPanel VerticalAlignment="Center"><TextBlock Text="内訳" FontSize="12" Foreground="{StaticResource Muted}"/><TextBlock x:Name="PlanText" Foreground="{StaticResource Accent}" TextWrapping="Wrap"/></StackPanel></Border>
            <Border Style="{StaticResource RowBorder}"><Grid><TextBlock Text="休憩を入れる" VerticalAlignment="Center"/>
              <ToggleButton x:Name="TglBreaks" Style="{StaticResource Switch}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></Border>
            <Border Style="{StaticResource RowBorder}"><Grid><TextBlock Text="休憩の長さ" VerticalAlignment="Center"/>
              <Border x:Name="BreakSeg" HorizontalAlignment="Right" VerticalAlignment="Center" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="16" Padding="2">
                <StackPanel Orientation="Horizontal">
                  <RadioButton x:Name="RbB5" GroupName="brk" Content="5分" Style="{StaticResource Seg}"/>
                  <RadioButton x:Name="RbB10" GroupName="brk" Content="10分" Style="{StaticResource Seg}"/>
                  <RadioButton x:Name="RbB15" GroupName="brk" Content="15分" Style="{StaticResource Seg}"/></StackPanel></Border></Grid></Border>
            <Border Style="{StaticResource RowBorder}"><Grid><TextBlock Text="次のセッションを自動で始める" VerticalAlignment="Center"/>
              <ToggleButton x:Name="TglAuto" Style="{StaticResource Switch}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></Border>
          </StackPanel>

          <TextBlock Text="アラーム" FontSize="12" Foreground="{StaticResource Muted}" Margin="0,22,0,4"/>
          <Border Style="{StaticResource RowBorder}"><Grid><TextBlock Text="音" VerticalAlignment="Center"/>
            <ComboBox x:Name="CmbSound" Style="{StaticResource DarkCombo}" Width="150" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></Border>
          <Border Style="{StaticResource RowBorder}"><Grid><TextBlock Text="音量" VerticalAlignment="Center"/>
            <Slider x:Name="SldVol" Width="150" Minimum="10" Maximum="100" TickFrequency="5" IsSnapToTickEnabled="True" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></Border>
          <Border Style="{StaticResource RowBorder}"><Grid><TextBlock Text="スヌーズ" VerticalAlignment="Center"/>
            <Border HorizontalAlignment="Right" VerticalAlignment="Center" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="16" Padding="2">
              <StackPanel Orientation="Horizontal">
                <RadioButton x:Name="RbS1" GroupName="snz" Content="1分" Style="{StaticResource Seg}"/>
                <RadioButton x:Name="RbS5" GroupName="snz" Content="5分" Style="{StaticResource Seg}"/>
                <RadioButton x:Name="RbS10" GroupName="snz" Content="10分" Style="{StaticResource Seg}"/></StackPanel></Border></Grid></Border>
          <Border Style="{StaticResource RowBorder}"><Grid><TextBlock Text="デスクトップ通知も出す" VerticalAlignment="Center"/>
            <ToggleButton x:Name="TglToast" Style="{StaticResource Switch}" HorizontalAlignment="Right" VerticalAlignment="Center"/></Grid></Border>
          <Button x:Name="BtnTest" Content="鳴らして確認する" Style="{StaticResource Pill}" HorizontalAlignment="Left" Margin="0,16,0,0"/>
        </StackPanel>
      </ScrollViewer>
    </Border>
  </Grid>
</Window>
'@

$AlarmXamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="集中アラーム" Width="460" SizeToContent="Height" Topmost="True" WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize" FontFamily="Yu Gothic UI" Background="#1E1D1B" Foreground="#ECE9E2">
  <Window.Resources>@@STYLES@@</Window.Resources>
  <StackPanel Margin="32" HorizontalAlignment="Center">
    <Grid Width="96" Height="96" HorizontalAlignment="Center">
      <Ellipse x:Name="Halo" Fill="{StaticResource AccentSoft}"/>
      <TextBlock x:Name="Bell" Text="&#xEA8F;" FontFamily="Segoe MDL2 Assets, Segoe Fluent Icons" FontSize="38" Foreground="{StaticResource Accent}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Grid>
    <TextBlock x:Name="AlarmTitle" FontFamily="Georgia, Yu Mincho" FontSize="28" TextAlignment="Center" TextWrapping="Wrap" Margin="0,20,0,0"/>
    <TextBlock x:Name="AlarmBody" FontSize="14" Foreground="{StaticResource Muted}" TextAlignment="Center" TextWrapping="Wrap" Margin="0,8,0,0" MaxWidth="360"/>
    <TextBlock x:Name="AlarmTime" FontSize="12" Foreground="{StaticResource Muted}" TextAlignment="Center" Margin="0,4,0,0"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,24,0,0">
      <Button x:Name="BtnAck" Content="止める" Style="{StaticResource PillPrimary}" IsDefault="True" Margin="4"/>
      <Button x:Name="BtnSnooze" Content="スヌーズ" Style="{StaticResource Pill}" Margin="4"/>
    </StackPanel>
  </StackPanel>
</Window>
'@
$MainXaml.InnerXml = $MainXaml.InnerXml.Replace('@@STYLES@@', $StylesXaml.Substring($StylesXaml.IndexOf('<ResourceDictionary')))
$AlarmXamlText = $AlarmXamlText.Replace('@@STYLES@@', $StylesXaml)

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $MainXaml))
$ui = @{}
foreach ($n in @('PhaseText','Ring','RemainText','SubText','Dots','BtnStart','BtnSkip','BtnReset','SessionPanel',
                 'FocusMinus','FocusVal','FocusPlus','PlanText','TglBreaks','BreakSeg','RbB5','RbB10','RbB15','TglAuto',
                 'CmbSound','SldVol','RbS1','RbS5','RbS10','TglToast','BtnTest')) { $ui[$n] = $window.FindName($n) }

$BC = New-Object System.Windows.Media.BrushConverter
$BrushFocus = $BC.ConvertFromString('#E08A66'); $BrushBreak = $BC.ConvertFromString('#7FB3A4')
$BrushDone  = $BC.ConvertFromString('#E08A66'); $BrushTodo  = $BC.ConvertFromString('#34322E')

# 音の一覧（Windows 標準のアラーム音・着信音）
foreach ($kind in @(@('Alarm', 'アラーム '), @('Ring', '着信音 '))) {
    for ($i = 1; $i -le 10; $i++) {
        $id = '{0}{1:00}' -f $kind[0], $i
        if (Test-Path -LiteralPath (Join-Path $MediaDir ($id + '.wav'))) {
            $it = New-Object System.Windows.Controls.ComboBoxItem
            $it.Content = $kind[1] + $i; $it.Tag = $id
            [void]$ui.CmbSound.Items.Add($it)
        }
    }
}

# ---------------------------------------------------------------- 表示
function Format-Span {
    param([timespan]$Span)
    if ($Span -lt [timespan]::Zero) { $Span = [timespan]::Zero }
    $t = [int][math]::Ceiling($Span.TotalSeconds)
    return ('{0:00}:{1:00}' -f [int][math]::Floor($t / 60), ($t % 60))
}

function Update-Dots {
    $ui.Dots.Children.Clear()
    $n = $S.Plan.Count
    $done = 0
    if ($S.State -ne 'Idle') { $done = $S.Cycle - 1; if ($S.Phase -eq 'Break') { $done = $S.Cycle } }
    for ($i = 1; $i -le $n; $i++) {
        $e = New-Object System.Windows.Shapes.Ellipse
        $e.Width = 8; $e.Height = 8; $e.Margin = New-Object System.Windows.Thickness(4, 0, 4, 0)
        if ($i -le $done) { $e.Fill = $BrushDone } else { $e.Fill = $BrushTodo }
        [void]$ui.Dots.Children.Add($e)
    }
}

function Set-Ring {
    param([double]$Fraction, $Brush)   # Fraction: 残り割合 0..1
    $f = [math]::Max(0.0, [math]::Min(1.0, $Fraction))
    $ui.Ring.StrokeDashOffset = 133.2 * (1.0 - $f)
    $ui.Ring.Stroke = $Brush
    $ui.Ring.Visibility = if ($f -le 0.0005) { 'Hidden' } else { 'Visible' }
}

function Update-Display {
    $isBreak = ($S.Phase -eq 'Break')
    $brush = if ($isBreak) { $BrushBreak } else { $BrushFocus }
    $ui.PhaseText.Foreground = $brush
    $ui.PhaseText.Text = if ($isBreak) { '休憩' } else { '集中' }
    switch ($S.State) {
        'Idle' {
            $ui.RemainText.Text = Format-Span ([timespan]::FromMinutes([double]$S.Plan[0]))
            $ui.SubText.Text = '準備ができました'
            Set-Ring 1.0 $brush
        }
        'WaitingAck' {
            $ui.RemainText.Text = '00:00'
            $ui.SubText.Text = '確認待ち'
            Set-Ring 0.0 $brush
        }
        default {
            $rem = if ($S.State -eq 'Running') { $S.EndTime - (Get-Date) } else { $S.Remaining }
            $ui.RemainText.Text = Format-Span $rem
            $ui.SubText.Text = if ($S.State -eq 'Paused') { '一時停止中' } elseif ($isBreak) { 'ゆっくり休みましょう' } else { '集中しています' }
            if ($S.PhaseTotal.TotalSeconds -gt 0) { Set-Ring ($rem.TotalSeconds / $S.PhaseTotal.TotalSeconds) $brush }
        }
    }
    $ui.BtnStart.Content = if ($S.State -eq 'Running') { '一時停止' } elseif ($S.State -eq 'Paused') { '再開' } else { '開始' }
    $ui.BtnStart.IsEnabled = ($S.State -ne 'WaitingAck')
    $ui.BtnSkip.IsEnabled  = ($S.State -ne 'Idle')
    $ui.BtnReset.IsEnabled = ($S.State -ne 'Idle')
    $ui.SessionPanel.IsEnabled = ($S.State -eq 'Idle')
    $ui.SessionPanel.Opacity = if ($S.State -eq 'Idle') { 1.0 } else { 0.55 }
    $window.Title = if ($S.State -eq 'Idle') { '集中アラーム' } else { '{0} {1} - 集中アラーム' -f $ui.RemainText.Text, $ui.PhaseText.Text }
}

function Sync-SettingsToUi {
    Update-Plan
    $ui.FocusVal.Text = '{0} 分' -f $S.Settings.TotalMinutes
    $ui.PlanText.Text = Get-PlanSummary
    $ui.TglBreaks.IsChecked = [bool]$S.Settings.Breaks
    $ui.TglAuto.IsChecked   = [bool]$S.Settings.AutoStart
    $ui.TglToast.IsChecked  = [bool]$S.Settings.UseToast
    $ui.BreakSeg.IsEnabled = [bool]$S.Settings.Breaks
    $ui.BreakSeg.Opacity = if ($S.Settings.Breaks) { 1.0 } else { 0.4 }
    switch ([int]$S.Settings.BreakMinutes) { 10 { $ui.RbB10.IsChecked = $true } 15 { $ui.RbB15.IsChecked = $true } default { $ui.RbB5.IsChecked = $true } }
    switch ([int]$S.Settings.SnoozeMinutes) { 1 { $ui.RbS1.IsChecked = $true } 10 { $ui.RbS10.IsChecked = $true } default { $ui.RbS5.IsChecked = $true } }
    $ui.SldVol.Value = [double]$S.Settings.Volume
    foreach ($it in $ui.CmbSound.Items) { if ($it.Tag -eq $S.Settings.Sound) { $ui.CmbSound.SelectedItem = $it } }
    if ($null -eq $ui.CmbSound.SelectedItem -and $ui.CmbSound.Items.Count -gt 0) { $ui.CmbSound.SelectedIndex = 0 }
}

# ---------------------------------------------------------------- セッション制御
function Get-NextPhase {
    $n = $S.Plan.Count
    if ($S.Phase -eq 'Work') {
        if ($S.Cycle -ge $n) { return $null }
        if ([bool]$S.Settings.Breaks) { return @{ Phase = 'Break'; Cycle = $S.Cycle } }
        return @{ Phase = 'Work'; Cycle = ($S.Cycle + 1) }
    }
    return @{ Phase = 'Work'; Cycle = ($S.Cycle + 1) }
}

function Start-Phase {
    param([string]$Phase, [int]$Cycle)
    $S.Phase = $Phase; $S.Cycle = $Cycle
    $min = if ($Phase -eq 'Work') { [double]$S.Plan[$Cycle - 1] } else { [double]$S.Settings.BreakMinutes }
    $S.PhaseTotal = [timespan]::FromMinutes($min)
    $S.EndTime = (Get-Date) + $S.PhaseTotal
    $S.Remaining = $S.PhaseTotal
    $S.Pending = $null
    $S.State = 'Running'
    $timer.Start()
    Update-Dots; Update-Display
}

function Stop-SnoozeTimer { if ($null -ne $S.SnoozeTimer) { try { $S.SnoozeTimer.Stop() } catch { }; $S.SnoozeTimer = $null } }
function Close-AlarmWindow {
    if ($null -ne $S.AlarmWin) { $w = $S.AlarmWin; $S.AlarmWin = $null; $w.Tag = 'handled'; try { $w.Close() } catch { } }
}
function Reset-Session {
    $timer.Stop(); Stop-SnoozeTimer; Stop-Sound; Close-AlarmWindow; Remove-AlarmToast
    $S.State = 'Idle'; $S.Phase = 'Work'; $S.Cycle = 1; $S.Pending = $null
    Update-Dots; Update-Display
}

function Invoke-AlarmAck {
    Stop-SnoozeTimer; Stop-Sound; Remove-AlarmToast; Close-AlarmWindow
    if ($S.State -eq 'WaitingAck' -and $null -ne $S.Pending) { Start-Phase $S.Pending.Phase $S.Pending.Cycle }
    Update-Display
}
function Invoke-AlarmSnooze {
    Stop-SnoozeTimer; Stop-Sound; Remove-AlarmToast; Close-AlarmWindow
    $st = New-Object System.Windows.Threading.DispatcherTimer
    $st.Interval = [timespan]::FromMinutes([double]$S.Settings.SnoozeMinutes)
    $st.Add_Tick({
        try { Stop-SnoozeTimer; if ($null -ne $S.LastAlarm) { Raise-Alarm $S.LastAlarm.Title $S.LastAlarm.Body $S.LastAlarm.Ack } }
        catch { Write-AppLog ('スヌーズ処理エラー: {0}' -f $_) }
    })
    $S.SnoozeTimer = $st; $st.Start()
}

function Show-AlarmWindow {
    param([string]$Title, [string]$Body, [string]$AckText, [bool]$Break)
    Close-AlarmWindow
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$AlarmXamlText)))
    $w.FindName('AlarmTitle').Text = $Title
    $w.FindName('AlarmBody').Text  = $Body
    $w.FindName('AlarmTime').Text  = (Get-Date).ToString('HH:mm')
    if ($Break) {
        $w.FindName('Halo').Fill = $BC.ConvertFromString('#25332F')
        $w.FindName('Bell').Foreground = $BrushBreak
    }
    $w.FindName('BtnAck').Content = $AckText
    $w.FindName('BtnSnooze').Content = ('スヌーズ {0}分' -f $S.Settings.SnoozeMinutes)
    $w.FindName('BtnAck').Add_Click({ try { Invoke-AlarmAck } catch { Write-AppLog ('確認処理エラー: {0}' -f $_) } })
    $w.FindName('BtnSnooze').Add_Click({ try { Invoke-AlarmSnooze } catch { Write-AppLog ('スヌーズエラー: {0}' -f $_) } })
    $w.Add_Closed({
        param($src, $e)
        try {
            if ($src.Tag -ne 'handled') {
                $src.Tag = 'handled'
                if ([object]::ReferenceEquals($S.AlarmWin, $src)) { $S.AlarmWin = $null }
                Invoke-AlarmAck
            }
        } catch { Write-AppLog ('ウィンドウ終了処理エラー: {0}' -f $_) }
    })
    $w.Tag = 'open'
    $S.AlarmWin = $w
    $w.Show(); $w.Topmost = $true; $null = $w.Activate()
}

function Raise-Alarm {
    param([string]$Title, [string]$Body, [string]$AckText = '止める', [bool]$Break = $false)
    $S.LastAlarm = @{ Title = $Title; Body = $Body; Ack = $AckText }
    if ([bool]$S.Settings.UseToast) { Show-AlarmToast $Title $Body }
    Show-AlarmWindow $Title $Body $AckText $Break
    Start-Sound
    if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) { $window.WindowState = [System.Windows.WindowState]::Normal }
}

function Complete-Phase {
    $n = $S.Plan.Count
    $wasWork = ($S.Phase -eq 'Work')
    $next = Get-NextPhase
    $ack = '止める'
    if ($null -eq $next) {
        $title = 'すべてのセッションが完了'
        $body  = ('{0} 回の集中セッションが終わりました。お疲れさまでした。' -f $n)
    } elseif ($next.Phase -eq 'Break') {
        $title = '休憩の時間です'
        $body  = ('セッション {0}/{1} が終わりました。{2} 分休みましょう。' -f $S.Cycle, $n, $S.Settings.BreakMinutes)
        $ack = '休憩を始める'
    } else {
        $title = if ($wasWork) { '次のセッションへ' } else { '休憩が終わりました' }
        $body  = ('セッション {0}/{1}（{2} 分）を始めましょう。' -f $next.Cycle, $n, $S.Plan[$next.Cycle - 1])
        $ack = '集中を始める'
    }
    $isBreakNext = ($null -ne $next -and $next.Phase -eq 'Break')

    if ($null -eq $next) {
        $timer.Stop(); $S.State = 'Idle'; $S.Phase = 'Work'; $S.Cycle = 1; $S.Pending = $null
    } elseif ([bool]$S.Settings.AutoStart) {
        Start-Phase $next.Phase $next.Cycle
        $ack = '止める'
    } else {
        $timer.Stop(); $S.State = 'WaitingAck'; $S.Pending = $next
    }
    Update-Dots; Update-Display
    Raise-Alarm $title $body $ack $isBreakNext
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [timespan]::FromMilliseconds(250)
$timer.Add_Tick({
    try {
        if ($S.State -eq 'Running') {
            if ((Get-Date) -ge $S.EndTime) { Complete-Phase } else { Update-Display }
        }
    } catch { Write-AppLog ('タイマーエラー: {0}' -f $_) }
})

# ---------------------------------------------------------------- イベント
$ui.BtnStart.Add_Click({
    try {
        switch ($S.State) {
            'Idle'    { Start-Phase 'Work' 1 }
            'Running' { $S.Remaining = $S.EndTime - (Get-Date); $S.State = 'Paused'; $timer.Stop(); Update-Display }
            'Paused'  { $S.EndTime = (Get-Date) + $S.Remaining; $S.State = 'Running'; $timer.Start(); Update-Display }
        }
    } catch { Write-AppLog ('開始エラー: {0}' -f $_) }
})
$ui.BtnReset.Add_Click({ try { Reset-Session } catch { Write-AppLog ('リセットエラー: {0}' -f $_) } })
$ui.BtnSkip.Add_Click({
    try {
        if ($S.State -eq 'WaitingAck') { Invoke-AlarmAck; return }
        $next = Get-NextPhase
        if ($null -eq $next) { Reset-Session } else { Start-Phase $next.Phase $next.Cycle }
    } catch { Write-AppLog ('スキップエラー: {0}' -f $_) }
})
$ui.BtnTest.Add_Click({
    try { Raise-Alarm 'テスト' 'アラームの音と通知を確認しています。' '止める' $false } catch { Write-AppLog ('テストエラー: {0}' -f $_) }
})

function Step-Setting {
    param([string]$Key, [int]$Delta, [int]$Min, [int]$Max)
    $v = [int]$S.Settings[$Key] + $Delta
    $S.Settings[$Key] = [math]::Max($Min, [math]::Min($Max, $v))
    Sync-SettingsToUi; Update-Dots; Update-Display; Save-Settings
}
$ui.FocusMinus.Add_Click({ Step-Setting 'TotalMinutes' -5 15 240 })
$ui.FocusPlus.Add_Click({ Step-Setting 'TotalMinutes' 5 15 240 })
$ui.TglBreaks.Add_Click({ $S.Settings.Breaks = [bool]$ui.TglBreaks.IsChecked; Sync-SettingsToUi; Update-Dots; Update-Display; Save-Settings })
$ui.TglAuto.Add_Click({ $S.Settings.AutoStart = [bool]$ui.TglAuto.IsChecked; Save-Settings })
$ui.TglToast.Add_Click({ $S.Settings.UseToast = [bool]$ui.TglToast.IsChecked; Save-Settings })
$ui.RbB5.Add_Click({ $S.Settings.BreakMinutes = 5; Sync-SettingsToUi; Update-Dots; Update-Display; Save-Settings })
$ui.RbB10.Add_Click({ $S.Settings.BreakMinutes = 10; Sync-SettingsToUi; Update-Dots; Update-Display; Save-Settings })
$ui.RbB15.Add_Click({ $S.Settings.BreakMinutes = 15; Sync-SettingsToUi; Update-Dots; Update-Display; Save-Settings })
$ui.RbS1.Add_Click({ $S.Settings.SnoozeMinutes = 1; Save-Settings })
$ui.RbS5.Add_Click({ $S.Settings.SnoozeMinutes = 5; Save-Settings })
$ui.RbS10.Add_Click({ $S.Settings.SnoozeMinutes = 10; Save-Settings })
$ui.SldVol.Add_ValueChanged({
    try { $S.Settings.Volume = [int]$ui.SldVol.Value; if ($null -ne $S.Media) { $S.Media.Volume = $S.Settings.Volume / 100.0 }; Save-Settings } catch { }
})
$ui.CmbSound.Add_SelectionChanged({
    try {
        $it = $ui.CmbSound.SelectedItem
        if ($null -ne $it -and $it.Tag -ne $S.Settings.Sound) {
            $S.Settings.Sound = [string]$it.Tag; Save-Settings
            if ($null -eq $S.AlarmWin) { Start-Sound 4 }   # 試聴
        }
    } catch { Write-AppLog ('音の変更エラー: {0}' -f $_) }
})

$window.Add_Closing({
    param($src, $e)
    try {
        if ($S.State -ne 'Idle') {
            $r = [System.Windows.MessageBox]::Show('セッションの実行中です。終了しますか？', '集中アラーム',
                [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
            if ($r -ne [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true; return }
        }
        $timer.Stop(); Stop-SnoozeTimer; Stop-Sound; Close-AlarmWindow; Remove-AlarmToast; Save-Settings
    } catch { Write-AppLog ('終了処理エラー: {0}' -f $_) }
})
$window.Dispatcher.Add_UnhandledException({
    param($src, $e)
    Write-AppLog ('未処理の例外: {0}' -f $e.Exception)
    $e.Handled = $true
})

# ---------------------------------------------------------------- 起動
try {
    Sync-SettingsToUi; Update-Dots; Update-Display
    if ($null -eq [System.Windows.Application]::Current) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
        $null = $app.Run($window)
    } else {
        $null = $window.ShowDialog()
    }
} catch {
    Write-AppLog ('致命的エラー: {0}' -f $_)
    [System.Windows.MessageBox]::Show(('エラーが発生しました:{0}{1}{0}{0}ログ: {2}' -f [Environment]::NewLine, $_, $LogPath), '集中アラーム') | Out-Null
} finally {
    Stop-Sound
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
