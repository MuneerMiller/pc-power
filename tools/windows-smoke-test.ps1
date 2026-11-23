# Installs PC Power on a real Windows machine as a service (with power actions switched to "log only"),
# checks that everything works, then uninstalls. Run from the windows-app folder, as administrator.
$ErrorActionPreference = 'Stop'
$script:failed = $false
function Check($name, $cond) { if ($cond) { "PASS  $name" } else { "FAIL  $name"; $script:failed = $true } }
function Info($name, $value) { "INFO  ${name}: $value" }

# A portable copy's settings, to check that installing carries them over.
$portable = Join-Path $env:TEMP 'pcpower-portable'
New-Item -ItemType Directory -Force $portable | Out-Null
'{"name":"Carry test","schedules":[{"id":"carry1","action":"shutdown","time":"23:10","days":[1],"enabled":true}]}' | Set-Content -Encoding ascii "$portable\config.json"
$p = Start-Process .\PCPower.exe -ArgumentList '--install', '--quiet', '--dry-run', '--for-user', "$env:USERDOMAIN\$env:USERNAME", '--from-dir', $portable -Wait -PassThru
Check 'installer finished without error' ($p.ExitCode -eq 0)
Start-Sleep 6
$data = "$env:ProgramData\PCPower"
if (Test-Path "$data\install.log") { Get-Content "$data\install.log" | ForEach-Object { "      install.log: $_" } }

$svc = Get-Service PCPower -ErrorAction SilentlyContinue
Check 'service exists and is running' ($svc -and $svc.Status -eq 'Running')
Check 'service starts with Windows' ($svc -and $svc.StartType -eq 'Automatic')
Check 'program copied to Program Files' (Test-Path "$env:ProgramFiles\PC Power\PCPower.exe")
Check 'listed in Installed apps' (Test-Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PCPower')
Check 'Start menu shortcut' (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\PC Power.lnk")
$fw = netsh advfirewall firewall show rule name="PC Power" | Out-String
Check 'firewall rule for private networks' ($fw -match 'PC Power' -and $fw -notmatch 'Public')
$acl = icacls "$data\local.key" | Out-String
Check 'local key not readable by ordinary users' ($acl -notmatch 'BUILTIN\\Users' -and $acl -notmatch 'Everyone')

$port, $key = (Get-Content "$data\local.key").Split(':')
$h = @{ 'X-PCPower' = '1'; 'X-PCPower-Key' = $key }
$base = "http://127.0.0.1:$port"
function Api($method, $path, $body) {
  if ($body) { Invoke-RestMethod "$base$path" -Method $method -Headers $h -ContentType 'application/json' -Body ($body | ConvertTo-Json -Compress) }
  else { Invoke-RestMethod "$base$path" -Method $method -Headers $h }
}
$st = Api Get '/api/status'
Check 'status answers' ($st.app -eq 'pcpower')
Check 'portable settings carried over on install' (($st.schedules | Where-Object id -eq 'carry1') -and $st.name -eq 'Carry test')
$ver = (Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\PCPower').DisplayVersion
Info 'installed version' $ver

# Can phones reach this PC? Network type and firewall checks, and their one-click fixes.
$loc = Api Get '/api/local?fresh=1'
Info 'network check' ($loc.network | ConvertTo-Json -Compress)
Check 'network type detected' ($loc.network.category -in @('public', 'private', 'domain'))
Check 'firewall rule seen' ($loc.network.firewall -eq 'ok')
netsh advfirewall firewall delete rule name="PC Power" | Out-Null
$loc = Api Get '/api/local?fresh=1'
Check 'missing firewall rule detected' ($loc.network.firewall -eq 'missing' -and $loc.network.problem -in @('firewall', 'public'))
Api Post '/api/local/network-fix' @{ fix = 'firewall' } | Out-Null
Check 'firewall rule repaired' ((netsh advfirewall firewall show rule name="PC Power" | Out-String) -match 'PC Power')
if ($loc.network.category -eq 'public') {
  Api Post '/api/local/network-fix' @{ fix = 'private' } | Out-Null
  $loc = Api Get '/api/local?fresh=1'
  Check 'public network switched to private' ($loc.network.category -eq 'private' -and -not $loc.network.problem)
}
$icon = Invoke-WebRequest "$base/icon-192.png" -UseBasicParsing
Check 'window icon served' ($icon.StatusCode -eq 200 -and $icon.Headers['Content-Type'] -eq 'image/png')
Check 'network card found' ($st.mac -match '^([0-9a-f]{2}:){5}[0-9a-f]{2}$')
Info 'connection' $st.connection
Info 'can hibernate' $st.canHibernate
$refused = $false
try { Invoke-RestMethod "$base/api/status" -Headers @{ 'X-PCPower' = '1' } | Out-Null } catch { $refused = $true }
Check 'local API refuses a caller without the key' $refused

# Phones: encrypted port
$hello = curl.exe -sk https://127.0.0.1:8787/api/hello
Check 'phone port answers over TLS' ($hello -match 'pcpower')
$old = curl.exe -sk --tls-max 1.2 https://127.0.0.1:8787/api/hello
Check 'TLS 1.2 is refused' (-not $old)
$noToken = curl.exe -sk -o NUL -w '%{http_code}' https://127.0.0.1:8787/api/status
Check 'unpaired caller refused' ($noToken -eq '401')

# Power actions (dry run) and the rules about clashes
$r = Api Post '/api/power' @{ action = 'shutdown' }
Check 'shut down starts a 60 second countdown' ($r.message -match '60 seconds')
$r = Api Post '/api/power' @{ action = 'cancel' }
Check 'countdown can be cancelled' ($r.message -match 'cancelled')
$lockRefused = $false
try { Api Post '/api/power' @{ action = 'lock' } | Out-Null } catch { $lockRefused = $true }
Info 'lock with no tray helper running' $(if ($lockRefused) { 'refused, as intended' } else { 'accepted (a helper is running)' })

# Scheduled turn-on: does Windows accept a wake timer from the service?
$when = (Get-Date).AddMinutes(40)
Api Post '/api/schedules' @{ action = 'wake'; time = $when.ToString('HH:mm'); date = $when.ToString('yyyy-MM-dd'); days = @() } | Out-Null
Start-Sleep 3
$st = Api Get '/api/status'
Check 'turn-on schedule stored' ($st.turnOn.next)
Info 'wake timer error from Windows' $(if ($st.turnOn.error) { $st.turnOn.error } else { 'none' })
Info 'powercfg /waketimers' ((powercfg /waketimers | Out-String).Trim())

# What the PC is doing, and the wake settings check
Info 'activity' ($st.activity | ConvertTo-Json -Compress)
Info 'powercfg /requests' ((powercfg /requests | Out-String).Trim() -replace "`r?`n", ' | ')
$w = Api Get '/api/local/wol?fresh=1'
Check 'wake settings can be read' ($w.supported -and -not $w.error)
Info 'wake settings' ($w | ConvertTo-Json -Compress -Depth 5)

# Timer, idle rule, days off, wake relay
$r = Api Post '/api/timer' @{ action = 'sleep'; minutes = 30 }
Check 'timer set' ($r.message -match '30 minutes')
Api Delete '/api/timer' | Out-Null
Api Put '/api/automation' @{ idle = @{ enabled = $true; minutes = 120; action = 'sleep' }; skipDates = @('2031-01-01') } | Out-Null
$st = Api Get '/api/status'
Check 'idle rule and days off saved' ($st.idle.enabled -and $st.skipDates -contains '2031-01-01')
$r = Api Post '/api/wake-peer' @{ mac = '3c:7c:3f:2a:9b:10'; name = 'Test PC' }
Check 'wake signal for another PC sent' ($r.ok)

"--- service log"
Get-Content "$data\pcpower.log" -Tail 25 | ForEach-Object { "      $_" }

# Restart survival: stop and start the service, settings must still be there
Restart-Service PCPower
Start-Sleep 5
$st = Api Get '/api/status'
Check 'settings survive a service restart' ($st.idle.enabled -and $st.schedules.Count -ge 1)

# Updating: installing again over the top (what "Update PC Power" does) keeps everything.
$p = Start-Process .\PCPower.exe -ArgumentList '--install', '--quiet', '--dry-run', '--for-user', "$env:USERDOMAIN\$env:USERNAME" -Wait -PassThru
Check 'update installs without error' ($p.ExitCode -eq 0)
Start-Sleep 6
$port, $key = (Get-Content "$data\local.key").Split(':')
$h = @{ 'X-PCPower' = '1'; 'X-PCPower-Key' = $key }
$st = Api Get '/api/status'
Check 'update keeps schedules and rules' ($st.idle.enabled -and ($st.schedules | Where-Object id -eq 'carry1'))
Check 'service running after update' ((Get-Service PCPower).Status -eq 'Running')

# Uninstall
$p = Start-Process "$env:ProgramFiles\PC Power\PCPower.exe" -ArgumentList '--uninstall', '--quiet' -Wait -PassThru
Check 'uninstaller finished without error' ($p.ExitCode -eq 0)
Start-Sleep 12
Check 'service removed' (-not (Get-Service PCPower -ErrorAction SilentlyContinue))
Check 'settings removed' (-not (Test-Path $data))
Check 'program folder removed' (-not (Test-Path "$env:ProgramFiles\PC Power"))
Check 'firewall rule removed' ((netsh advfirewall firewall show rule name="PC Power" | Out-String) -notmatch 'Rule Name')

if ($script:failed) { "`nSOME CHECKS FAILED"; exit 1 }
"`nALL CHECKS PASSED"
exit 0
