<#
Purpose: Windows worker onboarding stage scaffold.
Preconditions: Controller token stage has produced shared token artifact.
Inputs:
  - TOKEN_IN (default: ./artifacts/k0s-worker-token)
Postconditions:
  - Confirms shared token is present and emits deterministic next actions.
#>

param(
  [string]$TokenIn = "./artifacts/k0s-worker-token"
)

$ErrorActionPreference = "Stop"

Write-Host "[INFO] Windows worker onboarding scaffold"
Write-Host "[INFO] Expected shared token path: $TokenIn"

if (-not (Test-Path -LiteralPath $TokenIn)) {
  throw "Shared worker token not found at '$TokenIn'. Run ./04-controller-token.sh first and transfer the token to this path."
}

Write-Host "[INFO] Shared worker token found."
Write-Host "[INFO] Next: implement Windows k0s worker install/join flow using this token."
