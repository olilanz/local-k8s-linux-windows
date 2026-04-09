[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Purpose: Install kubectl (if absent) and configure it on Windows by fetching
#          kubeconfig artifacts from the controller VM over SSH.
# Preconditions: OpenSSH client available; VM reachable via SSH and
#                01-build-cluster/08-access-artifacts.sh already executed on VM.
# Invariants: Artifact-driven only. Does not patch/rebuild kubeconfig from VM runtime assumptions.
# Idempotency: Safe to rerun; context is reconciled each run.
# Postconditions: kubectl installed and context "kubernetes" activated from fetched artifacts.

$ContextName = if ($env:KUBECTL_CONTEXT_NAME) { $env:KUBECTL_CONTEXT_NAME } else { 'kubernetes' }
$VmHost = if ($env:VM_HOST) { $env:VM_HOST } else { 'kubernetes' }
$VmUser = if ($env:VM_USER) { $env:VM_USER } else { $env:USERNAME }
$VmSudoPassword = if ($env:VM_SUDO_PASSWORD) { $env:VM_SUDO_PASSWORD } else { '' }
$RemoteArtifactDir = if ($env:REMOTE_ARTIFACT_DIR) {
  $env:REMOTE_ARTIFACT_DIR
} else {
  "/home/$VmUser/repos/local-k8s-linux-windows/01-build-cluster/artifacts"
}
$RemoteKubeconfigArtifact = if ($env:REMOTE_KUBECONFIG_ARTIFACT) {
  $env:REMOTE_KUBECONFIG_ARTIFACT
} else {
  "$RemoteArtifactDir/kubeconfig-controller-ip.yaml"
}
$RemoteWslEnvArtifact = if ($env:REMOTE_WSL_ENV_ARTIFACT) {
  $env:REMOTE_WSL_ENV_ARTIFACT
} else {
  "$RemoteArtifactDir/wsl.env"
}

$KubectlInstallDir = if ($env:KUBECTL_INSTALL_DIR) { $env:KUBECTL_INSTALL_DIR } else { Join-Path $env:USERPROFILE 'bin' }
$KubectlExe = Join-Path $KubectlInstallDir 'kubectl.exe'
$LocalKubeDir = Join-Path $env:USERPROFILE '.kube'
$LocalKubeConfig = Join-Path $LocalKubeDir 'config'

$TmpKubeconfig = [System.IO.Path]::GetTempFileName()
$TmpWslEnv = [System.IO.Path]::GetTempFileName()

function Write-Info([string]$Message) {
  Write-Host "[$(Get-Date -Format HH:mm:ss)] [INFO]  $Message"
}

function Fail([string]$Message) {
  throw "[$(Get-Date -Format HH:mm:ss)] [ERROR] $Message"
}

function Ensure-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Fail "Required command '$Name' was not found. Install OpenSSH Client and retry."
  }
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

function Invoke-SshCapture {
  param(
    [Parameter(Mandatory = $true)][string]$RemoteCommand,
    [Parameter(Mandatory = $true)][string]$OutputPath
  )

  $sshArgs = @(
    '-o', 'ConnectTimeout=10',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-l', $VmUser,
    $VmHost,
    $RemoteCommand
  )

  $output = & ssh @sshArgs 2>$null
  if ($LASTEXITCODE -eq 0) {
    Set-Content -Path $OutputPath -Value $output -Encoding UTF8 -NoNewline
    return $true
  }

  return $false
}

function Get-RemoteFile {
  param(
    [Parameter(Mandatory = $true)][string]$RemotePath,
    [Parameter(Mandatory = $true)][string]$LocalPath
  )

  if (Invoke-SshCapture -RemoteCommand "cat '$RemotePath'" -OutputPath $LocalPath) {
    return $true
  }

  if (Invoke-SshCapture -RemoteCommand "sudo -n cat '$RemotePath'" -OutputPath $LocalPath) {
    return $true
  }

  if (-not [string]::IsNullOrWhiteSpace($VmSudoPassword)) {
    $escaped = $VmSudoPassword.Replace("'", "'\''")
    if (Invoke-SshCapture -RemoteCommand "printf '%s\n' '$escaped' | sudo -S -p '' cat '$RemotePath'" -OutputPath $LocalPath) {
      return $true
    }
  }

  return $false
}

function Parse-EnvFileValue {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if (-not (Test-Path -LiteralPath $FilePath)) { return $null }

  foreach ($line in (Get-Content -Path $FilePath)) {
    if ($line -match '^\s*#') { continue }
    if ($line -match "^\s*$Key=(.*)$") {
      $value = $matches[1].Trim()
      $value = $value.Trim("'", '"')
      return $value
    }
  }

  return $null
}

function Ensure-KubectlInstalled {
  if ((Get-Command kubectl -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $KubectlExe -ErrorAction SilentlyContinue)) {
    $existingVersion = (& kubectl version --client 2>$null | Out-String).Trim()
    if (-not $existingVersion) { $existingVersion = (& kubectl version 2>$null | Out-String).Trim() }
    Write-Info "kubectl already present: $existingVersion"
    return
  }

  Write-Info 'kubectl not found in target install location — installing kubectl.exe'
  New-Item -ItemType Directory -Path $KubectlInstallDir -Force | Out-Null

  $stableVersion = (Invoke-RestMethod -Uri 'https://dl.k8s.io/release/stable.txt' -Method Get).Trim()
  if (-not $stableVersion) {
    Fail 'Could not resolve latest kubectl version from https://dl.k8s.io/release/stable.txt'
  }

  $downloadUrl = "https://dl.k8s.io/release/$stableVersion/bin/windows/amd64/kubectl.exe"
  Invoke-WebRequest -Uri $downloadUrl -OutFile $KubectlExe

  Ensure-PathContains -Directory $KubectlInstallDir
  Write-Info "kubectl installed at '$KubectlExe'"
  $installedVersion = (& $KubectlExe version --client 2>$null | Out-String).Trim()
  if (-not $installedVersion) { $installedVersion = (& $KubectlExe version 2>$null | Out-String).Trim() }
  Write-Info "kubectl version: $installedVersion"
}

function Merge-Kubeconfig {
  param(
    [Parameter(Mandatory = $true)][string]$ImportedKubeconfig,
    [Parameter(Mandatory = $true)][string]$TargetKubeconfig
  )

  New-Item -ItemType Directory -Path (Split-Path -Parent $TargetKubeconfig) -Force | Out-Null
  if (-not (Test-Path -LiteralPath $TargetKubeconfig)) {
    New-Item -ItemType File -Path $TargetKubeconfig -Force | Out-Null
  }

  $mergedPath = Join-Path ([System.IO.Path]::GetTempPath()) ("kubeconfig-merged-{0}.yaml" -f [guid]::NewGuid())
  try {
    $env:KUBECONFIG = "$TargetKubeconfig;$ImportedKubeconfig"
    & kubectl config view --flatten --merge | Set-Content -Path $mergedPath -Encoding UTF8
    Move-Item -Path $mergedPath -Destination $TargetKubeconfig -Force
  }
  finally {
    Remove-Item -LiteralPath $mergedPath -Force -ErrorAction SilentlyContinue
    Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
  }
}

try {
  Ensure-Command -Name 'ssh'

  Write-Info "Checking SSH connectivity to '$VmUser@$VmHost'"
  & ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -l $VmUser $VmHost true 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Fail "Cannot reach '$VmUser@$VmHost' via SSH. Ensure the VM is running and SSH key auth is configured."
  }

  Write-Info "Fetching kubeconfig artifact over SSH: $RemoteKubeconfigArtifact"
  if (-not (Get-RemoteFile -RemotePath $RemoteKubeconfigArtifact -LocalPath $TmpKubeconfig)) {
    Fail "Failed to read '$RemoteKubeconfigArtifact' from VM. Run ./01-build-cluster/08-access-artifacts.sh on the VM first."
  }

  & ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -l $VmUser $VmHost "test -f '$RemoteWslEnvArtifact'" 2>$null | Out-Null
  $isWslEnvPresent = ($LASTEXITCODE -eq 0)
  if ($isWslEnvPresent) {
    Write-Info "Fetching optional WSL env artifact over SSH: $RemoteWslEnvArtifact"
    [void](Get-RemoteFile -RemotePath $RemoteWslEnvArtifact -LocalPath $TmpWslEnv)
    $ctxFromEnv = Parse-EnvFileValue -FilePath $TmpWslEnv -Key 'DOCKER_CONTEXT_NAME'
    if (-not [string]::IsNullOrWhiteSpace($ctxFromEnv)) {
      $ContextName = $ctxFromEnv
      Write-Info "Using context name from artifact: $ContextName"
    }
  }

  if (-not (Get-Content -Path $TmpKubeconfig -Raw).Trim()) {
    Fail "Artifact '$RemoteKubeconfigArtifact' is empty"
  }

  Ensure-KubectlInstalled

  Write-Info "Merging fetched kubeconfig into '$LocalKubeConfig'"
  Merge-Kubeconfig -ImportedKubeconfig $TmpKubeconfig -TargetKubeconfig $LocalKubeConfig

  $importedContext = (& kubectl --kubeconfig "$TmpKubeconfig" config current-context).Trim()
  if (-not [string]::IsNullOrWhiteSpace($importedContext) -and $importedContext -ne $ContextName) {
    Write-Info "Renaming context '$importedContext' -> '$ContextName'"
    & kubectl --kubeconfig "$LocalKubeConfig" config rename-context "$importedContext" "$ContextName" 2>$null | Out-Null
  }

  Write-Info "Setting '$ContextName' as current context"
  & kubectl --kubeconfig "$LocalKubeConfig" config use-context "$ContextName" | Out-Null

  Write-Info 'Verifying API connectivity'
  & kubectl --kubeconfig "$LocalKubeConfig" cluster-info | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Fail 'kubectl cluster-info failed — check API server reachability and TLS trust.'
  }

  Write-Info 'Listing nodes'
  & kubectl --kubeconfig "$LocalKubeConfig" get nodes -o wide

  Write-Info "Done. kubectl context '$ContextName' is active and verified."
}
finally {
  Remove-Item -LiteralPath $TmpKubeconfig -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $TmpWslEnv -Force -ErrorAction SilentlyContinue
}
