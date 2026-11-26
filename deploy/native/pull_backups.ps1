# Copies the VM's daily store backups (/var/backups/trion) to this PC, so a
# lost VM doesn't take the only copies with it. Keeps the newest $Keep files.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File deploy\native\pull_backups.ps1
#
# Registered as the "Trion backup pull" scheduled task (daily; runs at the next
# logon if the PC was off). Log: <Dest>\pull.log
param(
	[string]$VmHost = "opc@150.136.143.127",
	[string]$Key = "$env:USERPROFILE\Documents\Trion-Secrets\ssh-key-2026-11-22.key",
	[string]$Dest = "$env:USERPROFILE\Documents\Trion-Backups",
	[int]$Keep = 60
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $Dest | Out-Null
$log = Join-Path $Dest "pull.log"
$ssh = @("-o", "ConnectTimeout=30", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=accept-new", "-i", $Key)
try {
	# Backups are root-only on the VM: stage copies the login user can read.
	ssh @ssh $VmHost "rm -rf ~/backup-export && mkdir -m 700 ~/backup-export && sudo find /var/backups/trion -name 'trion-*.tgz' -exec install -o `$(id -un) -m 600 {} ~/backup-export/ \;"
	if ($LASTEXITCODE -ne 0) { throw "staging on the VM failed ($LASTEXITCODE)" }
	$have = @(Get-ChildItem $Dest -Filter "trion-*.tgz" | ForEach-Object Name)
	$list = ssh @ssh $VmHost "ls ~/backup-export"
	$new = 0
	foreach ($name in @($list)) {
		if ([string]::IsNullOrWhiteSpace($name) -or $have -contains $name) { continue }
		scp @ssh "${VmHost}:backup-export/$name" (Join-Path $Dest $name)
		if ($LASTEXITCODE -ne 0) { throw "download of $name failed" }
		$new++
	}
	ssh @ssh $VmHost "rm -rf ~/backup-export" | Out-Null
	Get-ChildItem $Dest -Filter "trion-*.tgz" | Sort-Object Name -Descending | Select-Object -Skip $Keep | Remove-Item
	Add-Content $log "$(Get-Date -Format s) ok: $new new, $(@(Get-ChildItem $Dest -Filter 'trion-*.tgz').Count) kept"
} catch {
	Add-Content $log "$(Get-Date -Format s) FAILED: $_"
	exit 1
}
