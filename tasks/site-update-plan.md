# Piano di aggiornamento periodico — www.massimoaria.com

> **Cos'è questo file.** Un runbook operativo per un agente Claude Code (o per me)
> che deve aggiornare periodicamente le statistiche di ricerca, la pagina
> pubblicazioni e i numeri della home. Contiene i vincoli invarianti, la
> procedura passo-passo e i comandi già verificati su questo repo.
>
> `tasks/` è escluso sia dal render (`!tasks/` in `_quarto.yml`) sia da git
> (`/tasks/` in `.gitignore`): questo file non finisce sul sito pubblicato **e
> non è versionato**. Esiste solo su questa macchina — se serve che sopravviva a
> un clone o che lo veda un'altra sessione, va tolto dal `.gitignore` e committato.

---

## 0. Checklist rapida (esecuzione settimanale)

```
[ ] git pull
[ ] Rendere il sito in LOCALE (mai affidarsi alla CI per Scholar) → §4
[ ] Verificare che Scholar abbia risposto: "ok": true in scholar_cache.json → §4.2
[ ] Controllare nuove pubblicazioni su OpenAlex/Scholar → §5
[ ] Se ci sono nuovi paper: inserirli nella sezione tematica giusta → §5.3
[ ] Controllare che le 3 voci fissate siano ancora in testa alle loro sezioni → §5.3.1
[ ] Se sono paper di management sanitario: sezione dedicata → §6
[ ] Verificare i numeri live nell'HTML renderizzato → §7
[ ] quarto render completo + verifica → §8
[ ] Commit con messaggio convenzionale + push → §8.3
```

---

## 1. Cadenza e trigger

| Cadenza | Chi | Cosa fa | Commit |
|---|---|---|---|
| **Mensile**, 1° del mese 06:00 UTC | GitHub Actions (`.github/workflows/update-statistics.yml`) | `quarto render` + push di `docs/` | `github-actions[bot]` — "monthly auto-build" |
| **Settimanale / on-demand** | Sessione Claude Code locale | Render locale con Scholar funzionante + eventuali nuove pubblicazioni | `Massimo Aria` — "weekly auto-build" |
| **Evento** (nuovo paper accettato/pubblicato) | Sessione Claude Code locale | §5 + §6 | messaggio descrittivo |

Deploy: GitHub Pages serve la cartella `docs/` del branch `main`
(workflow `pages-build-deployment`, parte da solo a ogni push).

---

## 2. Architettura dei dati — chi scrive cosa

```
                    ┌── index.qmd / it/index.qmd        (stat-strip + prosa)
_metrics.R ─────────┼── statistics.qmd / it/statistics.qmd  (card + grafici)
  │                 └── software.qmd / it/software.qmd   (installazioni bibliometrix)
  │
  ├── Google Scholar ──> scholar_cache.json   profilo, storico citazioni, n. pubblicazioni
  └── CRAN (cranlogs) ─> metrics_cache.json   totali download per pacchetto
```

**`_metrics.R` è la fonte unica di verità per ogni numero live del sito.**
Espone `metrics_scholar()`, `metrics_cran_total()`, i formattatori (`fmt_int`,
`fmt_compact`, `fmt_floor`) e la dateline (`metrics_year_roman()`,
`metrics_volume_roman()`). Contiene anche le costanti condivise `SCHOLAR_ID`,
`CRAN_PACKAGES`, `CRAN_SINCE`, `CAREER_START`.

Ogni sorgente remota viene interrogata **una volta per render**: le funzioni
hanno un TTL di 6 ore (`METRICS_TTL_HOURS`), quindi il primo dei sei documenti
scarica e gli altri cinque leggono da disco. Se la rete fallisce si degrada
all'ultimo valore buono in cache invece di stampare "N/A".

**Entrambe le cache vanno committate**: sono il canale con cui la build mensile
in CI riceve i dati che non riesce a scaricare da sola.

**Fatti da non dimenticare:**

- `execute-dir: project` in `_quarto.yml` → anche le pagine sotto `it/` risolvono
  `scholar_cache.json` e `publications.qmd` come path **dalla root del progetto**.
  Non aggiungere `../`.
- `it/publications.qmd` **non duplica** la bibliografia: legge `publications.qmd`,
  taglia il front matter e traduce solo i titoli di sezione con `gsub(..., fixed=TRUE)`.
  → **Ogni nuovo heading `##`/`###` in inglese va aggiunto alla lista di gsub**,
  altrimenti sulla pagina italiana compare in inglese. Vedi §6.4.

---

## 3. ⚠️ Vincolo critico — Google Scholar non risponde in CI

**Evidenza raccolta sul repo:** `scholar_cache.json` cambia in *tutti* i commit
locali ("weekly auto-build", firmati `Massimo Aria`) e in **nessuno** dei commit
di `github-actions[bot]` ("monthly auto-build"). Poiché il file viene riscritto
*solo se* `get_profile()` è andato a buon fine, la conclusione è che
Google Scholar blocca gli IP dei runner GitHub e in CI si cade sempre sul
ramo di fallback che legge la cache.

**Conseguenze operative:**

1. La build mensile in CI **aggiorna solo i download CRAN**. Citazioni e h-index
   restano congelati all'ultimo valore committato nella cache.
2. **Citazioni e h-index si aggiornano solo con un render locale.** Questo è il
   vero motivo per cui esiste il giro settimanale manuale — non è ridondanza.
3. Dopo il render locale **`scholar_cache.json` va sempre committato**, non solo
   `docs/`. È il canale con cui la CI riceve i dati Scholar.
4. Il campo `"ok"` di `scholar_cache.json` dice esplicitamente com'è andata
   l'ultima volta: `true` = Scholar ha risposto, `false` = si è usata la cache.
   Se dopo un render locale è `false`, **non committare come se fosse un
   aggiornamento**: segnalarlo e riprovare più tardi (vedi §4.2).

---

## 4. Runbook A — Aggiornamento statistiche

### 4.1 Render

Quarto non è nel PATH. Usare il binario di Positron:

```bash
export QUARTO=/Applications/Positron.app/Contents/Resources/app/quarto/bin/quarto
cd /Users/massimoaria/Dropbox/R/website
git pull
"$QUARTO" render
```

Il render completo copre `*.qmd` + `it/*.qmd` e riscrive `docs/`.

### 4.2 Verifica che Scholar abbia risposto

`_metrics.R` registra l'esito nella cache, quindi non serve dedurlo da un diff:

```bash
python3 -c "
import json; d=json.load(open('scholar_cache.json'))
print('ok        :', d['ok'])
print('fetched_at:', d['fetched_at'])
print('cites', d['profile']['total_cites'], '| h', d['profile']['h_index'], '| pubs', d['n_pubs'])
"
```

- **`ok: true`** e `fetched_at` di oggi → Scholar ha risposto, procedere.
- **`ok: false`** → Scholar ha rifiutato la richiesta e le pagine hanno pubblicato
  i valori vecchi presi dalla cache. Opzioni:
  a) riprovare dopo qualche ora / da rete diversa;
  b) aggiornare a mano `profile.total_cites`, `profile.h_index`,
     `profile.i10_index`, `n_pubs` e l'ultimo elemento di `cite_history` leggendoli
     dal profilo nel browser (`https://scholar.google.com/citations?user=Qu66YZQAAAAJ`),
     poi rifare il render;
  c) rimandare il giro settimanale — **non** committare spacciando dati vecchi per nuovi.

⚠️ **Attenzione al TTL.** Se hai già renderizzato meno di 6 ore fa,
`_metrics.R` riusa la cache senza andare in rete e `fetched_at` resta quello di
prima (`ok` resta `true`, correttamente: quei dati *sono* freschi). Per forzare
un download immediato, azzera il timestamp:

```bash
python3 -c "
import json
for f in ('scholar_cache.json','metrics_cache.json'):
    d=json.load(open(f)); d['fetched_at']='2000-01-01T00:00:00Z'
    json.dump(d, open(f,'w'), indent=2)
"
```

### 4.3 Sanity check sui numeri

| Controllo | Come |
|---|---|
| Citazioni monotone crescenti | `total_cites` non deve mai diminuire rispetto al commit precedente |
| Anno corrente parziale | l'ultimo elemento di `cite_history` è normale sia < dell'anno precedente fino a fine anno |
| Card statistics non "N/A" | `grep -c 'N/A' docs/statistics.html` deve essere 0 |
| Download CRAN presenti | `grep -o 'bibliometrix' docs/statistics.html \| wc -l` > 0 |

I pacchetti tracciati stanno in **un solo posto**: `CRAN_PACKAGES` in
`_metrics.R` (`bibliometrix, openalexR, dimensionsR, pubmedR, e2tree,
contentanalysis, tall`). **Un nuovo pacchetto CRAN si aggiunge lì e basta**:
grafici, card e home lo prendono da soli. Resta manuale solo la scheda
descrittiva in `software.qmd` + `it/software.qmd`.

### 4.4 Se cambia la palette

I colori dei grafici plotly sono costanti R hardcoded (`col_ink`, `col_accent`,
`col_teal`, …) nel chunk `setup`, **duplicate** in `statistics.qmd` e
`it/statistics.qmd`. Vanno cambiate in lockstep con `theme.scss`. La CSS da sola
non ricolora i grafici.

---

## 5. Runbook B — Aggiornamento pubblicazioni

### 5.1 Dove cercare i nuovi lavori

Fonte primaria consigliata: **OpenAlex** (scriptabile, senza chiave, e filtrabile
per ORCID — quindi già disambiguato).

- ORCID: `0000-0002-8517-9411` (verificato: rimanda a massimoaria.com)
- OpenAlex author: `A5069892096` (~238 works)

```bash
curl -s "https://api.openalex.org/works?filter=author.orcid:0000-0002-8517-9411,from_publication_date:2026-01-01&per-page=100&select=id,doi,title,publication_year,biblio,primary_location,authorships,type&mailto=ksynthsrl@gmail.com" \
| python3 -c "
import sys,json
d=json.load(sys.stdin)
for w in sorted(d['results'], key=lambda x:-(x['publication_year'] or 0)):
    src=((w.get('primary_location') or {}).get('source') or {}).get('display_name') or '—'
    b=w.get('biblio') or {}
    au='; '.join(a['author']['display_name'] for a in w.get('authorships',[]))
    print(f\"{w['publication_year']} | {src} | {w['title']}\n  {au}\n  {w.get('doi')} | vol {b.get('volume')} ({b.get('issue')}) pp {b.get('first_page')}-{b.get('last_page')}\n\")
"
```

Poi confrontare con quanto già presente:

```bash
grep -oE '10\.[0-9]{4,9}/[^"< ]+' publications.qmd | sort -u > /tmp/doi_site.txt
# diff manuale con i DOI restituiti da OpenAlex
```

Fonti secondarie: profilo Google Scholar (per lavori non ancora indicizzati in
OpenAlex, es. accettati/in press) e Crossref (`api.crossref.org`) per completare
volume/pagine mancanti.

### 5.2 ⚠️ Trappola di disambiguazione

Il profilo OpenAlex ha affiliazioni sporche (compaiono "Synlab Czech",
"Schlumberger (Ireland)", "INFN Napoli"): sono artefatti di parsing, **non**
errori di attribuzione — il filtro per ORCID resta affidabile. Ma attenzione a:

- **Due D'Aniello diversi**: *Luca* D'Aniello (bibliometria, management sanitario,
  co-autore abituale) vs *Biagio* D'Aniello (etologia, cognizione del cane,
  *Animal Cognition*). Non sono la stessa persona e i loro paper vanno in sezioni
  diverse — o non vanno affatto sul sito.
- Il record OpenAlex contiene un lavoro del **1971** (`[Clinical study of tuberous
  sclerosis]`): omonimo, scartare.

### 5.3 Come inserire una voce

Struttura di `publications.qmd` — **non modificarla**:

```
## Monographs                → lista numerata, entry separate da <br>
## Journal Articles
   ### Bibliometrics, Science Mapping and Text Analysis
   ### Statistics and Machine Learning
   ### Management in Health          ← nuova, vedi §6
   ### Tourism, Management, Transportation, and Social Sciences
```

Formato di una entry (markdown puro in lista numerata — **mai** componenti custom,
la numerazione visiva `01`, `02`… è generata in CSS da `theme.scss`):

```markdown
N. Cognome I., Cognome I., Aria M. (ANNO). **Titolo del paper**. *Rivista*, vol(iss), pp–pp, <a href="https://doi.org/DOI" target="_blank"> DOI: DOI</a>.
```

Regole:
- **Prima le voci fissate** della sezione (§5.3.1), poi tutte le altre in
  ordinamento **decrescente per anno**.
- Il DOI va sia nell'`href` sia nel testo del link (è la convenzione già in uso).
- Se il paper è *in press* / senza DOI: omettere il link, lasciare rivista in corsivo.
- Usare apostrofi tipografici (`’`) come nel resto del file per coerenza.

### 5.3.1 ⚠️ Voci fissate — non riordinare mai

Tre voci occupano una posizione **fissa**, decisa dall'autore. Non sono soggette
all'ordinamento per anno e **non vanno spostate** da un inserimento successivo,
da una rinumerazione o da un riordino automatico — nemmeno quando arriva un paper
più recente nella stessa sezione.

| Sezione | Pos. | Voce |
|---|---|---|
| `## Monographs` | **1** | Aria M. & Cuccurullo C. (2026). *Science Mapping Analysis — A primer with Biblioshiny*. McGraw-Hill, ISBN 978-88-386-2297-7 |
| `### Bibliometrics, Science Mapping and Text Analysis` | **1** | Aria M., Cuccurullo C. (2017). *bibliometrix: An R-tool for comprehensive science mapping analysis*. Journal of Informetrics, 11(4), 959–975 — DOI `10.1016/j.joi.2017.08.007` |
| `### Bibliometrics, Science Mapping and Text Analysis` | **2** | Aria M., Cuccurullo C., D'Aniello L., Spano M. (2026). *Biblioshiny and the SAAS Workflow: An integrated framework for transparent and reproducible science mapping*. Journal of Informetrics, 20(3), 101837 — DOI `10.1016/j.joi.2026.101837` |

Sono i lavori-bandiera dell'ecosistema bibliometrix/biblioshiny: la loro posizione
è una scelta editoriale, non un artefatto dell'ordinamento cronologico.
Nelle sezioni interessate l'anno decresce quindi **a partire dalla voce 2**
(Monographs) e **dalla voce 3** (Bibliometrics).

**Stato attuale: già corretto.** Le tre voci sono oggi nella posizione giusta —
questo vincolo è da *preservare*, non da applicare. Verifica rapida dopo ogni
modifica a `publications.qmd`:

```bash
# le prime voci di Monographs e di Bibliometrics, nell'ordine in cui compaiono
grep -n '^1\. \|^2\. ' publications.qmd | head -4
```

Atteso: `1.` di Monographs = *Science Mapping Analysis*; `1.` e `2.` di
Bibliometrics = *bibliometrix* e *Biblioshiny and the SAAS Workflow*.

**Igiene della numerazione.** I numeri sorgente sono attualmente duplicati in più
punti (nella sezione Bibliometrics: `3, 3, 4, 4, 4, 5…`; in Tourism: `5, 5`).
Markdown rinumera in output, quindi il sito è corretto, ma la fonte è confusa e
rende fragile l'inserimento automatico. **Alla prossima modifica sostanziale,
rinumerare le sezioni toccate.** Non fare una rinumerazione globale in un commit
di aggiornamento contenuti: farla in un commit dedicato. La rinumerazione deve
**rinumerare, non riordinare**: le voci fissate di §5.3.1 restano dove sono.

### 5.4 Propagazione italiana

Nessuna azione: `it/publications.qmd` rilegge il file inglese a ogni render.
**Unica eccezione**: nuovi heading → §6.4.

---

## 6. Runbook C — Nuova sezione «Management in Health»

### 6.1 Obiettivo

Aggiungere sotto `## Journal Articles` una sezione dedicata ai lavori di
**management, governance e politica sanitaria**, escludendo i paper clinici.

### 6.2 Criterio di inclusione / esclusione

**INCLUDERE** — il contributo primario riguarda organizzazione, governance,
performance, finanziamento, accesso o valutazione dei sistemi e delle aziende
sanitarie; l'unità di analisi è un'organizzazione, un sistema o una popolazione,
non un paziente.
Segnali: riviste tipo *Health Policy*, *Public Money & Management*, *MECOSAN*,
*Economic Modelling*, *Social Indicators Research*; termini come *hospital
configurations*, *academic health centers*, *healthcare governance*, *access to
care*, *CEO performance*.

**ESCLUDERE** — studi clinici, diagnostici, epidemiologici, odontoiatrici,
farmacologici o veterinari, anche quando figuro come statistico.
Cluster da escludere in blocco: burning mouth syndrome / oral lichen planus /
pemphigus / epidermolysis bullosa / xerostomia (gruppo SIPMO, riviste *Oral
Diseases*, *J Oral Pathol Med*, *Clin Oral Investig*, *J Oral Rehabil*); melanoma
dermoscopico; oncologia/endocrinologia; *Animal Cognition*.

**CASI DI CONFINE — decisione già presa:**

| Lavoro | Decisione |
|---|---|
| *IoT in healthcare: a scientometric analysis* (TFSC 2022) | **Resta** in Bibliometrics: il contributo primario è metodologico-scientometrico |
| *Mapping the evolution of gender dysphoria research* (Q&Q 2024) | **Resta** in Bibliometrics: bibliometria di un tema clinico, non management |
| *Predicting depression … E2Tree* (Annals of OR 2025) | **Resta** in Statistics & ML: il contributo è metodologico |
| *COVID-19 vaccine hesitancy* (Hum Vaccin Immunother 2021) | **Escluso**: salute pubblica/comportamentale, non management |
| *Global distribution of special needs dentistry across dental school curricula* (2024) | **Escluso**: ambito odontoiatrico |
| Monografia *Leading Change in Academic Health Science Centers* (2023) | **Resta** in `## Monographs` (è un libro), non duplicare |

Regola generale per i futuri dubbi: *se togliendo il contesto sanitario il paper
resterebbe un paper di metodo, va nella sezione di metodo; se resterebbe un paper
di gestione/organizzazione, va in Management in Health.*

### 6.3 Contenuto iniziale della sezione

**Da spostare** (già sul sito, oggi in sezione sbagliata — rimuovere dall'origine):

| Voce | Sezione attuale |
|---|---|
| Aria, Cuccurullo, D'Aniello, Spano (2026). *SciK-Health: an open-data dashboard…* — Quality and Quantity | Bibliometrics |
| D'Aniello L., Spano M., Cuccurullo C., Aria M. (2022). *Academic Health Centers' configurations…* — Health Policy | Bibliometrics |
| Belfiore A., Cuccurullo C., Aria M. (2022). *Financial configurations of Italian private hospitals…* — Health Policy | Tourism/Management |

**Da aggiungere** (presenti su OpenAlex, assenti dal sito — metadati già verificati
via API, ricontrollare comunque autori/pagine prima dell'inserimento):

1. Abatemarco A., Aria M., Beraldo S., Collaro M. (2024). **Measuring health care access and its inequality: A decomposition approach**. *Economic Modelling*, 132, 106659. DOI `10.1016/j.econmod.2024.106659`
2. Abatemarco A., Aria M., Beraldo S., Stroffolini F. (2020). **Measuring Disparities in Access to Health Care: A Proposal Based on an Ex-ante Perspective**. *Social Indicators Research*, 150(2), 549–568. DOI `10.1007/s11205-020-02305-y`
3. Aria M., Cuccurullo C., Sarto F. (2015). **Exploring healthcare governance literature: systematic review and paths for future research**. *MECOSAN*, 91, 61–80. DOI `10.3280/mesa2014-091004`
4. Caldarelli A., Fiondella C., Maffei M., Spanò R., Aria M. (2013). **CEO performance evaluation systems: empirical findings from the Italian health service**. *Public Money & Management*, 33(5), 369–376. DOI `10.1080/09540962.2013.817129`

**Opzionali** (contributi in atti, non articoli su rivista — includere solo se si
decide di aprire una sotto-voce "Conference proceedings", altrimenti omettere):
Cuccurullo, D'Aniello, Aria, Spano (2021) *Measuring the impact of healthcare
indicators on academic medical centers' scientific production*
(`10.36253/978-88-5518-461-8.31`); Aria, Cuccurullo, Gnasso (2021) *Supporting
decision-makers in healthcare domain* (`10.36253/978-88-5518-461-8.34`);
Fasanelli et al. (2017) *Humanisation of care pathways* (`10.1285/i20705948v10n2p485`).

### 6.4 ⚠️ Passo obbligatorio: traduzione dell'heading

Aggiungere il nuovo heading alla catena di `gsub` in `it/publications.qmd`
(dopo la riga che traduce "Statistics and Machine Learning"):

```r
body <- gsub("### Management in Health",
             "### Management Sanitario", body, fixed = TRUE)
```

Senza questa riga la pagina italiana mostra il titolo in inglese. Il TOC laterale
(`toc: true`) raccoglie il nuovo heading da solo, non serve altro.

### 6.5 Posizionamento

Inserire la nuova sezione **dopo** `### Statistics and Machine Learning` e
**prima** di `### Tourism, Management, Transportation, and Social Sciences`.
Il titolo dell'ultima sezione resta invariato: continua a contenere lavori di
management non sanitario (turismo, ospitalità, accounting).

---

## 7. Numeri live — cosa si aggiorna da solo e cosa no

Tutti i numeri che invecchiavano in silenzio sono ora calcolati a ogni render da
`_metrics.R`. **Non riscriverli a mano nei `.qmd`.**

| Valore | Dove appare | Fonte |
|---|---|---|
| N. pubblicazioni (`260+`) | stat-strip home + prosa, EN/IT | Scholar: voci con rivista, deduplicate per titolo normalizzato, arrotondate per difetto alla decina |
| Citazioni (`31,200+`) | stat-strip home; card statistics | Scholar `total_cites`, arrotondato per difetto al centinaio |
| H-index, i10-index | stat-strip home; card statistics | Scholar |
| Installazioni bibliometrix (`1.55M+`) | stat-strip home; prosa; scheda `software.qmd` EN/IT | `cranlogs`, totale dal 2015 |
| Totali download 7 pacchetti | card + grafici statistics | `cranlogs` |
| Anno in numeri romani (`MMXXVI`) | eyebrow del folio, EN/IT | `Sys.Date()` |
| `Vol.` del folio (`XX`) | eyebrow del folio, EN/IT | anno di carriera, inclusivo da `CAREER_START = 2007` |
| Anno di copyright | footer di ogni pagina | JavaScript lato client (`.js-year` in `lang-switch.html`); il markup porta l'anno di build come fallback senza JS |

L'arrotondamento per difetto (`fmt_floor`) esiste perché il `+` finale sia sempre
letteralmente vero: `264` pubblicazioni si mostrano come `260+`, mai `270+`.

**Cosa resta manuale:**

- **Palette dei grafici**: le costanti R (`col_ink`, `col_accent`, …) sono ancora
  duplicate nel chunk `setup` di `statistics.qmd` e `it/statistics.qmd`, e vanno
  cambiate in lockstep con `theme.scss` (§4.4).
- **Schede descrittive** dei pacchetti in `software.qmd` / `it/software.qmd`:
  testo e link. Solo il conteggio installazioni è dinamico.
- **`CAREER_START`** in `_metrics.R`: se cambia la convenzione del `Vol.`, si
  tocca lì.

---

## 8. Verifica e commit

### 8.1 Render

```bash
export QUARTO=/Applications/Positron.app/Contents/Resources/app/quarto/bin/quarto
"$QUARTO" render
```

Il render **deve** completare senza errori: la stessa build gira in CI e un
fallimento blocca l'auto-build mensile.

### 8.2 Controlli post-render

```bash
# nessun placeholder rimasto (né "N/A" né il trattino di fallback di fmt_*)
grep -c 'N/A\|N/D' docs/statistics.html docs/it/statistics.html
grep -o 'stat__num">[^<]*' docs/index.html   # 4 numeri, nessuno deve essere "—"

# la nuova sezione esiste in EN e in IT (tradotta)
grep -o 'Management in Health' docs/publications.html | head -1
grep -o 'Management Sanitario' docs/it/publications.html | head -1

# nessun heading inglese sfuggito alla traduzione
grep -oE '<h[23][^>]*>[^<]+' docs/it/publications.html

# smoke test in locale
python3 -m http.server 8765 --directory docs &
curl -s -o /dev/null -w "index:%{http_code} it:%{http_code} pubs:%{http_code} stats:%{http_code}\n" \
  http://localhost:8765/index.html http://localhost:8765/it/index.html \
  http://localhost:8765/publications.html http://localhost:8765/statistics.html
pkill -f "http.server 8765"
```

Verifica visiva (richiede il browser, non delegabile all'agente): stat-strip della
home, card della pagina statistics, switcher EN⇄IT che resta dentro `/it/`.

### 8.3 Commit

Committare **sorgenti + cache + docs** insieme:

```bash
git add scholar_cache.json metrics_cache.json publications.qmd it/publications.qmd docs/
git add _metrics.R index.qmd it/index.qmd statistics.qmd it/statistics.qmd software.qmd it/software.qmd  # se toccati
git commit -m "Update research statistics (weekly auto-build)"
git push
```

Convenzioni sui messaggi già in uso nel repo:

- solo metriche → `Update research statistics (weekly auto-build)`
- metriche + nuovi paper → `Add <descrizione> and refresh site statistics`
- riorganizzazione strutturale → messaggio descrittivo (es. `Add Management in Health section to publications`)

Dopo il push, `pages-build-deployment` pubblica in ~1 minuto. Controllo:

```bash
gh run list --limit 3
```

---

## 9. Invarianti — cose che rompono il sito

1. **Non cambiare la struttura di `publications.qmd`**: liste numerate markdown
   sotto heading `##`/`###`. La numerazione visiva è CSS (`counter-increment`),
   le voci in componenti custom la rompono.
2. **Non spostare le tre voci fissate** (§5.3.1): la monografia *Science Mapping
   Analysis* in posizione 1 delle Monographs, *bibliometrix* (JOI 2017) e
   *Biblioshiny and the SAAS Workflow* (JOI 2026) in posizione 1 e 2 di
   Bibliometrics. L'ordinamento per anno vale solo **sotto** di esse.
3. **Non duplicare la bibliografia in `it/publications.qmd`**: si auto-sincronizza.
   Ogni nuovo heading richiede però la sua riga di `gsub` (§6.4).
4. **Non aggiungere `../` ai path nelle pagine `it/`**: `execute-dir: project`.
5. **Costanti R dei colori duplicate** tra `statistics.qmd` e `it/statistics.qmd`:
   modificarle sempre in coppia. È l'unica duplicazione rimasta.
6. **Non reintrodurre numeri scritti a mano** nei `.qmd`: passano tutti da
   `_metrics.R` (§7). Un nuovo pacchetto CRAN si aggiunge a `CRAN_PACKAGES`,
   non alle singole pagine.
7. **Ogni pagina nuova** vuole la controparte in `it/` con `lang: it` nel front
   matter, e l'etichetta italiana nella mappa `LABELS` di `lang-switch.html`.
8. **Non committare un giro settimanale se `scholar_cache.json` non è cambiato**
   (§3, punto 4).
9. **Mai `dangerous-clean-slate: true`** in `deploy-netsons.yml`: cancellerebbe
   LimeSurvey e le altre applicazioni PHP che convivono con il sito sullo stesso
   hosting (§10.2).
10. **Il dominio non va puntato a GitHub Pages**: servirebbe solo file statici e
    manderebbe in 404 le applicazioni in sottocartella (§10.1).
11. `quarto` non è nel PATH → usare sempre il binario di Positron.

---

## 10. Hosting e pubblicazione

### 10.1 Com'è fatto

`www.massimoaria.com` **non** è il dominio di GitHub Pages (`cname: None`).
Il DNS punta a Netsons (`46.252.152.236`, zona gestita da `dns*.netsons.net`), e
sullo stesso hosting girano applicazioni PHP vive in sottocartelle:

| Percorso | Cos'è |
|---|---|
| `/limesurvey/` | installazione LimeSurvey (PHP 7.4, Apache) |
| `/irslab/` | Prenotazione IRS Lab (Aula C14 — DiSES) |
| `/dipeccellenza/` | form di candidatura Premialità Dipartimento di Eccellenza DISES |
| `/fondo_premiale/` | form Richiesta Contributo Fondo Premiale DISES |
| `/webmail/`, `/cpanel/` | scorciatoie del pannello di hosting |
| `/cgi-bin/`, `/data/` | esistono (403) |

**Per questo il dominio non può puntare a GitHub Pages**: Pages serve solo file
statici, non esegue PHP. Puntandogli `www` e l'apex, tutte quelle applicazioni
diventerebbero 404 e ogni link ai sondaggi già distribuito smetterebbe di
funzionare. Valutato e scartato ad agosto 2026.

La pubblicazione avviene quindi via **FTPS su Netsons**
(`.github/workflows/deploy-netsons.yml`), che carica `docs/` nella web root.
GitHub Pages resta attivo su `massimoaria.github.io/website/` come mirror.

Il workflow parte:

- a ogni **push su `main` che tocca `docs/**`** — cioè il giro settimanale locale;
- **chiamato da `update-statistics.yml`** dopo la build mensile. Serve la chiamata
  esplicita perché un push fatto con `GITHUB_TOKEN` non innesca altri workflow.

### 10.2 ⚠️ Regola di sicurezza del deploy

**Il deploy non deve mai toccare le sottocartelle delle applicazioni.** Due
garanzie indipendenti, in quest'ordine di importanza:

1. **`dangerous-clean-slate: false`** — l'action rimuove solo i file registrati
   nel proprio `.ftp-deploy-sync-state.json`. Tutto ciò che è già sul server e
   che non ha caricato lei è semplicemente invisibile, **comprese le cartelle che
   nessuno si è ricordato di elencare**. È questa la protezione vera.
2. La lista `exclude` nomina le applicazioni note. È documentazione e seconda
   rete di sicurezza, non il meccanismo primario.

**Non impostare mai `dangerous-clean-slate: true` su questo server**: cancellerebbe
LimeSurvey e i suoi dati. Quando compare una nuova applicazione, aggiungerla a
`exclude` — ma sappi che sarebbe comunque protetta dal punto 1.

### 10.3 Segreti da configurare

Su GitHub → Settings → Secrets and variables → Actions:

| Nome | Tipo | Valore |
|---|---|---|
| `NETSONS_FTP_SERVER` | secret | host FTP Netsons (es. `ftp.massimoaria.com`) |
| `NETSONS_FTP_USERNAME` | secret | utente FTP |
| `NETSONS_FTP_PASSWORD` | secret | password FTP |
| `NETSONS_SERVER_DIR` | variable | solo se la web root **non** è `/public_html/` |

Il workflow fallisce subito con un messaggio esplicito se i tre secret mancano,
invece di tentare una connessione anonima.

Consigliato creare su cPanel un **utente FTP dedicato** limitato alla web root,
invece di usare le credenziali principali dell'account.

### 10.4 Prima esecuzione — cosa aspettarsi

Il primo deploy sovrascrive:

- `index.html`, oggi il guscio `<iframe>` da 1 KB (sorgente: `redirect/index.html`);
- i file orfani fermi al 24 aprile 2025 (`teaching.html`, `publications.html`,
  `software.html`, …), residuo di una vecchia pubblicazione diretta.

Eventuali file orfani **non** presenti in `docs/` restano sul server: innocui, ma
si possono cancellare a mano da cPanel. Dopo il primo deploy riuscito,
`redirect/index.html` in questo repo non serve più.

### 10.5 Verifica dopo il deploy

```bash
# il sito è aggiornato e i deep link funzionano
curl -sI https://www.massimoaria.com/teaching.html | head -1          # 200
curl -s  https://www.massimoaria.com/ | grep -c 'stat__num'           # 4
curl -s  https://www.massimoaria.com/teaching.html | grep -c Monteriggioni  # 0

# LE APPLICAZIONI SONO ANCORA VIVE — controllo obbligatorio al primo deploy
for p in limesurvey irslab dipeccellenza fondo_premiale; do
  printf "%-16s %s\n" "$p" \
    "$(curl -sI -o /dev/null -w '%{http_code}' https://www.massimoaria.com/$p/)"
done   # attesi: quattro 200
```

---

## Appendice — snippet utili

**Metriche Scholar correnti dalla cache**

```bash
python3 -c "
import json; d=json.load(open('scholar_cache.json'))
p=d['profile']; print('cites',p['total_cites'],'h',p['h_index'],'i10',p['i10_index'])
print('ultimo anno:', d['cite_history'][-1])
"
```

**Totale download CRAN di un pacchetto**

```r
cranlogs::cran_downloads("bibliometrix", from = "2015-01-01", to = Sys.Date()) |>
  with(sum(count, na.rm = TRUE))
```

**Lavori sanitari su OpenAlex, con triage per parole chiave** — vedi lo script in
§5.1, aggiungendo un filtro regex su titolo/rivista:
`health|hospital|clinic|medic|care|nurs|patient|governance`.
Poi applicare i criteri di §6.2 a mano: il filtro lessicale da solo **non**
separa management e clinica.

---

*Ultimo aggiornamento del piano: 2026-08-29.*
