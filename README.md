# ScalperBot

Expert Advisor MQL5 per MetaTrader 5, pensato per **XAUUSD**.

Due ingressi (mai contemporanei, massimo uno per candela):

- **Range**: se le ultime `InpRangeCandles` candele stanno in un box di al più `InpRangeMaxPoints` punti, vende sul bordo alto / compra sul bordo basso con TP al lato opposto.
- **Momentum**: se il corpo della candela corrente supera `InpMinCandlePoints` punti, entra nella direzione della spinta.

Gestione della posizione a scaglioni monetari (in € reali, netti di commissioni):

| Profitto raggiunto | Cosa succede |
|---|---|
| `InpStep1Trigger` (2,50€) | SL a Break-Even + apre la piramide (seconda posizione, SL sull'apertura della base) |
| `InpStep2Trigger` (5€) | SL a `+InpStep2Lock` (2,50€) |
| `InpStep3Trigger` (10€) | SL a `+InpStep3Lock` (5€) |
| `InpTakeProfit` (15€) | chiude |
| `-InpMaxLoss` (-20€) | chiude |

## v6.00 — review e correzioni

La v5 aveva bug che lasciavano la posizione più scoperta di quanto sembrasse:

1. **Conversione euro → prezzo sbagliata** (`euro / (lotti * 10)`). Su XAUUSD a 0.1 lotti gli step di SL erano 10× più stretti del dichiarato: lo "SL a +5€" stava a $0.05 dall'apertura (= 0,46€), dentro lo spread. Ora si usa `SYMBOL_TRADE_TICK_VALUE` / `TICK_SIZE` reali.
2. **Cooldown e filtro spread bloccavano anche la gestione**: nei 15 s dopo un'operazione, o con spread alto (news, rollover), l'EA non chiudeva a -20€ né muoveva lo SL. Ora filtrano solo i nuovi ingressi.
3. **Nessuno SL/TP al broker**: lo stop era solo software. Terminale chiuso o connessione persa = posizione senza protezione. Ora SL e TP monetari vengono messi all'apertura; il controllo software resta come backup.
4. **Lo SL poteva tornare indietro**: se il profitto ritracciava da +10€ a +3€, lo SL veniva rimesso a Break-Even. Ora gli step sono monotoni.
5. **Vendite dentro un breakout**: il box esclude la candela corrente, quindi durante una rottura verso l'alto il prezzo era "≥ bordo alto" e l'EA vendeva ogni 15 s contro il breakout. Ora si entra solo se il prezzo è ancora dentro il box (± `InpRangeTolerance`) e la candela corrente non sta già spingendo nella direzione della rottura.
6. **Commissioni ignorate**: i target erano lordi. Ora il profitto è netto (commissione dei deal della posizione, raddoppiata se `InpCommissionPerSide`).
7. **Stato perso al riavvio**: con 2 posizioni aperte e EA riavviato, apriva una terza piramide. Ora lo stato si ricava dal conteggio delle posizioni.
8. **Confronto SL senza normalizzazione** → `PositionModify` ripetuto ogni tick. Ora prezzo normalizzato, tolleranza e rispetto di stops/freeze level del broker.

Aggiunte (tutte parametriche):

- `InpMaxDailyLoss`: sotto questa perdita giornaliera (realizzata + flottante) niente nuovi ingressi. Default 50€, 0 = off.
- `InpStartHour` / `InpEndHour`: fascia oraria server. Default 0–24 = sempre.
- `InpMaxCandlePoints`: non inseguire candele già troppo estese. Default 0 = off.
- `InpStrategyMode`: range / momentum / entrambe.
- `InpSlippage`, filling mode dal simbolo, log degli errori di trade nel journal.

Rinominato `InpRangeMaxPips` → `InpRangeMaxPoints` (era già in punti). I vecchi file `.set` vanno rifatti.

## Da verificare in MetaEditor / Strategy Tester

- Compilare: la v6 non è stata compilata (sviluppata senza MT5).
- Nel journal all'avvio compare `15.00€ = X di prezzo per 0.10 lotti`: X deve avere senso per l'oro (≈ 1.5–1.7 con 0.1 lotti).
- Backtest v5 vs v6 sullo stesso periodo, stesso simbolo, con spread reale.
- Controllare che il broker accetti lo SL di Break-Even a +2,50€ (stops level).

## Parametri e XAUUSD

I default (150 punti di box, 50 punti di spinta) sono nati su EURUSD. Sull'oro 150 punti = $1.50 in 15 candele, un box rarissimo: in pratica quasi tutti gli ingressi sono momentum. Da rivedere nel tester.
