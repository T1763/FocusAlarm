#Requires -Version 5.1
# スタートメニューとデスクトップに「集中アラーム」のショートカットを作り、ダウンロード由来のブロックを解除します。
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $PSScriptRoot 'FocusAlarm.ps1'
$name   = '集中アラーム.lnk'
$targets = @((Join-Path ([Environment]::GetFolderPath('Programs')) $name), (Join-Path ([Environment]::GetFolderPath('Desktop')) $name))
if ($Remove) { foreach ($p in $targets) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host "削除しました: $p" } }; return }
Get-ChildItem -LiteralPath $PSScriptRoot -File | ForEach-Object { try { Unblock-File -LiteralPath $_.FullName } catch { } }
$shell = New-Object -ComObject WScript.Shell
foreach ($lnk in $targets) {
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = $psExe
    $s.Arguments = ('-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script)
    $s.WorkingDirectory = $PSScriptRoot
    $s.WindowStyle = 7
    $s.IconLocation = (Join-Path $env:SystemRoot 'System32\timedate.cpl') + ',0'
    $s.Description = '集中アラーム'
    $s.Save()
    Write-Host "作成しました: $lnk"
}