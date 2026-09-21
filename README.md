# Cuicuit auf Proxmox LXC – Einzeiler-Installation

> **Hinweis: Das ist NICHT das Cuicuit-App-Repository.**
> Dieses Repo (`HatchetMan111/CuCuitCooking`) enthält **nur den
> Proxmox-LXC-Installer** für Cuicuit — keinen App-Code.
> Die eigentliche Anwendung liegt bei Upstream:
> `https://github.com/MadeInPierre/cuicuit`. Das Install-Script klont deren
> offizielles Repo direkt von GitHub in den Container.

Cuicuit („think about meals, not ingredients") läuft vollständig lokal
in einem unprivilegierten LXC-Container: SvelteKit-Frontend (Node 24,
Build mit `adapter-node`) plus **lokaler Supabase-Stack via Docker**
(Postgres + Auth + Storage, Migrationen und Seed kommen aus dem Repo),
Web UI auf Port **3000**, systemd-Services mit `Restart=always`,
Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `cuicuit` |
| Tech-Stack | SvelteKit 5 + Svelte 5 + Node 24 + Supabase (lokal, Docker) |
| Web UI | `http://<LXC-IP>:3000` (bind `0.0.0.0:3000` via `HOST`/`PORT`) |
| Health | `http://<LXC-IP>:3000/api/v1/openapi.json` (Fallback: `/`) |
| Supabase-Studio (lokal) | `http://<LXC-IP>:54323` |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 16 GB Disk (Supabase-Images + Node-Build + 20 MB Seed) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |

> **Alpha-Hinweis:** Upstream stuft Cuicuit als Alpha ein und bietet noch kein
> offizielles Self-Host-Docker an. Dieses Script baut den dokumentierten
> Dev-Stack (`supabase start` + `vite build`) produktionsnah nach. Bei
> Upstream-Brüchen (z. B. neue Pflicht-Env-Vars) Script erneut laufen lassen —
> es ist idempotent.

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

Einfach kopieren und auf dem Proxmox-Host als `root` einfügen
(Community-Scripts-Stil, keine weitere Datei nötig):

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CuCuitCooking/main/install/cuicuit.sh)"
```

Anpassungen wahlweise per Umgebungsvariable oder Flag:

```bash
CT_ID=101 CORES=2 RAM=4096 DISK=16 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CuCuitCooking/main/install/cuicuit.sh)"
bash cuicuit.sh --ctid 101 --cores 2 --memory 4096 --disk 16 --bridge vmbr0 --storage local-lvm
bash cuicuit.sh --debug   # = bash -x, maximale Fehlermeldungskette
```

Externes Supabase statt lokalem Docker-Stack (alle drei Pflicht):

```bash
CUICUIT_SUPABASE_URL=https://xyz.supabase.co \
CUICUIT_SUPABASE_ANON_KEY=eyJ... \
CUICUIT_SUPABASE_SERVICE_KEY=eyJ... \
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/CuCuitCooking/main/install/cuicuit.sh)"
```

Optionale Keys (LLM/Scraper, werden in die Container-`.env` übernommen):

```bash
MISTRAL_API_KEY=... GROQ_API_KEY=... LLM_PRIORITY=mistral,groq bash cuicuit.sh --ctid 101
```

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools, nimmt die nächste freie CT-ID,
2. erkennt RootFS-Storage (bevorzugt `local-lvm`), lädt das neueste
   `debian-12-standard`-Template falls nötig,
3. erstellt den LXC `cuicuit` (`onboot: 1`, unprivilegiert, `nesting=1` für Docker),
4. installiert im Container Docker, Node 24, klont `MadeInPierre/cuicuit`
   nach `/opt/cuicuit` (User `cuicuit`), startet den lokalen
   Supabase-Stack (`supabase start`, inkl. Migrationen + Seed),
5. füllt `/opt/cuicuit/.env` mit den Supabase-Keys (nur leere Werte),
   patcht `adapter-vercel` → `adapter-node`, baut (`vite build`),
   schreibt beide systemd-Units, `systemctl enable --now`,
6. verifiziert `systemctl is-active cuicuit` + HTTP-Check auf
   `localhost:3000/api/v1/openapi.json` und gibt die finale URL
   `http://<LXC-IP>:3000` aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active cuicuit = active).
[OK]    Web UI antwortet (HTTP-Check auf localhost:3000).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Cuicuit – Kitchen Companion (self-hosted, Alpha)
  Container    : CT 100 (Hostname: cuicuit, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 16 GB Disk
  Web UI       : http://192.168.1.100:3000
  Datenbank    : lokal im LXC (Supabase-Stack, Studio: http://192.168.1.100:54323)
  Root-Passwort: aB3... (nur jetzt angezeigt – sicher ablegen!)
  Service      : systemctl status cuicuit  (im Container via: pct enter 100)
  Update       : Skript erneut laufen lassen (idempotent)
  Deinstall    : pct stop 100 && pct destroy 100
  Reboot-Test  : pct reboot 100 && sleep 60 && curl -fs http://192.168.1.100:3000/api/v1/openapi.json
  Log          : /tmp/cuicuit-install-2026-....log
══════════════════════════════════════════════════════════
```

## 2. Reboot-Test (Reboot-sicher belegen)

Der Supabase-Stack braucht nach einem Reboot 30–60 s (Docker + Postgres +
Kong starten gestaffelt; `cuicuit.service` wartet via
`After=cuicuit-supabase.service`):

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active cuicuit cuicuit-supabase   # muss: active / active
curl -fs http://$(pct exec $CT -- ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1):3000/api/v1/openapi.json
pct config $CT | grep -i onboot                                # muss: onboot: 1
```

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
bash cuicuit.sh --ctid 100
# pullt Branch 'main' (reset --hard), baut nur bei neuer Rev neu,
# schreibt Units/.env-Defaults neu, danach systemctl restart.
```

Manuell im Container:

```bash
pct enter 100
cd /opt/cuicuit && git log --oneline -3
systemctl restart cuicuit && systemctl status cuicuit --no-pager --full
curl -fs http://127.0.0.1:3000/api/v1/openapi.json
```

Build erzwingen (z. B. nach manuellem `.env`-Edit mit neuen `PUBLIC_*`-Werten,
die zur Build-Zeit eingebettet werden):

```bash
pct exec 100 -- bash -c 'BUILD_FORCE=1 bash /tmp/cuicuit-setup.sh'
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
```

## 5. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/cuicuit-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `journalctl` beider Units,
  `systemctl status` – niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x cuicuit.sh --ctid 100
DEBUG=1 bash cuicuit.sh --ctid 100
# Log mitschicken:
tail -n 200 /tmp/cuicuit-install-*.log
pct exec 100 -- journalctl -u cuicuit --no-pager -n 100
pct exec 100 -- journalctl -u cuicuit-supabase --no-pager -n 50
```

## 6. Dateien in diesem Paket

```text
cuicuit-proxmox/                    # dieses Paket: NUR Proxmox-Installer, kein App-Code
├── install/cuicuit.sh              # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/cuicuit.service         # App-Unit (node /opt/cuicuit/build, Restart=always, After=network-online.target)
├── systemd/cuicuit-supabase.service# Stack-Unit (supabase start nach Reboot, RemainAfterExit)
└── README.md                       # diese Datei
```

`install/cuicuit.sh` bettet beide Unit-Vorlagen ein, damit der Einzeiler
ohne weitere Dateien auskommt.

## 7. Hinweise

- **Warum LXC statt VM:** nichts Kernel-/GPU-spezifisches — Node + Docker
  laufen in unprivilegierten LXC mit `nesting=1`. Keine VM nötig.
- **Warum 4 GB / 16 GB statt 1–2 GB / 4–8 GB:** der lokale Supabase-Stack
  (8+ Docker-Container) plus `npm ci` + `vite build` brauchen diese
  Reserven; darunter OOM killt den Build. Per `--memory`/`--disk` anpassbar.
- **Erstlauf dauert:** Docker-Images (Supabase, ~2 GB) + `npm ci` + Seed
  (20 MB) + Build → 10–25 Minuten je nach Host/Netz einplanen.
- **DHCP-Hinweis:** `PUBLIC_SUPABASE_URL` wird zur Build-Zeit mit der
  erkannten Container-IP eingebettet (Browser müssen Supabase direkt
  erreichen; `127.0.0.1` würde auf den Client zeigen). Ändert sich die
  Container-IP (neues DHCP-Lease), Installer einfach erneut laufen lassen —
  er erkennt die neue IP, schreibt `.env` neu und baut neu (idempotent).
  Für eine stabile URL DHCP-Reservierung oder statische IP einrichten.
- **`.env`-Regel:** gesetzte Werte werden nie überschrieben; nur leere
  (`PUBLIC_SUPABASE_URL=`, `...`) füllt der Installer. `PUBLIC_*`-Werte
  wirken erst nach Rebuild (`BUILD_FORCE=1`, siehe Kap. 3).
- **Upstream nutzt `adapter-vercel`:** der Installer installiert
  `@sveltejs/adapter-node` nach und patcht `svelte.config.js`
  (Backup: `svelte.config.js.proxmox-bak`; `git clean -fd` beim Update
  stellt Upstream-Stand wieder her, Patch läuft erneut).
- **Firewall:** Debian-Default hat keine aktive Firewall; falls `ufw`
  aktiv ist, gibt der Installer Port 3000 automatisch frei.
