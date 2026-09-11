# ScalperBot

Expert Advisor MQL5 per MetaTrader 5, pensato per **XAUUSD** su conto hedging (funziona anche su altri simboli, es. BTCUSD: tutte le distanze sono in ATR, vanno solo rivisti `InpMaxSpread` e `InpMaxLossMoney`).

## v7.00 — multi-strategia, multi-timeframe

Quattro strategie indipendenti, ognuna con il **suo timeframe** e il suo magic number (`InpMagicBase + indice`). Al massimo una posizione per strategia e `InpMaxPositions` totali. Si mette su un grafico qualsiasi del simbolo: il timeframe del grafico non conta.

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
- **v7**: questa. Compilata con MetaEditor 5 (build settembre 2026): **0 errori, 0 warning**. **Non ancora backtestata.**

## Come testarla (Strategy Tester)

1. Copiare `ScalperBot.mq5` in `MQL5/Experts/`, aprirlo in MetaEditor, **Compile** (F7).
2. Terminal → View → Strategy Tester (Ctrl+R):
   - Expert: `ScalperBot`, Symbol: `XAUUSD` (o `GOLD` a seconda del broker), Timeframe: uno qualsiasi (M1 va bene)
   - Modelling: **Every tick based on real ticks**
   - Deposit: quello reale, Leverage 1:500
   - Periodo: almeno 3 mesi
3. Journal: all'avvio deve comparire `1 punto = 0.2x€. Tetto perdita 60.00€ = 2.6 di prezzo` (valori sensati per l'oro a 0.25 lotti).
4. Confronto utile: stesso periodo con la v5 (`git show 3c8ba0d:ScalperBot.mq5 > ScalperBot_v5.mq5`).
5. Per capire quale strategia rende: disattivare le altre tre (`InpXxxEnabled = false`) e ripetere.

Cose da guardare nel report: profit factor per strategia (i commenti dei trade iniziano con il tag), drawdown massimo, quanti `SKIP ... rischio > tetto` nel journal (se tanti, alzare il tetto o abbassare i moltiplicatori ATR).
