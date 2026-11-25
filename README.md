# plmcp – plugin Claude Code per server MCP Aras

Plugin per [Claude Code](https://code.claude.com) che collega Claude a **una o più istanze Aras**
che espongono un server MCP (endpoint `<base Aras>/ai/mcp`). Include la skill `txt-operations`, che
guida Claude nell'aggiunta delle istanze, nel login Aras e nell'uso dei tool.

> Requisiti: **Windows** (PowerShell 5.1, incluso in Windows), un account Aras su ogni istanza,
> l'URL del server MCP e il suo client secret (chiedili a chi gestisce il server).
> Consigliata l'estensione Claude in Chrome per il login dal browser.

## Installazione

In Claude Code:

```
/plugin marketplace add zaratxt/plmcp
/plugin install plmcp@plmcp
```

Poi esegui `/reload-plugins` (o riavvia Claude Code).

## Aggiungere un'istanza

Chiedi a Claude, ad esempio: *"aggiungi un'istanza Aras"*. Ti chiederà in chat:

1. un nome per l'istanza (es. `txt-operations`);
2. l'URL del server MCP;
3. il client secret del server (è uno per server; passa dalla conversazione e viene salvato
   cifrato sul PC).

Claude registra il server in Claude Code; riavvia la sessione per vederlo. Poi chiedi il login:
Claude apre la pagina di login Aras nel browser, tu inserisci le tue credenziali e il token viene
salvato. Funziona anche da telefono tranne il login, che richiede il browser del PC (salvo sessione
Aras già attiva in Chrome).

Puoi aggiungere quante istanze vuoi: ognuna ha i suoi tool (`mcp__<istanza>__...`), il suo login e
il suo secret.

## Dove sono i dati

`%USERPROFILE%\.aras-mcp\<istanza>\`: configurazione, secret e token (cifrati con DPAPI, leggibili
solo dal tuo utente Windows). La password Aras non viene mai salvata. Il token si rinnova da solo.

## Aggiornamenti

```
/plugin marketplace update plmcp
```

poi `/reload-plugins`. In alternativa attiva l'auto-update in `/plugin` → Marketplaces → `plmcp`.
