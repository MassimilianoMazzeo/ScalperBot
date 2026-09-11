//+------------------------------------------------------------------+
//|                                                   ScalperBot.mq5 |
//|                                   Copyright 2026, Mazzeo/Tavelli |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "7.00"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| v7.00 - multi-strategia, multi-timeframe, pensato per XAUUSD     |
//|                                                                  |
//| Quattro strategie indipendenti, ognuna con il suo timeframe e il |
//| suo magic number (base + indice), al massimo una posizione per   |
//| strategia e InpMaxPositions totali:                              |
//|   0 RNG  mean-reversion sui bordi di un box stretto (no runner)  |
//|   1 MOM  momentum sul corpo della candela corrente               |
//|   2 BRK  breakout di un box (candele o sessione asiatica)        |
//|   3 PB   pullback sulla EMA veloce in trend                      |
//|                                                                  |
//| Rischio in R = distanza dello SL, calcolata sull'ATR del         |
//| timeframe della strategia (o fissa in euro), con tetto in euro.  |
//| Gestione: BE a +BeR, chiusura parziale a +Tp1R (scalp), il resto |
//| corre con trailing ATR fino a +Tp2R (runner).                    |
//+------------------------------------------------------------------+

#define N_STRATEGIES 4
#define IDX_RNG 0
#define IDX_MOM 1
#define IDX_BRK 2
#define IDX_PB  3

enum ENUM_SL_MODE
  {
   SL_ATR,     // SL = ATR x moltiplicatore (per timeframe della strategia)
   SL_MONEY    // SL = InpMaxLossMoney fisso in euro
  };

enum ENUM_BOX_MODE
  {
   BOX_CANDLES,   // Box = ultime N candele chiuse
   BOX_SESSION    // Box = sessione oraria (es. asiatica), breakout dopo la chiusura
  };

// --- PARAMETRI DI INPUT
input group "--- Generali ---"
input double   InpLotSize        = 0.25;     // Lotto per posizione
input ulong    InpMagicBase      = 998870;   // Magic number base (ogni strategia usa base+indice)
input int      InpMaxPositions   = 2;        // Posizioni aperte massime (tutte le strategie)
input int      InpMaxSpread      = 30;       // Spread massimo per entrare (Punti)
input int      InpSlippage       = 20;       // Slippage massimo (Punti)

input group "--- Rischio ---"
input ENUM_SL_MODE InpSlMode     = SL_ATR;   // Come si calcola lo Stop Loss
input double   InpMaxLossMoney   = 60.0;     // Perdita massima per posizione (€): tetto o SL fisso
input double   InpBeR            = 0.5;      // A +X R porta lo SL a Break-Even
input int      InpBeBufferPoints = 5;        // Punti oltre l'apertura per il Break-Even (copre commissioni)
input double   InpTp1R           = 1.0;      // A +X R chiude lo scalp (parziale se runner, totale altrimenti)
input double   InpScalpPct       = 50.0;     // % di posizione chiusa allo scalp (se runner attivo)
input double   InpLockR          = 0.5;      // Dopo lo scalp, SL a +X R
input double   InpTp2R           = 3.0;      // Target finale del runner (R)
input double   InpTrailAtrMult   = 1.5;      // Trailing del runner: estremo dall'ingresso - ATR x X
input bool     InpCommissionPerSide = true;  // Commissione addebitata sia in entrata che in uscita

input group "--- Protezioni giornaliere ---"
input double   InpMaxDailyLoss   = 150.0;    // Perdita massima giornaliera (€), 0 = off
input int      InpMaxConsecLosses = 3;       // Perdite consecutive prima della pausa, 0 = off
input int      InpPauseMinutes   = 60;       // Durata pausa dopo le perdite consecutive
input int      InpMinSecBetweenTrades = 30;  // Attesa minima tra due ingressi (secondi)
input int      InpStartHour      = 0;        // Ora server inizio operatività (0-23)
input int      InpEndHour        = 24;       // Ora server fine operatività (1-24); 0-24 = sempre

input group "--- Filtri di regime (ADX) ---"
input int      InpAdxPeriod      = 14;
input double   InpAdxRangeMax    = 20.0;     // RNG solo se ADX < X (mercato laterale)
input double   InpAdxTrendMin    = 22.0;     // MOM e PB solo se ADX >= X (mercato direzionale)
input int      InpAtrPeriod      = 14;

input group "--- 0. RNG: range mean-reversion ---"
input bool     InpRngEnabled     = true;
input ENUM_TIMEFRAMES InpRngTf   = PERIOD_M1;
input int      InpRngCandles     = 20;       // Candele chiuse che definiscono il box
input double   InpRngMaxAtr      = 1.5;      // Ampiezza massima del box (x ATR)
input double   InpRngMinAtr      = 0.6;      // Ampiezza minima del box (x ATR): sotto non vale la pena
input double   InpRngTolAtr      = 0.10;     // Tolleranza sui bordi (x ATR)
input double   InpRngSlAtr       = 0.8;      // SL (x ATR)
input double   InpRngMinRR       = 0.8;      // Rapporto minimo TP/SL per entrare

input group "--- 1. MOM: momentum candela ---"
input bool     InpMomEnabled     = true;
input ENUM_TIMEFRAMES InpMomTf   = PERIOD_M1;
input double   InpMomMinBodyAtr  = 0.6;      // Corpo minimo candela corrente (x ATR)
input double   InpMomMaxBodyAtr  = 1.8;      // Corpo massimo: oltre non si insegue (x ATR)
input double   InpMomSlAtr       = 1.0;      // SL (x ATR)
input bool     InpMomRunner      = true;     // Dopo lo scalp lascia correre il resto

input group "--- 2. BRK: breakout box ---"
input bool     InpBrkEnabled     = true;
input ENUM_TIMEFRAMES InpBrkTf   = PERIOD_M5;
input ENUM_BOX_MODE InpBrkBoxMode = BOX_CANDLES;
input int      InpBrkCandles     = 12;       // Candele del box (modo CANDLES), escluse la corrente e quella di rottura
input int      InpBrkSessionStart = 1;       // Ora server inizio sessione (modo SESSION)
input int      InpBrkSessionEnd  = 8;        // Ora server fine sessione (modo SESSION)
input int      InpBrkSessionUntil = 14;      // Ora server entro cui vale il breakout di sessione
input double   InpBrkBoxMaxAtr   = 2.5;      // Ampiezza massima del box (x ATR)
input double   InpBrkBufferAtr   = 0.10;     // Chiusura oltre il bordo di almeno X ATR
input double   InpBrkMinBodyAtr  = 0.4;      // Corpo minimo della candela di rottura (x ATR)
input double   InpBrkSlAtr       = 1.0;      // SL (x ATR)
input bool     InpBrkRunner      = true;

input group "--- 3. PB: pullback EMA in trend ---"
input bool     InpPbEnabled      = true;
input ENUM_TIMEFRAMES InpPbTf    = PERIOD_M15;
input int      InpPbEmaFast      = 20;
input int      InpPbEmaSlow      = 50;
input double   InpPbTouchAtr     = 0.15;     // La candela deve arrivare a X ATR dalla EMA veloce
input double   InpPbSlAtr        = 1.2;      // SL minimo (x ATR); comunque sotto il minimo della candela
input bool     InpPbRunner       = true;

input group "--- Piramide (sconsigliata a 0.25 lotti) ---"
input bool     InpEnablePyramid  = false;    // Seconda posizione della stessa strategia a +BeR
input double   InpPyramidLotPct  = 50.0;     // Lotto della piramide in % del lotto base

// --- STATO
struct Strategy
  {
   string           tag;
   bool             enabled;
   bool             runner;
   ENUM_TIMEFRAMES  tf;
   double           slAtr;
   int              hAtr;
   int              hAdx;
   int              hEmaFast;
   int              hEmaSlow;
   datetime         lastEntryBar;   // una sola apertura per candela della strategia
   datetime         lastSignalBar;  // per i segnali valutati a candela chiusa
   int              sessionTradeDay;
  };
Strategy S[N_STRATEGIES];

struct PosInfo
  {
   int     idx;          // strategia
   double  initVolume;
   double  commission;   // già negativa
   double  initialSL;
  };

datetime lastTradeTime = 0;
datetime pauseUntil    = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpBeR >= InpTp1R || InpLockR >= InpTp1R || InpTp1R >= InpTp2R)
     {
      Print("ERRORE: serve BeR < Tp1R, LockR < Tp1R, Tp1R < Tp2R");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpScalpPct <= 0.0 || InpScalpPct > 100.0)
     {
      Print("ERRORE: InpScalpPct deve essere tra 1 e 100");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("ATTENZIONE: conto NETTING. Più posizioni sullo stesso simbolo vengono fuse: usare InpMaxPositions=1 e piramide off.");

   S[IDX_RNG].tag = "RNG"; S[IDX_RNG].enabled = InpRngEnabled; S[IDX_RNG].runner = false;        S[IDX_RNG].tf = InpRngTf; S[IDX_RNG].slAtr = InpRngSlAtr;
   S[IDX_MOM].tag = "MOM"; S[IDX_MOM].enabled = InpMomEnabled; S[IDX_MOM].runner = InpMomRunner; S[IDX_MOM].tf = InpMomTf; S[IDX_MOM].slAtr = InpMomSlAtr;
   S[IDX_BRK].tag = "BRK"; S[IDX_BRK].enabled = InpBrkEnabled; S[IDX_BRK].runner = InpBrkRunner; S[IDX_BRK].tf = InpBrkTf; S[IDX_BRK].slAtr = InpBrkSlAtr;
   S[IDX_PB].tag  = "PB";  S[IDX_PB].enabled  = InpPbEnabled;  S[IDX_PB].runner  = InpPbRunner;  S[IDX_PB].tf  = InpPbTf;  S[IDX_PB].slAtr  = InpPbSlAtr;

   for(int i = 0; i < N_STRATEGIES; i++)
     {
      S[i].hAtr = INVALID_HANDLE; S[i].hAdx = INVALID_HANDLE;
      S[i].hEmaFast = INVALID_HANDLE; S[i].hEmaSlow = INVALID_HANDLE;
      S[i].lastEntryBar = 0; S[i].lastSignalBar = 0; S[i].sessionTradeDay = -1;
      if(!S[i].enabled) continue;

      S[i].hAtr = iATR(_Symbol, S[i].tf, InpAtrPeriod);
      S[i].hAdx = iADX(_Symbol, S[i].tf, InpAdxPeriod);
      if(S[i].hAtr == INVALID_HANDLE || S[i].hAdx == INVALID_HANDLE)
        {
         Print("ERRORE: indicatori non creati per ", S[i].tag);
         return(INIT_FAILED);
        }
      if(i == IDX_PB)
        {
         S[i].hEmaFast = iMA(_Symbol, S[i].tf, InpPbEmaFast, 0, MODE_EMA, PRICE_CLOSE);
         S[i].hEmaSlow = iMA(_Symbol, S[i].tf, InpPbEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
         if(S[i].hEmaFast == INVALID_HANDLE || S[i].hEmaSlow == INVALID_HANDLE)
           {
            Print("ERRORE: EMA non create per PB");
            return(INIT_FAILED);
           }
        }
     }

   PrintFormat("ScalperBot v7 su %s, %.2f lotti. 1 punto = %.2f€. Tetto perdita %.2f€ = %s di prezzo.",
               _Symbol, InpLotSize, PriceToMoney(_Point, InpLotSize), InpMaxLossMoney,
               DoubleToString(MoneyToPrice(InpMaxLossMoney, InpLotSize), _Digits));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   for(int i = 0; i < N_STRATEGIES; i++)
     {
      if(S[i].hAtr     != INVALID_HANDLE) IndicatorRelease(S[i].hAtr);
      if(S[i].hAdx     != INVALID_HANDLE) IndicatorRelease(S[i].hAdx);
      if(S[i].hEmaFast != INVALID_HANDLE) IndicatorRelease(S[i].hEmaFast);
      if(S[i].hEmaSlow != INVALID_HANDLE) IndicatorRelease(S[i].hEmaSlow);
     }
  }

//+------------------------------------------------------------------+
//| Conversioni denaro <-> prezzo con tick value/size reali          |
//+------------------------------------------------------------------+
double MoneyToPrice(double money, double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || lots <= 0.0) return(0.0);
   return((money * tickSize) / (tickValue * lots));
  }

double PriceToMoney(double dist, double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0) return(0.0);
   return(dist / tickSize * tickValue * lots);
  }

double MinStopDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return((double)MathMax(stops, freeze) * _Point);
  }

double NormalizeLot(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot > 0.0) lots = MathFloor(lots / stepLot + 0.0000001) * stepLot;
   return(MathMin(MathMax(lots, minLot), maxLot));
  }

//+------------------------------------------------------------------+
//| Lettura indicatori                                               |
//+------------------------------------------------------------------+
double Ind(int handle, int buffer, int shift)
  {
   double b[];
   if(handle == INVALID_HANDLE) return(EMPTY_VALUE);
   if(CopyBuffer(handle, buffer, shift, 1, b) != 1) return(EMPTY_VALUE);
   return(b[0]);
  }

bool IsOurMagic(long magic, int &idx)
  {
   long base = (long)InpMagicBase;
   if(magic < base || magic >= base + N_STRATEGIES) return(false);
   idx = (int)(magic - base);
   return(true);
  }

//+------------------------------------------------------------------+
//| Posizioni aperte: totali e per strategia                         |
//+------------------------------------------------------------------+
int CountPositions(int &perStrategy[])
  {
   ArrayResize(perStrategy, N_STRATEGIES);
   ArrayInitialize(perStrategy, 0);
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int idx;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC), idx)) continue;
      perStrategy[idx]++;
      total++;
     }
   return(total);
  }

//+------------------------------------------------------------------+
//| Dati storici della posizione selezionata (deal e ordine iniziale)|
//+------------------------------------------------------------------+
bool LoadPosInfo(PosInfo &info)
  {
   info.initVolume = 0.0; info.commission = 0.0; info.initialSL = 0.0; info.idx = -1;
   if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC), info.idx)) return(false);

   long posId = PositionGetInteger(POSITION_IDENTIFIER);
   if(!HistorySelectByPosition(posId)) return(false);

   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      info.commission += HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         info.initVolume += HistoryDealGetDouble(deal, DEAL_VOLUME);
     }
   for(int i = 0; i < HistoryOrdersTotal(); i++)
     {
      ulong order = HistoryOrderGetTicket(i);
      if(order == 0) continue;
      double sl = HistoryOrderGetDouble(order, ORDER_SL);
      if(sl > 0.0) { info.initialSL = sl; break; }
     }
   if(info.initVolume <= 0.0) info.initVolume = PositionGetDouble(POSITION_VOLUME);
   if(InpCommissionPerSide) info.commission *= 2.0;
   return(true);
  }

//+------------------------------------------------------------------+
//| Statistiche di oggi dallo storico: P&L realizzato, perdite       |
//| consecutive in coda e ora dell'ultima perdita                    |
//+------------------------------------------------------------------+
void TodayStats(double &realized, int &consecLosses, datetime &lastLossTime)
  {
   realized = 0.0; consecLosses = 0; lastLossTime = 0;
   datetime now      = TimeCurrent();
   datetime dayStart = now - (now % 86400);
   if(!HistorySelect(dayStart, now)) return;

   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      int idx;
      if(!IsOurMagic(HistoryDealGetInteger(deal, DEAL_MAGIC), idx)) continue;

      double comm = HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      realized += comm;   // le commissioni pesano su ogni deal, in entrata e in uscita
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
        {
         double gross = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP);
         realized += gross;
         double pnl = gross + comm;
         if(pnl < 0.0)
           {
            consecLosses++;
            lastLossTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
           }
         else
            consecLosses = 0;
        }
     }
  }

double FloatingNetPnL()
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      PosInfo info;
      if(!LoadPosInfo(info)) continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + info.commission;
     }
   return(sum);
  }

//+------------------------------------------------------------------+
//| Filtri globali per i nuovi ingressi                              |
//+------------------------------------------------------------------+
bool GlobalEntryFiltersOk()
  {
   datetime now = TimeCurrent();
   if(now - lastTradeTime < InpMinSecBetweenTrades) return(false);
   if(now < pauseUntil) return(false);
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return(false);

   if(!(InpStartHour == 0 && InpEndHour == 24))
     {
      MqlDateTime t;
      TimeToStruct(now, t);
      bool inside = (InpStartHour < InpEndHour)
                    ? (t.hour >= InpStartHour && t.hour < InpEndHour)
                    : (t.hour >= InpStartHour || t.hour < InpEndHour);
      if(!inside) return(false);
     }

   if(InpMaxDailyLoss > 0.0 || InpMaxConsecLosses > 0)
     {
      double realized; int consec; datetime lastLoss;
      TodayStats(realized, consec, lastLoss);

      if(InpMaxConsecLosses > 0 && consec >= InpMaxConsecLosses && lastLoss > 0)
        {
         datetime until = lastLoss + InpPauseMinutes * 60;
         if(now < until)
           {
            if(pauseUntil != until)
              {
               pauseUntil = until;
               PrintFormat("PAUSA: %d perdite consecutive, niente ingressi fino alle %s", consec, TimeToString(until, TIME_MINUTES));
              }
            return(false);
           }
        }
      if(InpMaxDailyLoss > 0.0)
        {
         double dailyPnL = realized + FloatingNetPnL();
         if(dailyPnL <= -MathAbs(InpMaxDailyLoss))
           {
            static datetime lastWarn = 0;
            if(now - lastWarn > 600)
              {
               PrintFormat("LIMITE GIORNALIERO: %.2f€ (limite -%.2f€). Nessun nuovo ingresso oggi.", dailyPnL, InpMaxDailyLoss);
               lastWarn = now;
              }
            return(false);
           }
        }
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Log esito trade                                                  |
//+------------------------------------------------------------------+
bool LogTradeResult(string context)
  {
   uint retcode = trade.ResultRetcode();
   bool ok = (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED);
   if(!ok) Print("ERRORE TRADE [", context, "] retcode ", retcode, " (", trade.ResultRetcodeDescription(), ")");
   else    Print("OK TRADE [", context, "] ticket ", trade.ResultOrder());
   return(ok);
  }

//+------------------------------------------------------------------+
//| Apre una posizione della strategia idx.                          |
//| slDist: distanza SL in prezzo (R). tpPrice>0: TP forzato (RNG).  |
//+------------------------------------------------------------------+
bool OpenPosition(int idx, ENUM_ORDER_TYPE type, double lots, double slDist, double tpPrice, string comment)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MinStopDistance();

   if(InpSlMode == SL_MONEY) slDist = MoneyToPrice(InpMaxLossMoney, lots);
   slDist = MathMax(slDist, minDist);
   if(slDist <= 0.0) return(false);

   double riskMoney = PriceToMoney(slDist, lots);
   if(riskMoney > InpMaxLossMoney + 0.01)
     {
      PrintFormat("SKIP %s: rischio %.2f€ > tetto %.2f€ (SL %s)", S[idx].tag, riskMoney, InpMaxLossMoney, DoubleToString(slDist, _Digits));
      return(false);
     }

   double tpMult = (S[idx].runner) ? InpTp2R : InpTp1R;
   double tpDist = MathMax(slDist * tpMult, minDist);
   double sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      sl = ask - slDist;
      tp = ask + tpDist;
      if(tpPrice > 0.0) tp = MathMax(tpPrice, ask + minDist);
     }
   else
     {
      sl = bid + slDist;
      tp = bid - tpDist;
      if(tpPrice > 0.0) tp = MathMin(tpPrice, bid - minDist);
     }
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   trade.SetExpertMagicNumber(InpMagicBase + (ulong)idx);
   bool sent = (type == ORDER_TYPE_BUY)
               ? trade.Buy(lots, _Symbol, ask, sl, tp, comment)
               : trade.Sell(lots, _Symbol, bid, sl, tp, comment);
   bool ok = sent && LogTradeResult(comment);
   if(ok)
     {
      lastTradeTime = TimeCurrent();
      S[idx].lastEntryBar = iTime(_Symbol, S[idx].tf, 0);
      PrintFormat("  %s rischio %.2f€ (R=%s), TP %s", S[idx].tag, riskMoney, DoubleToString(slDist, _Digits), DoubleToString(tp, _Digits));
     }
   return(ok);
  }

//+------------------------------------------------------------------+
//| Sposta lo SL della posizione selezionata solo se lo migliora     |
//+------------------------------------------------------------------+
void TightenStopLoss(ulong ticket, double newSL, string why)
  {
   long   posType   = PositionGetInteger(POSITION_TYPE);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MinStopDistance();

   newSL = NormalizeDouble(newSL, _Digits);
   if(MathAbs(newSL - currentSL) < _Point / 2.0) return;
   if(posType == POSITION_TYPE_BUY)
     {
      if(currentSL > 0.0 && newSL <= currentSL) return;
      if(newSL > bid - minDist) return;
     }
   else
     {
      if(currentSL > 0.0 && newSL >= currentSL) return;
      if(newSL < ask + minDist) return;
     }
   if(trade.PositionModify(ticket, newSL, currentTP))
      PrintFormat("SL %I64u -> %s (%s)", ticket, DoubleToString(newSL, _Digits), why);
   else
      LogTradeResult("Modify SL " + why);
  }

//+------------------------------------------------------------------+
//| Estremo raggiunto dal prezzo dall'apertura (sul TF della strat.) |
//+------------------------------------------------------------------+
double ExtremeSinceOpen(int idx, bool isBuy, datetime openTime)
  {
   int shift = iBarShift(_Symbol, S[idx].tf, openTime, false);
   if(shift < 0) shift = 0;
   if(isBuy)
     {
      int hb = iHighest(_Symbol, S[idx].tf, MODE_HIGH, shift + 1, 0);
      return((hb < 0) ? 0.0 : iHigh(_Symbol, S[idx].tf, hb));
     }
   int lb = iLowest(_Symbol, S[idx].tf, MODE_LOW, shift + 1, 0);
   return((lb < 0) ? 0.0 : iLow(_Symbol, S[idx].tf, lb));
  }

//+------------------------------------------------------------------+
//| Gestione di una posizione: BE, scalp parziale, runner, tetto     |
//+------------------------------------------------------------------+
void ManagePosition(ulong ticket, int &perStrategy[], int total)
  {
   PosInfo info;
   if(!LoadPosInfo(info)) return;
   int idx = info.idx;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume    = PositionGetDouble(POSITION_VOLUME);
   long   posType   = PositionGetInteger(POSITION_TYPE);
   bool   isBuy     = (posType == POSITION_TYPE_BUY);
   datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double net = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + info.commission;

   // Backup software del tetto di perdita (al broker c'è già lo SL)
   if(net <= -InpMaxLossMoney)
     {
      if(trade.PositionClose(ticket)) { PrintFormat("CHIUSA %I64u a %.2f€: tetto perdita", ticket, net); lastTradeTime = TimeCurrent(); }
      else LogTradeResult("Close cap");
      return;
     }

   double atr = Ind(S[idx].hAtr, 0, 1);
   double R   = (info.initialSL > 0.0) ? MathAbs(openPrice - info.initialSL) : 0.0;
   if(R <= 0.0 && atr != EMPTY_VALUE) R = atr * S[idx].slAtr;
   if(R <= 0.0) return;

   double gain = isBuy ? (bid - openPrice) : (openPrice - ask);   // profitto in prezzo
   double r    = gain / R;
   bool partialDone = (volume < info.initVolume - SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP) / 2.0);
   bool runner = S[idx].runner && InpScalpPct < 100.0;

   // Scalp a +Tp1R: parziale se runner, totale altrimenti (backup del TP al broker).
   // RNG ha il TP sul bordo opposto del box: non si chiude prima.
   if(r >= InpTp1R && !partialDone && idx != IDX_RNG)
     {
      if(runner)
        {
         double closeVol = NormalizeLot(info.initVolume * InpScalpPct / 100.0);
         if(closeVol >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN) && closeVol < volume)
           {
            if(trade.PositionClosePartial(ticket, closeVol))
              { PrintFormat("SCALP %I64u: chiusi %.2f lotti a +%.2fR (%.2f€ netti sul totale)", ticket, closeVol, r, net); partialDone = true; }
            else LogTradeResult("Partial close");
           }
        }
      else
        {
         if(trade.PositionClose(ticket)) { PrintFormat("CHIUSA %I64u a +%.2fR (%.2f€)", ticket, r, net); lastTradeTime = TimeCurrent(); }
         else LogTradeResult("Close TP1");
         return;
        }
     }

   // Stop dinamico: il massimo tra BE, lock e trailing, mai indietro
   double newSL = 0.0;
   string why = "";
   double dir = isBuy ? 1.0 : -1.0;
   if(r >= InpBeR)
     {
      newSL = openPrice + dir * InpBeBufferPoints * _Point;
      why = "BE";
     }
   if(partialDone)
     {
      double lock = openPrice + dir * InpLockR * R;
      if(newSL == 0.0 || dir * (lock - newSL) > 0) { newSL = lock; why = "lock"; }
      if(atr != EMPTY_VALUE)
        {
         double extreme = ExtremeSinceOpen(idx, isBuy, openTime);
         if(extreme > 0.0)
           {
            double trail = extreme - dir * InpTrailAtrMult * atr;
            if(dir * (trail - newSL) > 0) { newSL = trail; why = "trail"; }
           }
        }
     }
   if(newSL > 0.0) TightenStopLoss(ticket, newSL, why);

   // Piramide opzionale: una sola per strategia, tra BE e scalp
   if(InpEnablePyramid && perStrategy[idx] < 2 && total < InpMaxPositions &&
      r >= InpBeR && r < InpTp1R && !partialDone)
     {
      double lots = NormalizeLot(InpLotSize * InpPyramidLotPct / 100.0);
      ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      perStrategy[idx]++;   // anche se fallisce, non si riprova sullo stesso tick
      if(OpenPosition(idx, type, lots, R, 0.0, S[idx].tag + " pyramid"))
         total++;
     }
  }

void ManageAllPositions(int &perStrategy[], int total)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int idx;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC), idx)) continue;
      ManagePosition(ticket, perStrategy, total);
     }
  }

//+------------------------------------------------------------------+
//| Box di N candele chiuse a partire da startShift                  |
//+------------------------------------------------------------------+
bool BoxOfCandles(ENUM_TIMEFRAMES tf, int count, int startShift, double &hi, double &lo)
  {
   int hb = iHighest(_Symbol, tf, MODE_HIGH, count, startShift);
   int lb = iLowest(_Symbol, tf, MODE_LOW,  count, startShift);
   if(hb < 0 || lb < 0) return(false);
   hi = iHigh(_Symbol, tf, hb);
   lo = iLow(_Symbol, tf, lb);
   return(hi > lo);
  }

//+------------------------------------------------------------------+
//| Box della sessione oraria di oggi (ora server)                   |
//+------------------------------------------------------------------+
bool BoxOfSession(ENUM_TIMEFRAMES tf, double &hi, double &lo)
  {
   datetime now      = TimeCurrent();
   datetime dayStart = now - (now % 86400);
   datetime sStart   = dayStart + InpBrkSessionStart * 3600;
   datetime sEnd     = dayStart + InpBrkSessionEnd * 3600;
   if(sEnd <= sStart || now < sEnd) return(false);

   int shiftStart = iBarShift(_Symbol, tf, sStart, false);
   int shiftEnd   = iBarShift(_Symbol, tf, sEnd - 1, false);
   if(shiftStart < 0 || shiftEnd < 0 || shiftStart < shiftEnd) return(false);
   return(BoxOfCandles(tf, shiftStart - shiftEnd + 1, shiftEnd, hi, lo));
  }

//+------------------------------------------------------------------+
//| 0. RNG: mean-reversion sui bordi di un box stretto e laterale    |
//+------------------------------------------------------------------+
bool TryRNG(double lots)
  {
   int idx = IDX_RNG;
   ENUM_TIMEFRAMES tf = S[idx].tf;
   double atr = Ind(S[idx].hAtr, 0, 1);
   double adx = Ind(S[idx].hAdx, 0, 1);
   if(atr == EMPTY_VALUE || adx == EMPTY_VALUE || atr <= 0.0) return(false);
   if(adx >= InpAdxRangeMax) return(false);

   double hi, lo;
   if(!BoxOfCandles(tf, InpRngCandles, 1, hi, lo)) return(false);
   double width = hi - lo;
   if(width > InpRngMaxAtr * atr || width < InpRngMinAtr * atr) return(false);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tol = InpRngTolAtr * atr;
   double body0 = iClose(_Symbol, tf, 0) - iOpen(_Symbol, tf, 0);
   double push  = InpMomMinBodyAtr * atr;
   double slDist = S[idx].slAtr * atr;

   // SELL sul bordo alto: prezzo dentro il box, candela corrente non in rottura
   if(bid >= hi - tol && bid <= hi + tol && body0 < push)
     {
      double tp = lo + tol;
      if((bid - tp) / slDist >= InpRngMinRR)
         return(OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, tp, "RNG sell"));
     }
   if(ask <= lo + tol && ask >= lo - tol && body0 > -push)
     {
      double tp = hi - tol;
      if((tp - ask) / slDist >= InpRngMinRR)
         return(OpenPosition(idx, ORDER_TYPE_BUY, lots, slDist, tp, "RNG buy"));
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| 1. MOM: momentum sul corpo della candela corrente, in trend      |
//+------------------------------------------------------------------+
bool TryMOM(double lots)
  {
   int idx = IDX_MOM;
   ENUM_TIMEFRAMES tf = S[idx].tf;
   double atr = Ind(S[idx].hAtr, 0, 1);
   double adx = Ind(S[idx].hAdx, 0, 1);
   double plusDI  = Ind(S[idx].hAdx, 1, 1);
   double minusDI = Ind(S[idx].hAdx, 2, 1);
   if(atr == EMPTY_VALUE || adx == EMPTY_VALUE || atr <= 0.0) return(false);
   if(adx < InpAdxTrendMin) return(false);

   double body = iClose(_Symbol, tf, 0) - iOpen(_Symbol, tf, 0);
   double minB = InpMomMinBodyAtr * atr, maxB = InpMomMaxBodyAtr * atr;
   double slDist = S[idx].slAtr * atr;

   if(body >= minB && body <= maxB && plusDI > minusDI)
      return(OpenPosition(idx, ORDER_TYPE_BUY, lots, slDist, 0.0, "MOM buy"));
   if(body <= -minB && body >= -maxB && minusDI > plusDI)
      return(OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, 0.0, "MOM sell"));
   return(false);
  }

//+------------------------------------------------------------------+
//| 2. BRK: candela [1] chiude fuori dal box -> runner               |
//+------------------------------------------------------------------+
bool TryBRK(double lots)
  {
   int idx = IDX_BRK;
   ENUM_TIMEFRAMES tf = S[idx].tf;
   datetime bar0 = iTime(_Symbol, tf, 0);
   if(bar0 == S[idx].lastSignalBar) return(false);   // valutato una volta per candela chiusa
   S[idx].lastSignalBar = bar0;

   double atr = Ind(S[idx].hAtr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0.0) return(false);

   double hi, lo;
   if(InpBrkBoxMode == BOX_CANDLES)
     {
      if(!BoxOfCandles(tf, InpBrkCandles, 2, hi, lo)) return(false);
     }
   else
     {
      MqlDateTime t; TimeToStruct(TimeCurrent(), t);
      if(t.hour >= InpBrkSessionUntil) return(false);
      if(S[idx].sessionTradeDay == t.day_of_year) return(false);   // un breakout di sessione al giorno
      if(!BoxOfSession(tf, hi, lo)) return(false);
     }
   if(hi - lo > InpBrkBoxMaxAtr * atr) return(false);

   double open1 = iOpen(_Symbol, tf, 1), close1 = iClose(_Symbol, tf, 1);
   double body1 = close1 - open1;
   double buffer = InpBrkBufferAtr * atr;
   double slDist = S[idx].slAtr * atr;
   bool ok = false;

   if(close1 > hi + buffer && body1 >= InpBrkMinBodyAtr * atr)
      ok = OpenPosition(idx, ORDER_TYPE_BUY, lots, slDist, 0.0, "BRK buy");
   else if(close1 < lo - buffer && -body1 >= InpBrkMinBodyAtr * atr)
      ok = OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, 0.0, "BRK sell");

   if(ok && InpBrkBoxMode == BOX_SESSION)
     {
      MqlDateTime t; TimeToStruct(TimeCurrent(), t);
      S[idx].sessionTradeDay = t.day_of_year;
     }
   return(ok);
  }

//+------------------------------------------------------------------+
//| 3. PB: pullback sulla EMA veloce con trend confermato            |
//+------------------------------------------------------------------+
bool TryPB(double lots)
  {
   int idx = IDX_PB;
   ENUM_TIMEFRAMES tf = S[idx].tf;
   datetime bar0 = iTime(_Symbol, tf, 0);
   if(bar0 == S[idx].lastSignalBar) return(false);
   S[idx].lastSignalBar = bar0;

   double atr  = Ind(S[idx].hAtr, 0, 1);
   double adx  = Ind(S[idx].hAdx, 0, 1);
   double emaF = Ind(S[idx].hEmaFast, 0, 1);
   double emaS1 = Ind(S[idx].hEmaSlow, 0, 1);
   double emaS3 = Ind(S[idx].hEmaSlow, 0, 3);
   if(atr == EMPTY_VALUE || adx == EMPTY_VALUE || emaF == EMPTY_VALUE || emaS1 == EMPTY_VALUE || emaS3 == EMPTY_VALUE) return(false);
   if(atr <= 0.0 || adx < InpAdxTrendMin) return(false);

   double open1 = iOpen(_Symbol, tf, 1), close1 = iClose(_Symbol, tf, 1);
   double high1 = iHigh(_Symbol, tf, 1), low1 = iLow(_Symbol, tf, 1);
   double touch = InpPbTouchAtr * atr;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Long: trend su, la candela tocca la EMA veloce e chiude sopra, rialzista
   if(emaF > emaS1 && emaS1 > emaS3 && low1 <= emaF + touch && close1 > emaF && close1 > open1)
     {
      double slDist = MathMax(S[idx].slAtr * atr, ask - (low1 - 0.2 * atr));
      return(OpenPosition(idx, ORDER_TYPE_BUY, lots, slDist, 0.0, "PB buy"));
     }
   if(emaF < emaS1 && emaS1 < emaS3 && high1 >= emaF - touch && close1 < emaF && close1 < open1)
     {
      double slDist = MathMax(S[idx].slAtr * atr, (high1 + 0.2 * atr) - bid);
      return(OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, 0.0, "PB sell"));
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   int perStrategy[];
   int total = CountPositions(perStrategy);

   // 1. Gestione: sempre, senza filtri
   if(total > 0) ManageAllPositions(perStrategy, total);
   total = CountPositions(perStrategy);
   if(total >= InpMaxPositions) return;

   // 2. Filtri globali per i nuovi ingressi
   if(!GlobalEntryFiltersOk()) return;

   double lots = NormalizeLot(InpLotSize);

   // 3. Strategie: una posizione per strategia, una apertura per candela
   for(int i = 0; i < N_STRATEGIES; i++)
     {
      if(!S[i].enabled || perStrategy[i] > 0) continue;
      if(iTime(_Symbol, S[i].tf, 0) == S[i].lastEntryBar) continue;

      bool opened = false;
      switch(i)
        {
         case IDX_RNG: opened = TryRNG(lots); break;
         case IDX_MOM: opened = TryMOM(lots); break;
         case IDX_BRK: opened = TryBRK(lots); break;
         case IDX_PB:  opened = TryPB(lots);  break;
        }
      if(opened) return;   // massimo un ingresso per tick
     }
  }
//+------------------------------------------------------------------+
