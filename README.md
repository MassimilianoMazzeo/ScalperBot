# ScalperBot

Expert Advisor MQL5 per MetaTrader 5, pensato per **XAUUSD** su conto hedging (funziona anche su altri simboli, es. BTCUSD: tutte le distanze sono in ATR, vanno solo rivisti `InpMaxSpread` e `InpMaxLossMoney`).

## v7.00 — multi-strategia, multi-timeframe

Quattro strategie indipendenti (dalla v7.40 solo BRK e PB attive di default, vedi in fondo), ognuna con il **suo timeframe** e il suo magic number (`InpMagicBase + indice`). Al massimo una posizione per strategia e `InpMaxPositions` totali. Si mette su un grafico qualsiasi del simbolo: il timeframe del grafico non conta.

| # | Tag | Idea | TF default | Runner |
|---|---|---|---|---|
| 0 | **RNG** | Mean-reversion sui bordi di un box stretto (≤ 1.5 ATR in 20 candele), solo con ADX < 20. TP sul bordo opposto | M1 | no |
| 1 | **MOM** | Corpo della candela corrente tra 0.6 e 1.8 ATR nella direzione del +DI/−DI, solo con ADX ≥ 22 | M1 | sì |
| 2 | **BRK** | La candela chiusa rompe un box (12 candele, oppure la sessione asiatica 01–08 server) con corpo ≥ 0.4 ATR | M5 | sì |
| 3 | **PB** | Trend EMA20 > EMA50 (in salita), la candela tocca la EMA20 e chiude sopra, rialzista. SL sotto il minimo | M15 | sì |

### Rischio in R, non in euro fissi

A **0.25 lotti** sull'oro 1 punto = $0.25 ≈ 0,23€: le vecchie soglie (+2,50€ → BE, +15€ TP, −20€ SL) valevano 11 / 65 / 87 punti, cioè dentro lo spread (15–30 punti). Per questo:

- **R** = distanza dello SL = `ATR(14) × moltiplicatore` sul timeframe della strategia (`InpSlMode = SL_ATR`), oppure fisso in euro (`SL_MONEY`).
- **Tetto** `InpMaxLossMoney` (60€): se il rischio ATR supera il tetto, la strategia salta l'ingresso e lo scrive nel journal.
- Gestione per ogni posizione:
  - a **+0.5R** SL a Break-Even + `InpBeBufferPoints`
  - a **+1R** chiude lo **scalp** (`InpScalpPct` = 50 %); se la strategia non ha runner chiude tutto
  - il resto è il **runner**: SL a +0.5R, poi trailing `estremo dall'ingresso − 1.5 ATR`, TP finale a **+3R**
  - RNG: nessuno scalp a 1R, il TP è il bordo opposto del box
- SL e TP sono **al broker** dall'apertura; i controlli software sono solo backup.

### Protezioni

- `InpMaxDailyLoss` (150€): perdita del giorno (realizzata + flottante) oltre la quale non si apre più.
- `InpMaxConsecLosses` (3) → pausa di `InpPauseMinutes` (60).
- Spread massimo, cooldown tra ingressi, fascia oraria (default: sempre).
- Piramide **disattivata** di default: a 0.25 lotti raddoppia l'esposizione e la seconda posizione con SL sull'apertura della base perde sempre sul ritraccio.

### Da dove viene (storia delle versioni)

- **v5** (Mazzeo): range + momentum, soglie fisse in euro, +300€ reali. Bug: conversione euro→prezzo `euro/(lotti*10)` (10× troppo stretta sull'oro), cooldown/spread che bloccavano anche la gestione, nessuno SL al broker, vendite dentro i breakout, SL che tornava indietro.
- **v6**: stessa strategia con i bug corretti, tutto parametrico.
- **v7**: multi-strategia. **v7.10**: filtro spread relativo, stato sul grafico, lotto adattivo. Compilata con MetaEditor 5 (build settembre 2026): **0 errori, 0 warning**. **Non ancora backtestata.**

## v7.10 — «non fa nulla»: ora lo dice

Provata su BTCUSD non apriva niente e non diceva perché: `InpMaxSpread = 30` punti era tarato sull'oro, su BTC un punto è $0.01 e lo spread vale migliaia di punti. Il filtro bloccava tutto in silenzio.

- **Spread in % dello Stop** (`InpMaxSpreadPctR`, 25 %): il filtro è relativo a R della singola strategia, così vale su qualsiasi simbolo e timeframe. Il vecchio `InpMaxSpread` in punti resta come limite assoluto opzionale (0 = off).
- **Stato sempre visibile**: in alto a sinistra sul grafico (`Comment`) e nel journal ogni `InpStatusEveryMin` minuti: spread, posizioni, e per ogni strategia ATR, R in euro, spread in % di R e **il motivo per cui sta aspettando** («ADX 27 ≥ 20: mercato non laterale», «corpo 0.2 ATR (serve ≥ 0.6)», «spread 31 % di R > 25 %», «rischio 97 € al lotto minimo > tetto»…). Se la riga 2 dice `INGRESSI BLOCCATI`, c'è un filtro globale (cooldown, pausa, fascia oraria, limite giornaliero).
- **Lotto adattivo** (`InpLotMode = LOT_FIT_RISK`): se il rischio a 0.25 lotti supera il tetto, il lotto scende fino a rientrarci invece di saltare l'ingresso (lo scrive nel journal). `LOT_FIXED_SKIP` per il comportamento precedente.
- **Break-Even che copre le commissioni reali** della posizione, non un buffer fisso.
- **Slippage** = il maggiore tra `InpSlippage` e il 10 % di R (su BTC 20 punti erano $0.20).
- BRK e PB non «bruciano» più la candela se gli indicatori non sono ancora pronti al primo tick.
- Journal all'avvio: digits, point, contratto, tick value, stops level, spread attuale e quanto vale in euro al lotto impostato.

### Se ancora non apre

Guardare le 6 righe sul grafico. Casi tipici:

| Riga | Significa | Cosa fare |
|---|---|---|
| `spread 40% di R > 25%` | lo spread mangia troppo dello stop | aspettare ore più liquide, o alzare `InpMaxSpreadPctR`, o usare timeframe più alti (R più grande) |
| `ADX 27 >= 20` su RNG e `ADX 27 < 22` su MOM/PB | ADX tra 20 e 22: zona morta | normale, passa da sola |
| `box 2.3 ATR > 1.5` | il mercato non è in range | normale |
| `rischio 97€ al lotto minimo > tetto 60€` | anche col lotto minimo si rischia troppo | alzare `InpMaxLossMoney` o abbassare `InpXxxSlAtr` |
| `INGRESSI BLOCCATI: fuori fascia oraria` | `InpStartHour/EndHour` | controllare l'ora server |
| `ATR non pronto` per più di un minuto | il simbolo non ha storico su quel timeframe | aprire un grafico di quel timeframe per scaricarlo |

## v7.20 — lotto in % del capitale

Primo giro reale su BTCUSD (Fusion demo, 12 set): spread $18 = **122-153 % dello stop su M1**, 49 % su M5, 21 % su M15. Su BTC a questo broker lo scalping sotto M15 non è possibile, l'EA lo rifiuta e lo scrive. E a 0.25 lotti il rischio per trade su BTC era 3-19 €, su oro 60 €: il lotto fisso non ha senso su strumenti diversi.

- `InpLotMode = LOT_RISK_PCT` (default): lotto = `min(capitale × InpRiskPct %, InpMaxLossMoney) / rischio per lotto`, mai sopra `InpLotSize` (che diventa il lotto massimo). Uguale su oro e BTC.
- Per BTC usare timeframe più alti: RNG M15, MOM M15, BRK M30, PB H1.

## v7.30 — obiettivo giornaliero

`InpDailyTarget` (€, 0 = off): raggiunto il profitto del giorno (realizzato + flottante), niente nuovi ingressi fino a domani; le posizioni aperte continuano con la loro gestione. La prima riga dello stato mostra `oggi +X€ / target +Y€ / max -Z€`.

## v7.40 — backtest a tick reali: MOM e RNG spente di default

Primi backtest veri (Strategy Tester, XAUUSD FusionMarkets-Demo, rischio 2 %, target +500 / max −250 al giorno, 13 set 2026):

| Configurazione | Periodo | Tick | Risultato |
|---|---|---|---|
| tutte e 4 (RNG M1, MOM M1, BRK M5, PB M15) | 10 ago – 12 set | **generati** da M1 | +4438 € — 3009 trade, 86 al giorno, PF 1.17, DD 21 % |
| tutte e 4 | 1 – 12 set | **reali** | **−814 $** — 1119 trade, PF 0.82, DD 74 % |
| MOM/RNG M5, BRK M15, PB H1 | 1 – 12 set | reali | −452 $ |
| MOM/RNG M15, BRK M30, PB H1 | 1 – 12 set | reali | −193 $ |
| solo BRK M5 + PB M15 | 1 – 12 set | reali | +80 $ — PF 1.20 |
| **solo BRK M5 + PB M15** | 10 ago – 12 set | reali | **+226 $** — 246 trade, 8 al giorno, PF 1.19, DD 11 %, 14 giorni su 25 positivi, peggior giorno −106 $ |

Cosa dice:

- **MOM su M1 perde con i tick reali** a qualsiasi timeframe provato. Il +4438 € era un artefatto dei tick generati: dentro la candela M1 il tester inventa il percorso del prezzo e il BE a +0.5R / scalp a +1R «funzionano» sempre; con la sequenza vera dei tick vengono presi in mezzo (39 % di vincite, media +5.65 / −10.15). **Mai fidarsi di «Every tick» generato per lo scalping M1.**
- **RNG non è mai entrata** in 5 settimane: sull'oro M1 l'ADX(14) sta sotto 20 quasi mai (90 % delle volte «mercato non laterale»).
- **BRK e PB** sono le uniche in positivo con i tick reali, entrambe. Poche operazioni (8 al giorno), durata media 47 minuti: non è più uno scalping M1, ma è quello che regge.
- Con il 2 % di rischio l'aspettativa è di circa **+45 $ a settimana** su 1000: il target giornaliero di 500 € non è raggiungibile, la perdita massima giornaliera vista è −106 $.

Modifiche:

- `InpMomEnabled = false`, `InpRngEnabled = false` di default. Riattivarle solo dopo un backtest a tick reali che le giustifichi.
- `InpTrailStepPctR` (10 %): il trailing del runner sposta lo SL solo se migliora di almeno il 10 % di R. Prima lo modificava a ogni tick (decine di richieste al secondo), un broker reale le rifiuta o le rallenta.

Per riprodurre senza GUI (MetaTrader su Mac/Wine): un file `tester.ini` (UTF-16LE con BOM) con sezione `[Tester]` (`Expert=ScalperBot\ScalperBot.ex5`, `Symbol=XAUUSD`, `Model=4` per i tick reali, `FromDate`, `ToDate`, `Deposit`, `Currency=USD` — con `EUR` il broker non ha i tick di XAUEUR e il test si ferma —, `Report=nome`, `ShutdownTerminal=1`) e `[TesterInputs]` con `InpX=valore||valore||0||0||N`; poi `terminal64.exe /config:tester.ini`. Il report esce come `nome.htm` nella cartella del terminale.

## v7.50 — controtrend H1 e memoria degli errori

Un giorno intero di live sul demo (14 set 2026, 116 operazioni del bot) più 20 backtest a tick reali sulle 5 settimane 10 ago – 14 set (deposito 1000 $, rischio 4 %, target +500 / max −250 al giorno, 3 posizioni):

| Configurazione | Netto | Op/giorno | PF | DD max |
|---|---|---|---|---|
| BRK M5 + PB M5 (v7.40, com'era live) | +497 $ | 22 | 1.09 | 45 % |
| stessa + filtro H1 **a favore** del trend | −381 $ | 15 | 0.84 | 56 % |
| stessa + memoria | +682 $ | 22 | 1.12 | 45 % |
| **stessa + filtro H1 CONTROTREND** | **+1244 $** | **8** | **1.61** | **22 %** |
| stessa + controtrend + memoria | +1244 $ | 8 | 1.61 | 22 % |
| tutto su M1, MOM accesa, 5 posizioni, 1 % (provata live il 14 set) | −919 $ | 165 | 0.81 | 92 % |
| M1 senza MOM + memoria | −690 $ | 89 | 0.84 | 70 % |

Cosa dice:

- **Sull'oro BRK e PB su M5 pagano contro il trend orario, non a favore.** Prezzo sotto la EMA50 H1 che scende → solo buy; sopra e sale → solo sell. Il filtro «classico» a favore del trend taglia proprio le inversioni che rendono e passa da +497 a −381 $. Ribaltato, raddoppia il netto e dimezza il drawdown con un terzo delle operazioni.
- **La memoria funziona ma vale meno del filtro**: +497 → +682 $ sulla base. Con il controtrend attivo non cambia il risultato perché le combinazioni che avrebbe bloccato sono già filtrate. Resta accesa: lavora sui giorni futuri, non su quelli del test.
- **Lo scalping M1 ad alta frequenza perde in ogni forma provata.** Live il 14 set: 109 operazioni in 14 ore, +30 €, vincita media +6.7 / perdita media −9.6, 27 € di commissioni. Nel backtest brucia il 92 % del conto in 5 settimane. Chiuso.

Modifiche:

- **Filtro di direzione** (`InpTrendFilter`, EMA `InpTrendEma` = 50 su `InpTrendTf` = H1, con pendenza se `InpTrendNeedSlope`): vale per tutte le strategie, controllato dentro `OpenPosition`. `InpTrendInvert = true` di default: opera **contro** il verso dell'H1. Il motivo del rifiuto compare nello stato («segnale PB buy nel verso del trend H1»).
- **Memoria** (`InpLearnEnabled`): a ogni chiusura, e comunque ogni 15 minuti, il bot rilegge il proprio storico degli ultimi `InpLearnDays` (10) giorni, somma i risultati **in R** per strategia / verso / fascia di `InpLearnHourBlock` (3) ore server, e blocca le combinazioni con almeno `InpLearnMinTrades` (8) trade e somma ≤ `InpLearnBlockR` (−3 R). Finestra scorrevole: quando le vecchie perdite escono dai 10 giorni la combinazione viene riabilitata da sola. Log: `IMPARATO: PB buy 12-15 bloccata (-3.6R su 8 trade)`, `MEMORIA: ... riabilitata`. L'ultima riga dello stato elenca le combinazioni bloccate e il verso dell'H1.
- Il rischio iniziale in euro viaggia nel **commento dell'ordine** (`PB sell r38.14`): nello storico del tester `ORDER_SL` torna 0, dal commento la memoria ricostruisce R anche lì.

Per riprodurre in parallelo su Mac: cloni APFS della cartella del terminale (`cp -Rc`), ognuno lanciato con `terminal64.exe /portable /config:...`. Due tester avviati nello stesso secondo collidono sulla porta 3000 («authorization failed»): sfalsarli di 20–30 s.

## Come testarla (Strategy Tester)

1. Copiare `ScalperBot.mq5` in `MQL5/Experts/`, aprirlo in MetaEditor, **Compile** (F7).
2. Terminal → View → Strategy Tester (Ctrl+R):
   - Expert: `ScalperBot`, Symbol: `XAUUSD` (o `GOLD` a seconda del broker), Timeframe: uno qualsiasi (M1 va bene)
   - Modelling: **Every tick based on real ticks**
   - Deposit: quello reale, Leverage 1:500
   - Periodo: almeno 3 mesi
3. Journal: all'avvio compaiono le specifiche del simbolo e `Lotto 0.25: 1 punto = 0.23€ ... tetto 60€ = 2.6 di prezzo` (valori sensati per l'oro).
4. Confronto utile: stesso periodo con la v5 (`git show 3c8ba0d:ScalperBot.mq5 > ScalperBot_v5.mq5`).
5. Per capire quale strategia rende: disattivare le altre tre (`InpXxxEnabled = false`) e ripetere.

Cose da guardare nel report: profit factor per strategia (i commenti dei trade iniziano con il tag), drawdown massimo, quanti `SKIP ... rischio > tetto` nel journal (se tanti, alzare il tetto o abbassare i moltiplicatori ATR).
