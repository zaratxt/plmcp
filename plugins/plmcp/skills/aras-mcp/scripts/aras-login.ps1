# Login Aras per un'istanza MCP. Salva access/refresh token cifrati (DPAPI); la password non viene mai salvata.
#
#   -Instance <nome>       istanza configurata con aras-mcp-add.ps1 (obbligatorio)
#   -Mode Browser          (default) OAuth Authorization Code + PKCE con la pagina di login Aras:
#                          apre il browser e chiede di incollare l'URL finale
#   -Mode Password         password grant (client IOMApp): utente e password chiesti a terminale
#   -PrintAuthUrl          genera PKCE, salva lo stato in sospeso e stampa solo l'URL di login
#   -CallbackUrl <url>     completa il login con l'URL di ritorno (usa lo stato in sospeso)
param(
    [Parameter(Mandatory = $true)][string]$Instance,
    [ValidateSet('Browser', 'Password')] [string]$Mode = 'Browser',
    [string]$ClientId = 'InnovatorClient',
    [switch]$PrintAuthUrl,
    [string]$CallbackUrl
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aras-mcp-common.ps1')

$cfg = Get-InstanceConfig $Instance
if (-not $cfg) { throw "Istanza '$Instance' non configurata. Aggiungila con aras-mcp-add.ps1" }
$oauth       = $cfg.oauth_url
$redirectUri = "$($cfg.aras_base)/Client/OAuth/RedirectCallback"
$scope       = 'openid Innovator offline_access'
$pendFile    = Join-Path (Get-InstanceDir $Instance) 'pending.dat'

function ConvertTo-B64Url([byte[]]$b) { [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function New-RandomB64Url { $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ConvertTo-B64Url $b }

function Get-QueryParam([string]$url, [string]$name) {
    foreach ($p in (([Uri]$url).Query.TrimStart('?') -split '&')) {
        $kv = $p -split '=', 2
        if ($kv[0] -eq $name) { return [Uri]::UnescapeDataString($kv[1]) }
    }
    $null
}

function Write-LoginOk($t) {
    $rt = if ($t.refresh_token) { 'si' } else { 'NO (rifare login alla scadenza)' }
    Write-Host "Login OK per '$Instance' (refresh token: $rt)"
}

function Complete-Login([string]$url) {
    if (-not (Test-Path $pendFile)) { throw 'Nessun login in sospeso: esegui prima con -PrintAuthUrl' }
    $p = Unprotect-Text (Get-Content $pendFile -Raw) | ConvertFrom-Json
    $err = Get-QueryParam $url 'error'
    if ($err) { throw "Login rifiutato: $err" }
    if ((Get-QueryParam $url 'state') -ne $p.state) { throw 'State non corrispondente: URL non valido o di un altro login' }
    $code = Get-QueryParam $url 'code'
    if (-not $code) { throw "Nell'URL non c'e' il parametro code" }
    $resp = Invoke-RestMethod -Method Post -Uri "$oauth/connect/token" -ContentType 'application/x-www-form-urlencoded' -Body @{
        grant_type = 'authorization_code'; client_id = $p.client_id; code = $code
        code_verifier = $p.verifier; redirect_uri = $p.redirect_uri
    }
    Remove-Item $pendFile -Force
    Write-LoginOk (Save-Tokens $Instance $resp $p.client_id $null)
}

if ($CallbackUrl) { Complete-Login $CallbackUrl; return }

if ($Mode -eq 'Password') {
    $user = Read-Host "Utente Aras ($Instance)"
    $sec = Read-Host 'Password Aras' -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $hash = -join ([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($plain)) | ForEach-Object { $_.ToString('x2') })
    $plain = $null
    $resp = Invoke-RestMethod -Method Post -Uri "$oauth/connect/token" -ContentType 'application/x-www-form-urlencoded' -Body @{
        grant_type = 'password'; client_id = 'IOMApp'; scope = 'Innovator offline_access'
        username = $user; password = $hash; database = $cfg.database
    }
    Write-LoginOk (Save-Tokens $Instance $resp 'IOMApp' $null)
    return
}

$verifier  = New-RandomB64Url
$challenge = ConvertTo-B64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
$state     = New-RandomB64Url
Protect-Text (@{ verifier = $verifier; state = $state; client_id = $ClientId; redirect_uri = $redirectUri } | ConvertTo-Json -Compress) | Set-Content $pendFile
$e = { param($v) [Uri]::EscapeDataString($v) }
$authUrl = "$oauth/connect/authorize?client_id=$(& $e $ClientId)&response_type=code&scope=$(& $e $scope)" +
           "&redirect_uri=$(& $e $redirectUri)&code_challenge=$challenge&code_challenge_method=S256&state=$state"

if ($PrintAuthUrl) { $authUrl; return }

Start-Process $authUrl
Write-Host 'Fai login nel browser. Prima che la pagina finale reindirizzi, copia l''URL completo dalla barra'
Write-Host 'indirizzi (contiene "code=") e incollalo qui. Se non ci riesci usa -Mode Password.'
Complete-Login ((Read-Host 'URL').Trim())
