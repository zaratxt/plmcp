# Aggiunge (o modifica) un'istanza Aras MCP e la registra in Claude Code (scope utente).
# Finestra: nome istanza, URL del server MCP (<base Aras>/ai/mcp), database, client secret.
# Il secret viene cifrato con DPAPI in %USERPROFILE%\.aras-mcp\<istanza>\secret.dat.
#
#   aras-mcp-add.ps1                         nuova istanza (finestra)
#   aras-mcp-add.ps1 -Instance <nome>        modifica istanza esistente (es. cambiare il secret)
#   <secret> | aras-mcp-add.ps1 -Instance <nome> -McpUrl <url> [-Database <db>] -NoGui -SecretStdin
#                                            senza finestra, secret letto da stdin (non dagli argomenti)
#   aras-mcp-add.ps1 -Instance <nome> -McpUrl <url> -NoGui
#                                            senza finestra, mantiene il secret.dat gia' presente
param(
    [string]$Instance,
    [string]$McpUrl,
    [string]$Database,
    [string]$SecretHeader = 'X-Aras-Mcp-Secret',
    [switch]$NoGui,
    [switch]$SecretStdin
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'aras-mcp-common.ps1')

# Validazione e salvataggio. Ritorna un messaggio di esito o lancia un'eccezione con un testo per l'utente.
function Save-Instance([string]$name, [string]$url, [string]$db, [string]$secret) {
    if (-not (Test-InstanceName $name)) { throw 'Nome istanza non valido: usa lettere, numeri, - e _ (max 40).' }
    $base = Get-ArasBaseFromMcpUrl $url
    if (-not $base) { throw 'URL non valido: deve essere del tipo https://server/<app>/ai/mcp' }
    try { $ep = Resolve-ArasEndpoints $base } catch { throw "Aras non raggiungibile su $base ($($_.Exception.Message))" }
    if (-not $db) {
        if ($ep.databases.Count -eq 1) { $db = $ep.databases[0] }
        elseif ($ep.databases.Count -gt 1) { throw "Scegli il database: $($ep.databases -join ', ')" }
        else { throw 'Database non rilevato: indicalo a mano.' }
    }

    $dir = Get-InstanceDir $name
    $secretFile = Join-Path $dir 'secret.dat'
    if (-not $secret) {
        if (Test-Path $secretFile) { $secret = Unprotect-Text (Get-Content $secretFile -Raw) }
        else { throw 'Inserisci il client secret.' }
    }

    $old = Get-InstanceConfig $name
    $cfg = [ordered]@{
        mcp_url       = $url.Trim().TrimEnd('/')
        aras_base     = $base
        oauth_url     = $ep.oauth
        database      = $db
        secret_header = $SecretHeader
    }
    # Se cambia il server, il vecchio login non vale piu'
    if ($old -and ($old.oauth_url -ne $cfg.oauth_url -or $old.database -ne $db)) {
        Remove-Item (Join-Path $dir 'token.dat') -ErrorAction SilentlyContinue
    }
    Save-InstanceConfig $name $cfg

    # Verifica secret (possibile solo se c'e' gia' un login valido)
    $verified = $false
    try { $tok = Get-ArasAccessToken $name } catch { $tok = $null }
    if ($tok) {
        $res = Test-ArasMcp $cfg.mcp_url @{ Authorization = "Bearer $tok"; $SecretHeader = $secret }
        if ($res -eq 'unauthorized') { throw 'Il server risponde 401: secret errato.' }
        $verified = ($res -eq 'ok')
    }
    Protect-Text $secret | Set-Content $secretFile

    Install-ArasMcpBin $PSScriptRoot
    Register-ArasMcpServer $name $cfg.mcp_url

    $v = if ($verified) { 'Secret verificato.' } else { 'Secret salvato (si verifica dopo il login Aras).' }
    "Istanza '$name' registrata in Claude Code (database $db). $v"
}

if ($NoGui) {
    if (-not $Instance -or -not $McpUrl) {
        $cfg = if ($Instance) { Get-InstanceConfig $Instance } else { $null }
        if (-not $cfg) { throw '-NoGui richiede -Instance e -McpUrl' }
        $McpUrl = $cfg.mcp_url; if (-not $Database) { $Database = $cfg.database }
    }
    $secret = $null
    if ($SecretStdin) { $secret = ([Console]::In.ReadToEnd()).Trim() }
    try { Save-Instance $Instance $McpUrl $Database $secret }
    catch { [Console]::Error.WriteLine("ARAS_ADD_FAILED: $($_.Exception.Message)"); exit 1 }
    return
}

# --- Finestra ---
$lockFile = Join-Path $ArasMcpRoot 'add.lock'
New-Item -ItemType Directory -Force $ArasMcpRoot | Out-Null
if ((Test-Path $lockFile) -and ((Get-Date) - (Get-Item $lockFile).LastWriteTime).TotalMinutes -lt 10) { exit 0 }
Set-Content $lockFile $PID

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace ArasMcp -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
[Windows.Forms.Application]::EnableVisualStyles()

try {
    $existing = if ($Instance) { Get-InstanceConfig $Instance } else { $null }

    $form = New-Object Windows.Forms.Form
    $form.Text = if ($existing) { "Aras MCP - istanza $Instance" } else { 'Aras MCP - aggiungi istanza' }
    $form.Size = New-Object Drawing.Size(520, 330)
    $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.TopMost = $true

    $y = 15
    function Add-Field([string]$label, [switch]$Password) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $label; $l.Location = New-Object Drawing.Point(15, ($script:y + 3)); $l.Size = New-Object Drawing.Size(130, 20)
        $form.Controls.Add($l)
        $t = New-Object Windows.Forms.TextBox
        $t.Location = New-Object Drawing.Point(150, $script:y); $t.Size = New-Object Drawing.Size(340, 24)
        if ($Password) { $t.UseSystemPasswordChar = $true }
        $form.Controls.Add($t)
        $script:y += 34
        $t
    }

    $txtName = Add-Field 'Nome istanza'
    $txtUrl  = Add-Field 'URL server MCP'
    $l = New-Object Windows.Forms.Label
    $l.Text = 'Database'; $l.Location = New-Object Drawing.Point(15, ($y + 3)); $l.Size = New-Object Drawing.Size(130, 20)
    $form.Controls.Add($l)
    $cmbDb = New-Object Windows.Forms.ComboBox
    $cmbDb.Location = New-Object Drawing.Point(150, $y); $cmbDb.Size = New-Object Drawing.Size(340, 24)
    $form.Controls.Add($cmbDb); $y += 34
    $txtSecret = Add-Field 'Client secret' -Password

    $hint = New-Object Windows.Forms.Label
    $hint.Location = New-Object Drawing.Point(150, $y); $hint.Size = New-Object Drawing.Size(340, 34)
    $hint.ForeColor = 'Gray'
    $hint.Text = "Es. URL: https://server/<app>/ai/mcp. Database: lascia vuoto per rilevarlo."
    $form.Controls.Add($hint); $y += 38

    $status = New-Object Windows.Forms.Label
    $status.Location = New-Object Drawing.Point(15, $y); $status.Size = New-Object Drawing.Size(475, 40)
    $form.Controls.Add($status)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'Salva'; $ok.Location = New-Object Drawing.Point(320, 250); $ok.Size = New-Object Drawing.Size(80, 28)
    $form.Controls.Add($ok); $form.AcceptButton = $ok
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Annulla'; $cancel.Location = New-Object Drawing.Point(410, 250); $cancel.Size = New-Object Drawing.Size(80, 28)
    $cancel.DialogResult = 'Cancel'
    $form.Controls.Add($cancel); $form.CancelButton = $cancel

    if ($Instance) { $txtName.Text = $Instance }
    if ($existing) {
        $txtName.ReadOnly = $true
        $txtUrl.Text = $existing.mcp_url
        $cmbDb.Text = $existing.database
        $hint.Text = 'Lascia vuoto il secret per mantenere quello salvato.'
    } elseif ($McpUrl) { $txtUrl.Text = $McpUrl }

    $ok.Add_Click({
        $status.ForeColor = 'Black'; $status.Text = 'Verifica in corso...'; $form.Refresh()
        try {
            $msg = Save-Instance $txtName.Text.Trim() $txtUrl.Text.Trim() $cmbDb.Text.Trim() $txtSecret.Text.Trim()
        } catch {
            $status.ForeColor = 'DarkRed'; $status.Text = $_.Exception.Message
            if ($_.Exception.Message -like 'Scegli il database:*') {
                $cmbDb.Items.Clear()
                ($_.Exception.Message -replace '^Scegli il database:\s*', '') -split ',\s*' | ForEach-Object { [void]$cmbDb.Items.Add($_) }
                $cmbDb.DroppedDown = $true
            }
            return
        }
        [Windows.Forms.MessageBox]::Show("$msg`n`nTorna a Claude Code: chiedi il login su '$($txtName.Text.Trim())' e il collegamento del server.", 'Aras MCP') | Out-Null
        $form.DialogResult = 'OK'; $form.Close()
    })

    # Se il processo e' stato avviato nascosto, il primo ShowWindow eredita SW_HIDE: forziamo la visualizzazione
    $form.Add_Load({
        $form.BeginInvoke([Action]{
            [ArasMcp.Win32]::ShowWindow($form.Handle, 5) | Out-Null
            [ArasMcp.Win32]::SetForegroundWindow($form.Handle) | Out-Null
            $form.Activate()
            if ($existing) { $txtSecret.Focus() } else { $txtName.Focus() }
        }) | Out-Null
    })
    [void]$form.ShowDialog()
} finally {
    Remove-Item $lockFile -ErrorAction SilentlyContinue
}
