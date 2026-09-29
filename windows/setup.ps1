# Sets up this Windows PC as a client of the Pi: installs usbip-win2 (the
# USB/IP client, Microsoft-signed drivers) and a startup task that keeps the
# Pi's USB devices attached (usbip-attach.ps1). Run in PowerShell as
# administrator:
#
#   powershell -ExecutionPolicy Bypass -File setup.ps1 [-Server usbridge.local]
#       [-ReceiveMode zero-copy|low-latency]
#
# Undo: Unregister-ScheduledTask 'pi-usbridge attach'; uninstall "USBip" in
# Settings > Apps; delete $env:ProgramData\pi-usbridge.
param(
	[string]$Server = 'usbridge.local',
	[ValidateSet('zero-copy', 'low-latency')]
	[string]$ReceiveMode = 'zero-copy'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$version = '0.9.8.1'
$url = "https://github.com/vadimgrn/usbip-win2/releases/download/v.$version/USBip-$version-x64.exe"
$sha256 = '38cad6d4432b52d5bb9409d9ad03b72fdffc4ada4cd3a48fbeca1a2752a8518a'
$dir = Join-Path $env:ProgramData 'pi-usbridge'
$usbip = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
New-Item -ItemType Directory -Force $dir | Out-Null

$installed = if (Test-Path $usbip) { (& $usbip --version) -join '' } else { '' }
if ($installed -ne $version) {
	$exe = Join-Path $dir "USBip-$version-x64.exe"
	Write-Host "Downloading usbip-win2 $version"
	Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $exe
	if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $sha256) {
		Remove-Item $exe
		throw "checksum mismatch: $url"
	}
	Write-Host 'Installing usbip-win2 (Windows may ask to restart later; not needed now)'
	$p = Start-Process $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
	if ($p.ExitCode -ne 0) { throw "usbip-win2 installer failed: $($p.ExitCode)" }
	Remove-Item $exe
} else {
	Write-Host "usbip-win2 $version is installed"
}

Copy-Item (Join-Path $PSScriptRoot 'usbip-attach.ps1') $dir -Force
$script = Join-Path $dir 'usbip-attach.ps1'
$name = 'pi-usbridge attach'
if (Get-ScheduledTask $name -ErrorAction SilentlyContinue) {
	# Replacing the task: detach what the old one attached, the new one
	# attaches it again within seconds with its own settings.
	Stop-ScheduledTask $name
	Unregister-ScheduledTask $name -Confirm:$false
	& $usbip detach --all | Out-Null
}
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
	"-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass " +
	"-File `"$script`" -Server $Server -ReceiveMode $ReceiveMode")
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
	-RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
	-AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask $name -Action $action -Settings $settings `
	-Trigger (New-ScheduledTaskTrigger -AtStartup) -User SYSTEM -RunLevel Highest | Out-Null
Start-ScheduledTask $name
Write-Host "Done: USB devices plugged into the Pi ($Server) attach to this PC."
Write-Host "Log: $dir\usbip-attach.log"
