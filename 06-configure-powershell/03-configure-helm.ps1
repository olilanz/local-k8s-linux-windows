[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Purpose: Install Helm (if absent) and validate it against the current kubectl context on Windows.
# Preconditions: kubectl already configured (run 02-configure-kubectl.ps1 first).
# Invariants: Local CLI setup only; does not mutate cluster resources.
# Idempotency: Safe to rerun.
# Postconditions: helm command is installed and can access cluster metadata.

$ContextName = if ($env:HELM_CONTEXT_NAME) { $env:HELM_CONTEXT_NAME } else { 'kubernetes' }
$LocalKubeConfig = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { Join-Path $env:USERPROFILE '.kube\config' }

$HelmInstallDir = if ($env:HELM_INSTALL_DIR) { $env:HELM_INSTALL_DIR } else { Join-Path $env:USERPROFILE 'bin' }
$HelmExe = Join-Path $HelmInstallDir 'helm.exe'

function Write-Info([string]$Message) {
  Write-Host "[$(Get-Date -Format HH:mm:ss)] [INFO]  $Message"
}

function Fail([string]$Message) {
  throw "[$(Get-Date -Format HH:mm:ss)] [ERROR] $Message"
}

function Ensure-PathContains([string]$Directory) {
  $currentPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User)
  if ([string]::IsNullOrWhiteSpace($currentPath)) { $currentPath = '' }

  $parts = $currentPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  if ($parts -notcontains $Directory) {
    $newPath = if ($currentPath) { "$currentPath;$Directory" } else { $Directory }
    [Environment]::SetEnvironmentVariable('Path', $newPath, [EnvironmentVariableTarget]::User)
    $env:Path = "$env:Path;$Directory"
    Write-Info "Added '$Directory' to user PATH"
  }
}

function Ensure-HelmInstalled {
  if (Get-Command helm -ErrorAction SilentlyContinue) {
    $helmVersion = (& helm version --short 2>$null | Out-String).Trim()
    if (-not $helmVersion) { $helmVersion = (& helm version 2>$null | Out-String).Trim() }
    Write-Info "Helm already present: $helmVersion"
    return
  }

  Write-Info 'Helm not found — installing helm.exe'

  New-Item -ItemType Directory -Path $HelmInstallDir -Force | Out-Null

  $helmVersion = if ($env:HELM_VERSION) {
    $env:HELM_VERSION
  } else {
    (Invoke-RestMethod -Uri 'https://api.github.com/repos/helm/helm/releases/latest').tag_name
  }

  if (-not $helmVersion) {
    Fail 'Could not resolve Helm version. Set HELM_VERSION environment variable and retry.'
  }

  $helmVersion = $helmVersion.Trim()
  if (-not $helmVersion.StartsWith('v')) {
    $helmVersion = "v$helmVersion"
  }

  $zipName = "helm-$helmVersion-windows-amd64.zip"
  $downloadUrl = "https://get.helm.sh/$zipName"
  $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("helm-{0}.zip" -f [guid]::NewGuid())
  $tempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("helm-extract-{0}" -f [guid]::NewGuid())

  try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip
    Expand-Archive -Path $tempZip -DestinationPath $tempExtractDir -Force

    $extractedHelm = Join-Path $tempExtractDir 'windows-amd64\helm.exe'
    if (-not (Test-Path -LiteralPath $extractedHelm)) {
      Fail "helm.exe not found in archive from $downloadUrl"
    }

    Copy-Item -Path $extractedHelm -Destination $HelmExe -Force
    Ensure-PathContains -Directory $HelmInstallDir

    $installedVersion = (& $HelmExe version --short 2>$null | Out-String).Trim()
    if (-not $installedVersion) { $installedVersion = (& $HelmExe version 2>$null | Out-String).Trim() }
    Write-Info "Helm installed: $installedVersion"
  }
  finally {
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Fail 'kubectl is required before Helm setup. Run ./06-configure-powershell/02-configure-kubectl.ps1 first.'
}

if (-not (Test-Path -LiteralPath $LocalKubeConfig)) {
  Fail "Missing kubeconfig at '$LocalKubeConfig'. Run ./06-configure-powershell/02-configure-kubectl.ps1 first."
}

Ensure-HelmInstalled

$contexts = (& kubectl --kubeconfig "$LocalKubeConfig" config get-contexts -o name 2>$null)
if ($contexts -contains $ContextName) {
  Write-Info "Setting kubectl context '$ContextName' before Helm verification"
  & kubectl --kubeconfig "$LocalKubeConfig" config use-context "$ContextName" | Out-Null
}

Write-Info 'Verifying Helm can reach the active Kubernetes context'
& helm --kubeconfig "$LocalKubeConfig" list -A | Out-Null
if ($LASTEXITCODE -ne 0) {
  Fail 'Helm connectivity check failed. Ensure kubectl context is configured and cluster is reachable.'
}

Write-Info "Done. Helm is installed and verified against kubeconfig: $LocalKubeConfig"
