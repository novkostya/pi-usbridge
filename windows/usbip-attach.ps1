# Keeps the USB devices the Pi shares attached to this PC over USB/IP.
# usbip-win2 reattaches by itself too, but waits a fixed 30 s after every
# disconnect (Pi rebooted, device replugged); this attaches within ~2 s of
# the Pi offering a device. setup.ps1 runs it at startup as a scheduled task.
#
#   usbip-attach.ps1 [-Server usbridge.local] [-Port 3240]
#
# It looks the name up itself and gives usbip the address: usbip-win2's
# driver resolves names with plain DNS only, so not .local ones.
param(
	[string]$Server = 'usbridge.local',
	[int]$Port = 3240
)
$usbip = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
$log = Join-Path $PSScriptRoot 'usbip-attach.log'

function Say([string]$msg) {
	if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Remove-Item $log }
	Add-Content $log "$(Get-Date -Format s) $msg"
}

# The Pi's IPv4 address, or $null. A .local lookup takes ~2.7 s (Windows
# waits for an IPv6 address the Pi doesn't have) and Windows only caches it
# for ~10 s, so the loop keeps the address while it answers.
function Address {
	try {
		$a = [Net.Dns]::GetHostAddresses($Server) | Where-Object AddressFamily -eq 'InterNetwork'
		return ($a | Select-Object -First 1).IPAddressToString
	} catch { return $null }
}

function Reachable([string]$ip) {
	$c = New-Object Net.Sockets.TcpClient
	try { return $c.ConnectAsync($ip, $Port).Wait(700) } catch { return $false } finally { $c.Dispose() }
}

$last = @{}  # last attach result per bus ID: log changes only
$ip = $null
Say "started: $Server port $Port"
while ($true) {
	if (-not ($ip -and (Reachable $ip))) {
		$ip = Address  # new or changed address, or the Pi is down
		if ($ip -and -not (Reachable $ip)) { $ip = $null }
	}
	if ($ip) {
		# "   1-1.3   : Sony Corp. : DualSense ..." lines from the Pi's list
		$offered = @(& $usbip -t $Port list -r $ip 2>$null |
			ForEach-Object { if ($_ -match '^\s*(\d+-[\d.]+)\s+:') { $Matches[1] } })
		# "-> usbip://192.168.1.50:3240/1-1.3" lines for what's attached here
		$url = [regex]::Escape("usbip://${ip}:$Port/")
		$attached = @(& $usbip port 2>$null |
			ForEach-Object { if ($_ -match "$url(\S+)") { $Matches[1] } })
		foreach ($busid in $offered) {
			if ($attached -contains $busid) { continue }
			# Fails while another PC has the device; retried every 2 s.
			$out = (& $usbip -t $Port attach -r $ip -b $busid --once 2>&1) -join ' '
			if ($last[$busid] -ne $out) { Say "attach ${busid} from ${ip}: $out" }
			$last[$busid] = $out
		}
	}
	Start-Sleep -Seconds 2
}
