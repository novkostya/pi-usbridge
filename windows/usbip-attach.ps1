# Keeps the USB devices shared with this PC attached over USB/IP:
# - the Pi's, whenever it offers some;
# - those of Moonlight USBridge on a phone or tablet, while it streams from
#   this PC (it advertises _usbip._tcp over mDNS, naming the PC it streams
#   from, and only lets that PC connect).
# usbip-win2 reattaches by itself too, but waits a fixed 30 s after every
# disconnect (Pi rebooted, device replugged); this attaches within ~2 s of a
# device being offered. setup.ps1 runs it at startup as a scheduled task.
#
#   usbip-attach.ps1 [-Server usbridge.local] [-Port 3240] [-Once]
#
# It looks the name up itself (over mDNS if it's a .local one) and gives
# usbip the address: usbip-win2's driver resolves names with plain DNS only,
# so not .local ones.
param(
	[string]$Server = 'usbridge.local',
	[int]$Port = 3240,
	[switch]$Once  # one round, for testing
)
$usbip = Join-Path $env:ProgramFiles 'USBip\usbip.exe'
$log = Join-Path $PSScriptRoot 'usbip-attach.log'

function Say([string]$msg) {
	if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Remove-Item $log }
	Add-Content $log "$(Get-Date -Format s) $msg"
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

# The records that answer an mDNS query for $name of type $type (1: A, 12:
# PTR) within 400 ms, each with the message it came in and where its data
# starts. Asks from an ordinary port with the "unicast response" bit set, so
# the answers come straight back here (Android's responder ignores plain
# "legacy unicast" queries), and on every network adapter: left to Windows,
# the query would go out of one only, maybe a VPN's.
function Ask-Mdns([string]$name, [int]$type) {
	$q = [byte[]](0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
	foreach ($label in $name.Split('.')) {
		$q += [byte[]]@($label.Length) + [Text.Encoding]::ASCII.GetBytes($label)
	}
	$q = [byte[]]($q + [byte[]](0, 0, $type, 0x80, 1))
	$records = @()
	$u = New-Object Net.Sockets.UdpClient(0)
	try {
		foreach ($ip in Mine) {
			if ($ip -like '127.*') { continue }
			try {
				$u.Client.SetSocketOption('IP', 'MulticastInterface', [Net.IPAddress]::Parse($ip).GetAddressBytes())
				[void]$u.Send($q, $q.Length, '224.0.0.251', 5353)
			} catch {}
		}
		$until = (Get-Date).AddMilliseconds(400)
		while (($left = ($until - (Get-Date)).TotalMilliseconds) -gt 0) {
			$u.Client.ReceiveTimeout = [Math]::Max(1, [int]$left)
			try { $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $m = $u.Receive([ref]$ep) } catch { break }
			if ($m.Length -lt 12) { continue }
			$pos = 12
			for ($i = 0; $i -lt ($m[4] * 256 + $m[5]); $i++) { $pos = (Read-Name $m $pos)[1] + 4 }
			$count = ($m[6] * 256 + $m[7]) + ($m[8] * 256 + $m[9]) + ($m[10] * 256 + $m[11])
			for ($i = 0; $i -lt $count -and $pos + 10 -le $m.Length; $i++) {
				$r = Read-Name $m $pos
				$pos = $r[1]
				$type = $m[$pos] * 256 + $m[$pos + 1]
				$gone = $m[$pos + 4] -eq 0 -and $m[$pos + 5] -eq 0 -and $m[$pos + 6] -eq 0 -and $m[$pos + 7] -eq 0
				$len = $m[$pos + 8] * 256 + $m[$pos + 9]
				$data = $pos + 10
				$pos = $data + $len
				if ($pos -gt $m.Length -or $gone) { continue }  # TTL 0: going away
				$records += [pscustomobject]@{ Name = $r[0]; Type = $type; Msg = $m; Data = $data; Len = $len }
			}
		}
	} finally { $u.Close() }
	return $records
}

# The Pi's IPv4 address, or $null. A .local name is asked over mDNS here
# rather than through Windows, which takes ~2.7 s (it waits for an IPv6
# address the Pi doesn't have) and at times ignores the Pi's answers for
# minutes on end. Other names, and .local ones nothing answers here for (in
# the hosts file, say), are left to Windows.
function Address {
	$name = $Server.TrimEnd('.')
	if ($name -like '*.local') {
		foreach ($r in Ask-Mdns $name 1) {
			if ($r.Type -eq 1 -and $r.Name -eq $name) { return $r.Msg[$r.Data..($r.Data + 3)] -join '.' }
		}
	}
	try {
		$a = [Net.Dns]::GetHostAddresses($Server) | Where-Object AddressFamily -eq 'InterNetwork'
		return ($a | Select-Object -First 1).IPAddressToString
	} catch { return $null }
}

# "ip:port" of every _usbip._tcp service on the LAN that names this PC as its
# host.
function Exporters {
	$mine = @(Mine)
	$ptr = @{}; $srv = @{}; $txt = @{}; $a = @{}
	foreach ($r in Ask-Mdns '_usbip._tcp.local' 12) {
		$m = $r.Msg; $data = $r.Data
		switch ($r.Type) {
			12 { if ($r.Name -eq '_usbip._tcp.local') { $ptr[(Read-Name $m $data)[0]] = 1 } }
			33 { $srv[$r.Name] = @(($m[$data + 4] * 256 + $m[$data + 5]), (Read-Name $m ($data + 6))[0]) }
			16 {
				for ($p = $data; $p -lt $data + $r.Len; $p += 1 + $m[$p]) {
					$kv = [Text.Encoding]::UTF8.GetString($m, $p + 1, $m[$p])
					if ($kv -like 'host=*') { $txt[$r.Name] = $kv.Substring(5) }
				}
			}
			1 { $a[$r.Name] = $m[$data..($data + 3)] -join '.' }
		}
	}
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
		$out = (& $usbip -t $p attach -r $ip -b $busid --once 2>&1) -join ' '
		$key = "${ip}:$p/$busid"
		if ($last[$key] -ne $out) { Say "attach $busid from ${ip}:${p}: $out" }
		$last[$key] = $out
	}
}

$ip = $null
$seen = @()
Say "started: $Server port $Port, and Moonlight USBridge streaming from here"
while ($true) {
	if (-not ($ip -and (Reachable $ip $Port))) {
		$ip = Address  # new or changed address, or the Pi is down
		if ($ip -and -not (Reachable $ip $Port)) { $ip = $null }
	}
	if ($ip) { Attach-From $ip $Port }
	$exporters = @(Exporters)
	foreach ($e in $exporters) {
		if ($seen -notcontains $e) { Say "Moonlight USBridge at $e" }
		$host_, $p = $e -split ':'
		Attach-From $host_ ([int]$p)
	}
	$seen = $exporters
	if ($Once) { break }
	Start-Sleep -Seconds 2
}
