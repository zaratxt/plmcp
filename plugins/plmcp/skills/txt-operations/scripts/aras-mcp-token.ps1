# headersHelper per Claude Code: stampa gli header HTTP (Bearer token Aras + client secret) per un'istanza.
# Registrato automaticamente da aras-mcp-add.ps1 come:  ... -File aras-mcp-token.ps1 -Instance <nome>
param([Parameter(Mandatory = $true)][string]$Instance)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aras-mcp-common.ps1')

function Write-Err([string]$m) { [Console]::Error.WriteLine($m) }

$cfg = Get-InstanceConfig $Instance
if (-not $cfg) {
    Write-Err "ARAS_INSTANCE_UNKNOWN: istanza '$Instance' non configurata. Aggiungila con $PSScriptRoot\aras-mcp-add.ps1"
    exit 1
}

$secretFile = Join-Path (Get-InstanceDir $Instance) 'secret.dat'
if (-not (Test-Path $secretFile)) {
    Write-Err "ARAS_SECRET_REQUIRED: client secret mancante per '$Instance'. Chiedi a Claude di configurarlo (skill txt-operations), poi riconnetti il server."
    exit 1
}

try { $token = Get-ArasAccessToken $Instance }
catch {
    Write-Err "$($_.Exception.Message). Esegui: $PSScriptRoot\aras-login.ps1 -Instance $Instance"
    exit 1
}

$header = if ($cfg.secret_header) { $cfg.secret_header } else { 'X-Aras-Mcp-Secret' }
$headers = [ordered]@{ Authorization = "Bearer $token" }
$headers[$header] = Unprotect-Text (Get-Content $secretFile -Raw)
$headers | ConvertTo-Json -Compress
