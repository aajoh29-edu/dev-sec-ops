<#
.SYNOPSIS
  Launch, stop, or reset the EEGR 580 Rocky Linux 9 lab container on Docker Desktop.

.EXAMPLE
  .\lab\run.ps1                 # build your workstation (if missing) + lab layer, then start
  .\lab\run.ps1 -Rebuild        # rebuild workstation and lab layer without cache, then start
  .\lab\run.ps1 -Shell          # open a shell as the lab user (LAB_USER) inside the container
  .\lab\run.ps1 -Down           # stop; keep volumes
  .\lab\run.ps1 -Reset          # stop and DELETE all lab volumes (keys, DB, audit log)
  .\lab\run.ps1 -ShowDockerRun  # print the equivalent single `docker run` command
#>
[CmdletBinding()]
param(
  [switch]$Rebuild, [switch]$Shell, [switch]$Down, [switch]$Reset, [switch]$ShowDockerRun
)
$ErrorActionPreference = 'Stop'
$LabDir  = $PSScriptRoot
$RepoDir = Split-Path $LabDir -Parent
$Compose = @('compose', '-f', (Join-Path $LabDir 'docker-compose.yml'))

# 1. Preconditions: Docker Desktop on the WSL2 backend (cgroup v2).
docker info --format '{{.OperatingSystem}} cgroup={{.CgroupVersion}}' | Write-Host
if ((docker info --format '{{.CgroupVersion}}') -ne '2') { throw 'cgroup v2 required (Docker Desktop WSL2 backend).' }

# 2. Load pinned versions into this process's environment (compose interpolation).
Get-Content (Join-Path $RepoDir 'versions.env') | Where-Object { $_ -match '^\s*[A-Z0-9_]+=' } | ForEach-Object {
  $k, $v = $_ -split '=', 2
  [Environment]::SetEnvironmentVariable($k.Trim(), $v.Trim(), 'Process')
}
if ($env:ROCKY_IMAGE -notmatch '@sha256:[0-9a-f]{64}$') { throw 'ROCKY_IMAGE is not digest-pinned. Run scripts/resolve-versions.sh and commit versions.env.' }
if (-not $env:LAB_USER)   { $env:LAB_USER = 'dev' }
if (-not $env:LAB_TARGET) { $env:LAB_TARGET = 'lab' }

# 2b. Your workstation image (target 'lab'): build it from its pinned source when missing.
function Build-Workstation {
  $ctx = $env:WORKSTATION_GIT_CONTEXT
  if (-not $ctx) { throw "Image '$($env:WORKSTATION_IMAGE)' not found and WORKSTATION_GIT_CONTEXT is empty in versions.env." }
    $buildArgs = @('build', '-t', $env:WORKSTATION_IMAGE, '--build-arg', "ROCKY_IMAGE=$($env:ROCKY_IMAGE)",
                 '--label', "org.opencontainers.image.source=$ctx")
  if ($ctx -match '^https://') {
    if ($ctx -notmatch '\.git#[0-9a-f]{40}(:|$)') { throw 'WORKSTATION_GIT_CONTEXT must pin a full 40-character commit SHA: https://github.com/<user>/<repo>.git#<sha>:<dir>' }
    if ($env:GIT_AUTH_TOKEN) { $buildArgs += @('--secret', 'id=GIT_AUTH_TOKEN,env=GIT_AUTH_TOKEN') }  # private repo
  } elseif (Test-Path $ctx) {
    $sha = (git -C $ctx rev-parse HEAD 2>$null)
    if (git -C $ctx status --porcelain 2>$null) { Write-Warning "Workstation folder has uncommitted changes; the image will not match commit $sha." }
    $buildArgs += @('--label', "org.opencontainers.image.revision=$sha")
  } else { throw "WORKSTATION_GIT_CONTEXT '$ctx' is neither a pinned GitHub URL nor an existing folder." }
  if ($Rebuild) { $buildArgs += @('--no-cache', '--pull') }
  Write-Host "Building workstation image $($env:WORKSTATION_IMAGE) from $ctx"
  docker @buildArgs $ctx
  if ($LASTEXITCODE -ne 0) { throw 'Workstation build failed.' }
}

# 3. Secrets: random, local, ACL'd to the current user only, never committed.
$SecretDir = Join-Path $LabDir 'secrets'
New-Item -ItemType Directory -Force -Path $SecretDir | Out-Null
function New-Secret([string]$Path) {
  if (Test-Path $Path) { return }
  $bytes = New-Object byte[] 24
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  [Convert]::ToBase64String($bytes).TrimEnd('=') | Set-Content -NoNewline -Encoding ascii $Path
  icacls $Path /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
  Write-Host "Created secret $Path"
}
New-Secret (Join-Path $SecretDir 'lab_user_password.txt')
New-Secret (Join-Path $SecretDir 'pg_user_password.txt')

if ($ShowDockerRun) {
@"
docker run -d --name rocky9-lab --hostname rocky9-lab ``
  --privileged --cgroupns=private --shm-size=2g --stop-signal SIGRTMIN+3 --stop-timeout 45 ``
  --tmpfs /run:rw,mode=0755 --tmpfs /run/lock:rw,mode=1777 --tmpfs /tmp:rw,mode=1777,exec ``
  -p 127.0.0.1:3390:3390 -p 127.0.0.1:8080:8080 -p 127.0.0.1:5432:5432 ``
  -v rocky9-home:/home -v rocky9-gnupg:/home/$($env:LAB_USER)/.gnupg -v rocky9-pgdata:/var/lib/pgsql ``
  -v rocky9-audit:/var/log/lab-audit -v rocky9-git:/srv/git -v rocky9-labci:/var/lib/labci ``
  -v rocky9-docker:/var/lib/docker -v rocky9-trivy-cache:/var/cache/scanners/trivy ``
  -v rocky9-grype-cache:/var/cache/scanners/grype ``
  --mount type=bind,src="$RepoDir",dst=/workspace-src,readonly ``
  --mount type=bind,src="$SecretDir\lab_user_password.txt",dst=/etc/lab/secrets/lab_user_password,readonly ``
  --mount type=bind,src="$SecretDir\pg_user_password.txt",dst=/etc/lab/secrets/pg_user_password,readonly ``
  eegr580/rocky9-lab:local /sbin/init
"@ | Write-Host
  return
}

if ($Reset) {
  $answer = Read-Host 'Delete ALL lab volumes (GPG keys, database, audit log, mock remote)? Type RESET'
  if ($answer -ne 'RESET') { Write-Host 'Aborted.'; return }
  docker @Compose down --volumes --remove-orphans; return
}
if ($Down)  { docker @Compose down; return }
if ($Shell) { docker exec -it -u $env:LAB_USER -w "/home/$($env:LAB_USER)" rocky9-lab bash -l; return }

if ($env:LAB_TARGET -eq 'lab') {
  docker image inspect $env:WORKSTATION_IMAGE *> $null
  if ($LASTEXITCODE -ne 0 -or $Rebuild) { Build-Workstation }
  Write-Host "Workstation image: $(docker image inspect $env:WORKSTATION_IMAGE --format '{{.Id}}')"
}
# The workstation image is local-only, so the lab layer is never built with --pull.
if ($Rebuild) { docker @Compose build --no-cache }
docker @Compose up -d --build

# 4. Wait for systemd and verify the loopback-only bindings.
for ($i = 0; $i -lt 60; $i++) {
  $state = (docker exec rocky9-lab systemctl is-system-running 2>$null)
  if ($state -in @('running', 'degraded')) { break }
  Start-Sleep -Seconds 2
}
Write-Host "systemd state: $state"
docker port rocky9-lab | ForEach-Object {
  if ($_ -notmatch '127\.0\.0\.1:') { throw "Non-loopback port binding detected: $_" }
  Write-Host "  $_"
}
docker exec rocky9-lab /opt/lab/scripts/bin/lab-doctor
Write-Host "RDP: mstsc /v:127.0.0.1:3390 (user $($env:LAB_USER); password in lab\secrets\lab_user_password.txt)"
Write-Host 'Next: .\lab\run.ps1 -Shell   then   setup-lab.sh && demo.sh'
