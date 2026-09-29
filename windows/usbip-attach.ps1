# Keeps the USB devices the Pi shares attached to this PC over USB/IP.
# usbip-win2 reattaches by itself too, but waits a fixed 30 s after every
# disconnect (Pi rebooted, device replugged); this attaches within ~2 s of
# the Pi offering a device. setup.ps1 runs it at startup as a scheduled task.
#
#   usbip-attach.ps1 [-Server usbridge.lan] [-Port 3240]
param(
	[string]$Server = 'usbridge.lan',
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

$url = [regex]::Escape("usbip://${Server}:$Port/")
$last = @{}  # last attach result per bus ID: log changes only
Say "started: $Server port $Port"
while ($true) {
	if (Reachable) {
		# "   1-1.3   : Sony Corp. : DualSense ..." lines from the Pi's list
		$offered = @(& $usbip -t $Port list -r $Server 2>$null |
			ForEach-Object { if ($_ -match '^\s*(\d+-[\d.]+)\s+:') { $Matches[1] } })
		# "-> usbip://usbridge.lan:3240/1-1.3" lines for what's attached here
		$attached = @(& $usbip port 2>$null |
			ForEach-Object { if ($_ -match "$url(\S+)") { $Matches[1] } })
		foreach ($busid in $offered) {
			if ($attached -contains $busid) { continue }
			# Fails while another PC has the device; retried every 2 s.
			$out = (& $usbip -t $Port attach -r $Server -b $busid --once 2>&1) -join ' '
			if ($last[$busid] -ne $out) { Say "attach ${busid}: $out" }
			$last[$busid] = $out
		}
	}
	Start-Sleep -Seconds 2
}
