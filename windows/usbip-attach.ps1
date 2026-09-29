# Keeps the USB devices shared with this PC attached over USB/IP:
# - the Pi's, whenever it offers some;
# - those of Moonlight USBridge on a phone or tablet, while it streams from
#   this PC (it advertises _usbip._tcp over mDNS, naming the PC it streams
#   from, and only lets that PC connect).
# usbip-win2 reattaches by itself too, but waits a fixed 30 s after every
# disconnect (Pi rebooted, device replugged); this attaches within ~2 s of a
# device being offered. setup.ps1 runs it at startup as a scheduled task.
#
#   usbip-attach.ps1 [-Server usbridge.local] [-Port 3240]
#                    [-ReceiveMode zero-copy|low-latency] [-Once]
#
# -ReceiveMode is how usbip-win2 receives device data: zero-copy (its default)
# or low-latency, which it recommends for small, frequent transfers.
#
# It looks the name up itself and gives usbip the address: usbip-win2's
# driver resolves names with plain DNS only, so not .local ones.
param(
	[string]$Server = 'usbridge.local',
	[int]$Port = 3240,
	[ValidateSet('zero-copy', 'low-latency')]
	[string]$ReceiveMode = 'zero-copy',
	[switch]$Once  # one round, for testing
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

function Reachable([string]$ip, [int]$port) {
	$c = New-Object Net.Sockets.TcpClient
	try { return $c.ConnectAsync($ip, $port).Wait(700) } catch { return $false } finally { $c.Dispose() }
}

# The name at $pos in DNS message $m: @(name, position after it)
function Read-Name([byte[]]$m, [int]$pos) {
	$labels = @(); $end = -1; $hops = 0
	while ($pos -lt $m.Length) {
		$l = [int]$m[$pos]
		if ($l -eq 0) { $pos++; break }
		if (($l -band 0xc0) -eq 0xc0) {  # compression pointer
			if ($end -lt 0) { $end = $pos + 2 }
			if (++$hops -gt 16 -or $pos + 1 -ge $m.Length) { break }
			$pos = (($l -band 0x3f) -shl 8) -bor $m[$pos + 1]
			continue
		}
		if ($pos + 1 + $l -gt $m.Length) { break }
		$labels += [Text.Encoding]::UTF8.GetString($m, $pos + 1, $l)
		$pos += 1 + $l
	}
	if ($end -lt 0) { $end = $pos }
	return , @(($labels -join '.'), $end)
}

# This PC's IPv4 addresses
function Mine {
	[Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
		Where-Object OperationalStatus -eq 'Up' |
		ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
		Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
		ForEach-Object { $_.Address.IPAddressToString }
}

# "ip:port" of every _usbip._tcp service on the LAN that names this PC as its
# host. Asks from an ordinary port with the "unicast response" bit set, so the
# answers come straight back here (Android's responder ignores plain
# "legacy unicast" queries).
$query = [byte[]](0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 6) + [Text.Encoding]::ASCII.GetBytes('_usbip') +
	[byte[]](4) + [Text.Encoding]::ASCII.GetBytes('_tcp') + [byte[]](5) + [Text.Encoding]::ASCII.GetBytes('local') +
	[byte[]](0, 0, 12, 0x80, 1)
function Exporters {
	$mine = @(Mine)
	$ptr = @{}; $srv = @{}; $txt = @{}; $a = @{}
	$u = New-Object Net.Sockets.UdpClient(0)
	try {
		[void]$u.Send($query, $query.Length, '224.0.0.251', 5353)
		$until = (Get-Date).AddMilliseconds(400)
		while (($left = ($until - (Get-Date)).TotalMilliseconds) -gt 0) {
			$u.Client.ReceiveTimeout = [Math]::Max(1, [int]$left)
			try { $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $m = $u.Receive([ref]$ep) } catch { break }
			if ($m.Length -lt 12) { continue }
			$pos = 12
			for ($i = 0; $i -lt ($m[4] * 256 + $m[5]); $i++) { $pos = (Read-Name $m $pos)[1] + 4 }
			$records = ($m[6] * 256 + $m[7]) + ($m[8] * 256 + $m[9]) + ($m[10] * 256 + $m[11])
			for ($i = 0; $i -lt $records -and $pos + 10 -le $m.Length; $i++) {
				$r = Read-Name $m $pos
				$name = $r[0]; $pos = $r[1]
				$type = $m[$pos] * 256 + $m[$pos + 1]
				$gone = $m[$pos + 4] -eq 0 -and $m[$pos + 5] -eq 0 -and $m[$pos + 6] -eq 0 -and $m[$pos + 7] -eq 0
				$len = $m[$pos + 8] * 256 + $m[$pos + 9]
				$data = $pos + 10
				$pos = $data + $len
				if ($pos -gt $m.Length -or $gone) { continue }  # TTL 0: going away
				switch ($type) {
					12 { if ($name -eq '_usbip._tcp.local') { $ptr[(Read-Name $m $data)[0]] = 1 } }
					33 { $srv[$name] = @(($m[$data + 4] * 256 + $m[$data + 5]), (Read-Name $m ($data + 6))[0]) }
					16 {
						for ($p = $data; $p -lt $data + $len; $p += 1 + $m[$p]) {
							$kv = [Text.Encoding]::UTF8.GetString($m, $p + 1, $m[$p])
							if ($kv -like 'host=*') { $txt[$name] = $kv.Substring(5) }
						}
					}
					1 { $a[$name] = "$($m[$data]).$($m[$data + 1]).$($m[$data + 2]).$($m[$data + 3])" }
				}
			}
		}
	} finally { $u.Close() }
	foreach ($instance in $ptr.Keys) {
		$s = $srv[$instance]
		if ($s -and $a[$s[1]] -and $mine -contains $txt[$instance]) { "$($a[$s[1]]):$($s[0])" }
	}
}

$last = @{}  # last attach result per server and bus ID: log changes only
# Attach what the USB/IP server at $ip:$p offers and isn't attached yet.
function Attach-From([string]$ip, [int]$p) {
	# "   1-1.3   : Sony Corp. : DualSense ..." lines from its list
	$offered = @(& $usbip -t $p list -r $ip 2>$null |
		ForEach-Object { if ($_ -match '^\s*(\d+-[\d.]+)\s+:') { $Matches[1] } })
	# "-> usbip://192.168.1.50:3240/1-1.3" lines for what's attached here
	$url = [regex]::Escape("usbip://${ip}:$p/")
	$attached = @(& $usbip port 2>$null |
		ForEach-Object { if ($_ -match "$url(\S+)") { $Matches[1] } })
	foreach ($busid in $offered) {
		if ($attached -contains $busid) { continue }
		# Fails while another PC has the device; retried every 2 s.
		$out = (& $usbip -t $p attach -r $ip -b $busid --once --receive-mode $ReceiveMode 2>&1) -join ' '
		$key = "${ip}:$p/$busid"
		if ($last[$key] -ne $out) { Say "attach $busid from ${ip}:${p}: $out" }
		$last[$key] = $out
	}
}

$ip = $null
$seen = @{}  # exporter -> when it last answered: log arrivals, not every missed answer
Say "started: $Server port $Port, and Moonlight USBridge streaming from here; $ReceiveMode"
while ($true) {
	if (-not ($ip -and (Reachable $ip $Port))) {
		$ip = Address  # new or changed address, or the Pi is down
		if ($ip -and -not (Reachable $ip $Port)) { $ip = $null }
	}
	if ($ip) { Attach-From $ip $Port }
	foreach ($e in @(Exporters)) {
		if (-not $seen[$e] -or ((Get-Date) - $seen[$e]).TotalSeconds -gt 30) { Say "Moonlight USBridge at $e" }
		$seen[$e] = Get-Date
		$host_, $p = $e -split ':'
		Attach-From $host_ ([int]$p)
	}
	if ($Once) { break }
	Start-Sleep -Seconds 2
}
