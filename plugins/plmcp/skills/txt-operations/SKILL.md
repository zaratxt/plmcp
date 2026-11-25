---
name: txt-operations
description: Collegarsi e usare uno o più server MCP Aras (istanze Aras con endpoint <base>/ai/mcp, autenticati con token OAuth Aras + client secret). Usare quando l'utente vuole aggiungere/elencare/rimuovere un'istanza Aras, fare login su un'istanza, interrogare o modificare dati Aras tramite MCP, quando i tool di un server Aras non sono disponibili, oppure quando il server risponde 401 / "not authenticated" / token scaduto.
---

# Server MCP Aras multi-istanza

`<SKILL_DIR>` = cartella base di questa skill (indicata quando la skill viene caricata). Gli script
sono in `<SKILL_DIR>\scripts`; quando un'istanza viene aggiunta vengono copiati anche in
`%USERPROFILE%\.aras-mcp\bin` (cartella stabile usata dai server registrati). Solo Windows.

Ogni istanza è un server MCP registrato in Claude Code (scope utente) con il nome scelto
dall'utente, es. `txt-operations`; i suoi tool si chiamano `mcp__<istanza>__<tool>`. Dati
dell'istanza in `%USERPROFILE%\.aras-mcp\<istanza>\` (config.json in chiaro; secret.dat e
token.dat cifrati DPAPI). Il server riceve `Authorization: Bearer <token Aras>` e il client secret
nell'header `X-Aras-Mcp-Secret`, forniti dall'headersHelper `aras-mcp-token.ps1 -Instance <istanza>`.
Il pulsante Authenticate di `/mcp` NON funziona per questi server.

Regole:
- Password e credenziali Aras le inserisce SEMPRE l'utente nella pagina di login Aras (o nel suo
  terminale): non chiederle in chat e non digitarle. Non stampare mai token.
- Il client secret è uno per server (condiviso, non personale): si può chiedere in chat (sezione 2).
  Non ripeterlo nelle risposte, non scriverlo in file in chiaro: passa solo dallo stdin dello script.
- Con più istanze, se la richiesta non dice su quale lavorare, chiedilo. Prima di ogni scrittura
  ripeti istanza e operazione e chiedi conferma.

## 1. Elencare le istanze

```powershell
. "<SKILL_DIR>\scripts\aras-mcp-common.ps1"; Get-Instances | Format-Table
```
Mostra nome, URL, database e se secret e login sono presenti.

Dopo un aggiornamento del plugin, ricopia gli script nella cartella stabile:
```powershell
. "<SKILL_DIR>\scripts\aras-mcp-common.ps1"; Install-ArasMcpBin "<SKILL_DIR>\scripts"
```

## 2. Aggiungere o modificare un'istanza

Raccogli i dati in chat, così funziona anche da telefono (Remote Control):
1. Con `AskUserQuestion` (risposta libera tramite "Other") o in chat chiedi:
   - nome dell'istanza (lettere, numeri, `-`, `_`; es. `txt-operations`, `clientex-prod`);
   - URL del server MCP, nella forma `https://server/<app>/ai/mcp`;
   - il client secret del server. Avvisa l'utente che passa dalla conversazione (resta nella
     cronologia della sessione); il secret è condiviso per server, non personale.
   Per una modifica (es. nuovo secret) basta il nome dell'istanza esistente.
2. Registra l'istanza (il secret arriva dallo stdin, non dagli argomenti):
   ```powershell
   '<secret>' | powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\aras-mcp-add.ps1" -Instance <istanza> -McpUrl "<url>" -NoGui -SecretStdin
   ```
   Per cambiare solo il secret di un'istanza esistente ometti `-McpUrl`; per cambiare solo l'URL
   ometti `-SecretStdin` (mantiene il secret salvato).
   Lo script rileva OAuth server e database Aras, verifica il secret se c'è già un login, salva
   config e secret cifrato, copia gli script in `bin` e registra il server con
   `claude mcp add-json <istanza> ... -s user`. Stampa `Istanza '<istanza>' registrata ...`.
3. Errori (stderr `ARAS_ADD_FAILED: ...`):
   - `Scegli il database: A, B` → chiedi quale e ripeti con `-Database <db>`;
   - `secret errato` → richiedi il secret;
   - `Aras non raggiungibile` / `URL non valido` → verifica l'URL con l'utente.
4. Nella risposta all'utente non ripetere il secret.

Alternativa solo al PC: finestra Windows
`Start-Process powershell -WindowStyle Hidden -ArgumentList '-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',"`"<SKILL_DIR>\scripts\aras-mcp-add.ps1`""`
(con `,'-Instance','<istanza>'` per modificare), se l'utente preferisce non scrivere il secret in chat.

Un server aggiunto durante la sessione potrebbe non essere visibile finché Claude Code non viene
riavviato: prova prima la riconnessione (sezione 5); se il server non compare, chiedi all'utente di
riavviare la sessione.

## 3. Verificare lo stato di un'istanza

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\aras-mcp-token.ps1" -Instance <istanza> | Out-Null; $LASTEXITCODE
```
Esito 0 = pronto (non stampare l'output: contiene token e secret). Altrimenti leggi lo stderr:
- `ARAS_INSTANCE_UNKNOWN` → istanza non configurata: sezione 2.
- `ARAS_SECRET_REQUIRED` → manca il secret: chiedilo e registralo come nella sezione 2.
- `ARAS_LOGIN_REQUIRED` → serve il login: sezione 4.

## 4. Login Aras dal browser (Authorization Code + PKCE)

1. Genera l'URL di login:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\aras-login.ps1" -Instance <istanza> -PrintAuthUrl
   ```
2. Aprilo nel browser dell'utente (Claude in Chrome) e chiedi all'utente di fare login nella pagina
   Aras. Se è già autenticato su quell'Aras il login può essere immediato.
   Da telefono: Chrome è sul PC, quindi l'utente non può digitare lì la password. Prova comunque il
   passo 3 direttamente: se Chrome ha ancora una sessione Aras attiva il codice arriva senza login.
   Altrimenti il login va fatto quando l'utente è al PC.
3. La pagina `<base>/Client/OAuth/RedirectCallback` del client web Aras consuma il codice e
   reindirizza al client, quindi l'URL nella barra NON contiene più il codice. Metodo affidabile:
   dopo il login dell'utente genera un NUOVO URL con `-PrintAuthUrl` ed esegui nella scheda (stessa
   origine dell'Aras) `fetch(url, {credentials:"include"})`: il fetch segue i redirect senza
   eseguire la pagina di callback e `new URL(r.url).searchParams` contiene `code` e `state`. Gli URL
   nell'output dei tool del browser sono REDACTED: restituisci il codice spaziato
   (`code.split("").join(" ")`) e ricomponilo. Il codice scade in pochi minuti: procedi subito.
4. Completa:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\aras-login.ps1" -Instance <istanza> -CallbackUrl "<base>/Client/OAuth/RedirectCallback?code=<code>&state=<state>"
   ```
   Deve stampare `Login OK`. Poi riconnetti (sezione 5).

Senza Claude in Chrome: l'utente esegue in un terminale suo (es. `run_in_terminal`)
`aras-login.ps1 -Instance <istanza> -Mode Password` e inserisce lì utente e password. Mai passare la
password come argomento.

## 5. Riconnettere il server (lo fa Claude)

Chiama `ToolSearch` con una query che contiene il nome dell'istanza (es. `txt-operations`,
max_results 20): forza la riconnessione e restituisce i tool `mcp__<istanza>__*`. Verifica con
il tool `session_status` dell'istanza. Se non si collega, ripeti la sezione 3 per capire cosa manca;
chiedi all'utente `/mcp` → Reconnect o il riavvio solo se dopo un paio di tentativi non funziona.

## 6. Rimuovere un'istanza

Chiedi conferma, poi:
```powershell
. "<SKILL_DIR>\scripts\aras-mcp-common.ps1"; (Invoke-ClaudeCli @('mcp','remove','<istanza>','-s','user')).Output
Remove-Item "$env:USERPROFILE\.aras-mcp\<istanza>" -Recurse
```

## 7. Errori comuni

| Sintomo | Azione |
|---|---|
| `State non corrispondente` | URL di un altro tentativo: rifai il login dal passo 1. |
| `(400) Bad Request` al completamento | codice scaduto o già usato: rifai dal passo 1. |
| login OK ma 401 dal server | secret errato: richiedilo e aggiornalo (sezione 2). |
| 401 a metà sessione | token scaduto: l'headersHelper lo rinnova alla connessione → riconnetti (sezione 5). |
| refresh fallito | refresh token scaduto o revocato: rifai il login. |
| `Invalid redirect_uri` nella pagina Aras | l'istanza non ha il client OAuth standard: usa `-Mode Password`. |

## 8. Usare i tool

- Tool tipici: `session_status`, `data_model_list_databases`, `data_model_search` (anche in
  italiano), `data_model_get_item_type_structure`, `data_model_get_method_code`, `api_get_items`
  (OData), `run_sql` (sola lettura, con permessi), `knowledge_search` / `get_knowledge_doc`;
  scritture: `api_apply_aml`, `api_create_item`, `api_call_method`, `insight_save`. Al primo uso
  leggi gli schemi dei tool dell'istanza: possono variare tra server.
- Le scritture restituiscono un `confirmationId` da usare solo dopo l'approvazione dell'utente: non
  inventarlo mai.
- Le operazioni girano con l'identità Aras dell'utente loggato su quell'istanza.
- Per AML e modello dati usa anche le skill `aras-aml` e `aras-programmer-s-guide`, se presenti.
