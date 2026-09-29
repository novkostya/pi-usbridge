# Keeps the Pi's controller attached to this PC over USB/IP. usbip-win2
# reattaches by itself too, but waits a fixed 30 s after every disconnect
# (Pi rebooted, controller replugged); this attaches within ~2 s of the Pi
# offering it again. setup.ps1 runs it at startup as a scheduled task.
#
#   usbip-attach.ps1 [-Server vhusb.lan] [-BusId 1-1.3]
#
# The Pi's usbipd serves its one controller whatever bus ID is asked for, so
# the bus ID only matters with more than one controller plugged in.
param(
	[string]$Server = 'vhusb.lan',
	[string]$BusId = '1-1.3',
	[int]$Port = 3240
)
$usbip = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
$log = Join-Path $PSScriptRoot 'usbip-attach.log'

function Say([string]$msg) {
	if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Remove-Item $log }
	Add-Content $log "$(Get-Date -Format s) $msg"
}

function Reachable {
	$c = New-Object Net.Sockets.TcpClient
	try { return $c.ConnectAsync($Server, $Port).Wait(700) } catch { return $false } finally { $c.Dispose() }
}

Say "started: $Server port $Port, bus ID $BusId"
$last = ''
while ($true) {
	$attached = (& $usbip port 2>$null) -match [regex]::Escape("usbip://${Server}:$Port/")
	if (-not $attached -and (Reachable)) {
		# "Device not found" while nothing is plugged into the Pi: log changes only.
		$out = (& $usbip attach -r $Server -b $BusId --once 2>&1) -join ' '
		if ($out -ne $last) { Say "attach: $out" }
		$last = $out
	}
	Start-Sleep -Seconds 2
}
