# Funzioni comuni per i server MCP Aras multi-istanza. Da includere con: . "$PSScriptRoot\aras-mcp-common.ps1"
# Ogni istanza ha una cartella %USERPROFILE%\.aras-mcp\<istanza>\ con:
#   config.json  (mcp_url, aras_base, oauth_url, database, client_id, secret_header)
#   secret.dat   client secret cifrato DPAPI
#   token.dat    access/refresh token cifrati DPAPI
#   pending.dat  login PKCE in sospeso

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ArasMcpRoot = Join-Path $env:USERPROFILE '.aras-mcp'
$ArasMcpBin  = Join-Path $ArasMcpRoot 'bin'

function Protect-Text([string]$s) { ConvertTo-SecureString $s -AsPlainText -Force | ConvertFrom-SecureString }
function Unprotect-Text([string]$s) {
    $sec = ConvertTo-SecureString $s.Trim()
    [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

function Test-InstanceName([string]$n) { $n -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$' }
function Get-InstanceDir([string]$n) { Join-Path $ArasMcpRoot $n }

function Get-InstanceConfig([string]$n) {
    $f = Join-Path (Get-InstanceDir $n) 'config.json'
    if (-not (Test-Path $f)) { return $null }
    Get-Content $f -Raw | ConvertFrom-Json
}

function Save-InstanceConfig([string]$n, $cfg) {
    $d = Get-InstanceDir $n
    New-Item -ItemType Directory -Force $d | Out-Null
    ($cfg | ConvertTo-Json) | Set-Content (Join-Path $d 'config.json') -Encoding UTF8
}

function Get-Instances {
    if (-not (Test-Path $ArasMcpRoot)) { return @() }
    Get-ChildItem $ArasMcpRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'config.json') } | ForEach-Object {
        $c = Get-Content (Join-Path $_.FullName 'config.json') -Raw | ConvertFrom-Json
        [pscustomobject]@{
            name     = $_.Name
            mcp_url  = $c.mcp_url
            database = $c.database
            secret   = Test-Path (Join-Path $_.FullName 'secret.dat')
            login    = Test-Path (Join-Path $_.FullName 'token.dat')
        }
    }
}

# L'URL del server MCP e' <base Aras>/ai/mcp
function Get-ArasBaseFromMcpUrl([string]$url) {
    $u = $url.Trim().TrimEnd('/')
    if ($u -match '^(https?://.+?)/ai/mcp$') { return $Matches[1] }
    $null
}

# Trova OAuth server e database dell'istanza Aras
function Resolve-ArasEndpoints([string]$base) {
    $d = Invoke-RestMethod -Uri "$base/Server/OAuthServerDiscovery.aspx" -UseBasicParsing -TimeoutSec 20
    $oauth = ([string](@($d.locations)[0].uri)).TrimEnd('/')
    if (-not $oauth) { throw "OAuth server non trovato in $base/Server/OAuthServerDiscovery.aspx" }
    $dbs = @()
    try {
        [xml]$x = (Invoke-WebRequest -Uri "$base/Server/DBList.aspx" -UseBasicParsing -TimeoutSec 20).Content
        $dbs = @($x.DBList.DB | ForEach-Object { $_.id })
    } catch { }
    @{ oauth = $oauth; databases = $dbs }
}

function Save-Tokens([string]$n, $resp, [string]$clientId, [string]$fallbackRefresh) {
    $obj = [ordered]@{
        client_id     = $clientId
        access_token  = $resp.access_token
        refresh_token = $(if ($resp.refresh_token) { $resp.refresh_token } else { $fallbackRefresh })
        expires_at    = [DateTimeOffset]::UtcNow.AddSeconds([int]$resp.expires_in - 60).ToUnixTimeSeconds()
    }
    Protect-Text ($obj | ConvertTo-Json -Compress) | Set-Content (Join-Path (Get-InstanceDir $n) 'token.dat')
    $obj
}

# Ritorna un access token valido (rinnovandolo se scaduto) o lancia un'eccezione "ARAS_LOGIN_REQUIRED: ..."
function Get-ArasAccessToken([string]$n) {
    $cfg = Get-InstanceConfig $n
    $tokFile = Join-Path (Get-InstanceDir $n) 'token.dat'
    if (-not (Test-Path $tokFile)) { throw 'ARAS_LOGIN_REQUIRED: nessun token' }
    $t = Unprotect-Text (Get-Content $tokFile -Raw) | ConvertFrom-Json
    if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt [long]$t.expires_at) { return $t.access_token }
    if (-not $t.refresh_token) { throw 'ARAS_LOGIN_REQUIRED: token scaduto e senza refresh token' }
    try {
        $r = Invoke-RestMethod -Method Post -Uri "$($cfg.oauth_url)/connect/token" -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type = 'refresh_token'; client_id = $t.client_id; refresh_token = $t.refresh_token
        }
    } catch { throw "ARAS_LOGIN_REQUIRED: refresh fallito ($($_.Exception.Message))" }
    (Save-Tokens $n $r $t.client_id $t.refresh_token).access_token
}

# Prova il server MCP: 'ok', 'unauthorized' o 'error: ...'
function Test-ArasMcp([string]$url, [hashtable]$headers) {
    $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"aras-mcp","version":"1"}}}'
    $h = @{ Accept = 'application/json, text/event-stream' }
    foreach ($k in $headers.Keys) { $h[$k] = $headers[$k] }
    try {
        Invoke-WebRequest -Method Post -Uri $url -UseBasicParsing -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 20 | Out-Null
        'ok'
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { 'unauthorized' }
        else { "error: $($_.Exception.Message)" }
    }
}

# --- Registrazione del server in Claude Code (scope utente) ---

function Get-ClaudeExe {
    foreach ($c in @(Get-Command claude -All -ErrorAction SilentlyContinue)) {
        if ($c.Source -like '*.exe') { return $c.Source }
        $p = Join-Path (Split-Path $c.Source) 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (Test-Path $p) { return $p }
    }
    $p = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path $p) { return $p }
    throw 'claude.exe non trovato nel PATH'
}

function ConvertTo-WinArg([string]$s) {
    '"' + ([regex]::Replace($s, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' }) -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-ClaudeCli([string[]]$argv) {
    $psi = New-Object Diagnostics.ProcessStartInfo (Get-ClaudeExe)
    $psi.Arguments = ($argv | ForEach-Object { ConvertTo-WinArg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Code = $p.ExitCode; Output = $out.Trim() }
}

# Copia gli script in una cartella stabile (la cartella del plugin cambia a ogni aggiornamento)
function Install-ArasMcpBin([string]$sourceDir) {
    New-Item -ItemType Directory -Force $ArasMcpBin | Out-Null
    if ((Resolve-Path $sourceDir).Path -ne (Resolve-Path $ArasMcpBin).Path) {
        Copy-Item (Join-Path $sourceDir '*.ps1') $ArasMcpBin -Force
    }
}

function Register-ArasMcpServer([string]$n, [string]$url) {
    $helper = Join-Path $ArasMcpBin 'aras-mcp-token.ps1'
    $json = [ordered]@{
        type          = 'http'
        url           = $url
        headersHelper = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$helper`" -Instance $n"
    } | ConvertTo-Json -Compress
    Invoke-ClaudeCli @('mcp', 'remove', $n, '-s', 'user') | Out-Null
    $r = Invoke-ClaudeCli @('mcp', 'add-json', $n, $json, '-s', 'user')
    if ($r.Code -ne 0) { throw "Registrazione in Claude Code fallita: $($r.Output)" }
}
