//+------------------------------------------------------------------+
//|                                                   ScalperBot.mq5 |
//|                                   Copyright 2026, Mazzeo/Tavelli |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "7.61"
#define BOT_VERSION "7.61"

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
//|                                                                  |
//| v7.10: filtro spread in % di R (funziona su qualsiasi simbolo),  |
//| lotto ridotto se il rischio supera il tetto, BE che copre le     |
//| commissioni reali, stato sempre visibile sul grafico e nel       |
//| journal con il motivo per cui ogni strategia sta aspettando.     |
//|                                                                  |
//| v7.50: filtro di direzione sul timeframe alto (EMA H1) per tutte |
//| le strategie, e MEMORIA: il bot rilegge il proprio storico e     |
//| blocca le combinazioni strategia/verso/fascia oraria che negli   |
//| ultimi giorni hanno perso (finestra scorrevole: le riprova       |
//| quando le vecchie perdite escono dalla finestra).                |
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

enum ENUM_LOT_MODE
  {
   LOT_RISK_PCT,    // Lotto calcolato: rischia InpRiskPct % del capitale per trade (entro il tetto in euro)
   LOT_FIT_RISK,    // Lotto fisso InpLotSize, ridotto se il rischio supera il tetto
   LOT_FIXED_SKIP   // Lotto fisso InpLotSize: se il rischio supera il tetto salta l'ingresso
  };

enum ENUM_BOX_MODE
  {
   BOX_CANDLES,   // Box = ultime N candele chiuse
   BOX_SESSION    // Box = sessione oraria (es. asiatica), breakout dopo la chiusura
  };

// --- PARAMETRI DI INPUT
input group "--- Generali ---"
input ENUM_LOT_MODE InpLotMode   = LOT_RISK_PCT; // Come si calcola il lotto
input double   InpRiskPct        = 4.0;      // Rischio per trade in % del capitale (modo LOT_RISK_PCT)
input double   InpLotSize        = 0.25;     // Lotto fisso (modi LOT_FIT_RISK / LOT_FIXED_SKIP) e lotto massimo in LOT_RISK_PCT
input ulong    InpMagicBase      = 998870;   // Magic number base (ogni strategia usa base+indice)
input int      InpMaxPositions   = 3;        // Posizioni aperte massime (tutte le strategie)
input double   InpMaxSpreadPctR  = 25.0;     // Spread massimo in % dello Stop Loss (R) della strategia
input int      InpMaxSpread      = 0;        // Spread massimo assoluto (Punti), 0 = off (vale solo quello in % di R)
input int      InpSlippage       = 20;       // Slippage minimo (Punti): si usa il maggiore tra questo e il 10% di R
input int      InpStatusEveryMin = 5;        // Ogni quanti minuti scrivere lo stato nel journal (0 = solo sul grafico)

input group "--- Rischio ---"
input ENUM_SL_MODE InpSlMode     = SL_ATR;   // Come si calcola lo Stop Loss
input double   InpMaxLossMoney   = 18.0;     // Perdita massima per posizione (€): tetto o SL fisso (6% del conto da 300€)
input double   InpBeR            = 0.5;      // A +X R porta lo SL a Break-Even
input int      InpBeBufferPoints = 5;        // Buffer minimo oltre l'apertura per il Break-Even (le commissioni reali si aggiungono da sole)
input double   InpTp1R           = 1.0;      // A +X R chiude lo scalp (parziale se runner, totale altrimenti)
input double   InpScalpPct       = 50.0;     // % di posizione chiusa allo scalp (se runner attivo)
input double   InpLockR          = 0.5;      // Dopo lo scalp, SL a +X R
input double   InpTp2R           = 3.0;      // Target finale del runner (R)
input double   InpTrailAtrMult   = 1.5;      // Trailing del runner: estremo dall'ingresso - ATR x X
input double   InpTrailStepPctR  = 10.0;     // Trailing: sposta lo SL solo se migliora di almeno X% di R
input bool     InpCommissionPerSide = true;  // Commissione addebitata sia in entrata che in uscita

input group "--- Protezioni giornaliere ---"
input double   InpMaxDailyLoss   = 75.0;     // Perdita massima giornaliera (€), 0 = off (25% del conto da 300€)
input double   InpDailyTarget    = 150.0;    // Obiettivo giornaliero (€): raggiunto, niente nuovi ingressi; 0 = off
input int      InpMaxConsecLosses = 3;       // Perdite consecutive prima della pausa, 0 = off
input int      InpPauseMinutes   = 60;       // Durata pausa dopo le perdite consecutive
input int      InpMinSecBetweenTrades = 30;  // Attesa minima tra due ingressi (secondi)
input int      InpStartHour      = 1;        // Ora server inizio operatività (0-23)
input int      InpEndHour        = 23;       // Ora server fine operatività (1-24); 0-24 = sempre. 1-23: salta la pausa dell'oro e l'ora peggiore del test

input group "--- Filtri di regime (ADX) ---"
input int      InpAdxPeriod      = 14;
input double   InpAdxRangeMax    = 20.0;     // RNG solo se ADX < X (mercato laterale)
input double   InpAdxTrendMin    = 22.0;     // MOM e PB solo se ADX >= X (mercato direzionale)
input int      InpAtrPeriod      = 14;

input group "--- Filtro di direzione (timeframe alto) ---"
input bool            InpTrendFilter    = true;       // Opera solo nel verso del trend del timeframe alto
input ENUM_TIMEFRAMES InpTrendTf        = PERIOD_H1;  // Timeframe del trend
input int             InpTrendEma       = 50;         // Periodo della EMA di trend
input bool            InpTrendNeedSlope = true;       // Serve anche la EMA inclinata nel verso (no = basta prezzo sopra/sotto)
input bool            InpTrendInvert    = true;       // Controtrend: opera solo CONTRO il verso del timeframe alto
input double          InpTrendMaxSlope  = 0.30;       // Pendenza massima della EMA (in ATR del suo timeframe, 0 = off): niente ingressi se il trend e' troppo forte
input double          InpMinAtr         = 2.5;        // ATR minimo della strategia per entrare (in prezzo, 0 = off): evita gli stop da rumore

input group "--- Memoria: impara dagli errori ---"
input bool     InpLearnEnabled   = true;   // Blocca le combinazioni strategia/verso/fascia oraria in perdita
input int      InpLearnDays      = 10;     // Giorni di storico considerati (finestra scorrevole)
input int      InpLearnMinTrades = 8;      // Trade minimi nella combinazione prima di giudicarla
input double   InpLearnBlockR    = -3.0;   // Blocco se la somma dei risultati in R e' sotto questa soglia
input int      InpLearnHourBlock = 3;      // Ampiezza della fascia oraria (ore server)

input group "--- 0. RNG: range mean-reversion ---"
input bool     InpRngEnabled     = false;
input ENUM_TIMEFRAMES InpRngTf   = PERIOD_M1;
input int      InpRngCandles     = 20;       // Candele chiuse che definiscono il box
input double   InpRngMaxAtr      = 1.5;      // Ampiezza massima del box (x ATR)
input double   InpRngMinAtr      = 0.6;      // Ampiezza minima del box (x ATR): sotto non vale la pena
input double   InpRngTolAtr      = 0.10;     // Tolleranza sui bordi (x ATR)
input double   InpRngSlAtr       = 0.8;      // SL (x ATR)
input double   InpRngMinRR       = 0.8;      // Rapporto minimo TP/SL per entrare

input group "--- 1. MOM: momentum candela ---"
input bool     InpMomEnabled     = false;
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
input ENUM_TIMEFRAMES InpPbTf    = PERIOD_M5;
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
string   g_why[N_STRATEGIES];    // perché ogni strategia sta aspettando (mostrato sul grafico)
string   g_globalWhy   = "";     // perché gli ingressi sono bloccati per tutte
datetime g_lastStatusLog = 0;

// Filtro di direzione
int      g_hTrend    = INVALID_HANDLE;
int      g_hTrendAtr = INVALID_HANDLE;
double   g_trendSlope = 0.0;   // pendenza EMA (e1-e3) in ATR del timeframe di trend, aggiornata da TrendDir

// Memoria: risultati per strategia / verso (0 buy, 1 sell) / fascia oraria
#define LEARN_MAX_BLOCKS 24
struct LearnBucket
  {
   int    n;
   double sumR;
   bool   blocked;
  };
LearnBucket g_mem[N_STRATEGIES][2][LEARN_MAX_BLOCKS];
datetime g_memBuilt  = 0;
int      g_prevTotal = 0;
int      g_memBlocked = 0;

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

   for(int i = 0; i < N_STRATEGIES; i++) g_why[i] = "in attesa del primo tick";

   if(InpTrendFilter)
     {
      g_hTrend = iMA(_Symbol, InpTrendTf, InpTrendEma, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hTrend == INVALID_HANDLE) { Print("ERRORE: EMA di trend non creata"); return(INIT_FAILED); }
      g_hTrendAtr = iATR(_Symbol, InpTrendTf, 14);   // serve anche solo per mostrare la pendenza nello stato
      if(g_hTrendAtr == INVALID_HANDLE) { Print("ERRORE: ATR di trend non creato"); return(INIT_FAILED); }
     }
   if(InpLearnEnabled && (InpLearnHourBlock < 1 || InpLearnHourBlock > 24 || InpLearnDays < 1 || InpLearnMinTrades < 1))
     {
      Print("ERRORE: InpLearnHourBlock 1-24, InpLearnDays >= 1, InpLearnMinTrades >= 1");
      return(INIT_PARAMETERS_INCORRECT);
     }
   for(int i = 0; i < N_STRATEGIES; i++)
      for(int d = 0; d < 2; d++)
         for(int h = 0; h < LEARN_MAX_BLOCKS; h++) { g_mem[i][d][h].n = 0; g_mem[i][d][h].sumR = 0.0; g_mem[i][d][h].blocked = false; }
   g_memBuilt = 0;

   double lots   = NormalizeLot(InpLotSize);
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   PrintFormat("ScalperBot v" + BOT_VERSION + " su %s | digits %d | point %s | contratto %.2f | tick value %.4f | tick size %s | stops level %d pt | spread ora %d pt",
               _Symbol, _Digits, DoubleToString(_Point, _Digits), SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), _Digits),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), (int)spread);
   string lotMode = (InpLotMode == LOT_RISK_PCT) ? StringFormat("calcolato: %.1f%% di %.0f€ = %.0f€ a trade (max %.2f lotti)", InpRiskPct, AccountInfoDouble(ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0, InpLotSize)
                    : (InpLotMode == LOT_FIT_RISK) ? "fisso, ridotto se il rischio supera il tetto" : "fisso, salta se il rischio supera il tetto";
   PrintFormat("Lotto max %.2f: 1 punto = %.4f€, spread ora = %.2f€ | tetto %.0f€ | lotto %s",
               lots, PriceToMoney(_Point, lots), PriceToMoney(spread * _Point, lots), InpMaxLossMoney, lotMode);
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
      PrintFormat("ATTENZIONE: spread %d pt > InpMaxSpread %d: nessun ingresso finché non scende", (int)spread, InpMaxSpread);
   if(InpTrendFilter) PrintFormat("Filtro di direzione: EMA%d %s%s%s%s", InpTrendEma, TfName(InpTrendTf), InpTrendNeedSlope ? " con pendenza" : "", InpTrendInvert ? " (CONTROTREND)" : "",
                                  (InpTrendMaxSlope > 0.0) ? StringFormat(", fermo se la pendenza supera %.2f ATR", InpTrendMaxSlope) : "");
   if(InpMinAtr > 0.0) PrintFormat("ATR minimo per entrare: %s", DoubleToString(InpMinAtr, _Digits));
   if(InpLearnEnabled) PrintFormat("Memoria: ultimi %d giorni, fasce di %d ore, blocco sotto %.1fR con almeno %d trade", InpLearnDays, InpLearnHourBlock, InpLearnBlockR, InpLearnMinTrades);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   Comment("");
   for(int i = 0; i < N_STRATEGIES; i++)
     {
      if(S[i].hAtr     != INVALID_HANDLE) IndicatorRelease(S[i].hAtr);
      if(S[i].hAdx     != INVALID_HANDLE) IndicatorRelease(S[i].hAdx);
      if(S[i].hEmaFast != INVALID_HANDLE) IndicatorRelease(S[i].hEmaFast);
      if(S[i].hEmaSlow != INVALID_HANDLE) IndicatorRelease(S[i].hEmaSlow);
     }
   if(g_hTrend != INVALID_HANDLE) IndicatorRelease(g_hTrend);
   if(g_hTrendAtr != INVALID_HANDLE) IndicatorRelease(g_hTrendAtr);
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
   g_globalWhy = "";
   if(now - lastTradeTime < InpMinSecBetweenTrades)
     { g_globalWhy = StringFormat("cooldown %d s dopo l'ultimo ingresso", InpMinSecBetweenTrades); return(false); }
   if(now < pauseUntil)
     { g_globalWhy = "pausa dopo perdite consecutive fino alle " + TimeToString(pauseUntil, TIME_MINUTES); return(false); }
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
     { g_globalWhy = StringFormat("spread %d pt > InpMaxSpread %d", (int)spread, InpMaxSpread); return(false); }

   if(!(InpStartHour == 0 && InpEndHour == 24))
     {
      MqlDateTime t;
      TimeToStruct(now, t);
      bool inside = (InpStartHour < InpEndHour)
                    ? (t.hour >= InpStartHour && t.hour < InpEndHour)
                    : (t.hour >= InpStartHour || t.hour < InpEndHour);
      if(!inside) { g_globalWhy = StringFormat("fuori fascia oraria %02d-%02d (ora server %02d)", InpStartHour, InpEndHour, t.hour); return(false); }
     }

   if(InpMaxDailyLoss > 0.0 || InpMaxConsecLosses > 0 || InpDailyTarget > 0.0)
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
            g_globalWhy = "pausa dopo perdite consecutive fino alle " + TimeToString(until, TIME_MINUTES);
            return(false);
           }
        }
      double dailyPnL = realized + FloatingNetPnL();
      if(InpDailyTarget > 0.0 && dailyPnL >= InpDailyTarget)
        {
         static datetime lastTargetLog = 0;
         if(now - lastTargetLog > 600)
           {
            PrintFormat("OBIETTIVO GIORNALIERO raggiunto: %+.2f€ (target %.0f€). Nessun nuovo ingresso oggi.", dailyPnL, InpDailyTarget);
            lastTargetLog = now;
           }
         g_globalWhy = StringFormat("obiettivo raggiunto: oggi %+.2f€ (target %.0f€)", dailyPnL, InpDailyTarget);
         return(false);
        }
      if(InpMaxDailyLoss > 0.0)
        {
         if(dailyPnL <= -MathAbs(InpMaxDailyLoss))
           {
            static datetime lastWarn = 0;
            if(now - lastWarn > 600)
              {
               PrintFormat("LIMITE GIORNALIERO: %.2f€ (limite -%.2f€). Nessun nuovo ingresso oggi.", dailyPnL, InpMaxDailyLoss);
               lastWarn = now;
              }
            g_globalWhy = StringFormat("limite giornaliero: oggi %.2f€ (limite -%.0f€)", dailyPnL, InpMaxDailyLoss);
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
//| Filtro di direzione: +1 trend su, -1 giu', 0 neutro/non pronto   |
//+------------------------------------------------------------------+
int TrendDir(string &why)
  {
   why = "";
   double e1 = Ind(g_hTrend, 0, 1), e3 = Ind(g_hTrend, 0, 3);
   double c1 = iClose(_Symbol, InpTrendTf, 1);
   if(e1 == EMPTY_VALUE || e3 == EMPTY_VALUE || c1 <= 0.0) { why = "EMA di trend non pronta"; return(0); }
   bool up = (c1 > e1) && (!InpTrendNeedSlope || e1 > e3);
   bool dn = (c1 < e1) && (!InpTrendNeedSlope || e1 < e3);
   // Forza del trend: quanto si e' mossa la EMA in due candele, in ATR del suo timeframe.
   // Oltre la soglia il trend e' troppo forte per andargli contro (e troppo maturo per inseguirlo).
   if(g_hTrendAtr != INVALID_HANDLE)
     {
      double atrTf = Ind(g_hTrendAtr, 0, 1);
      g_trendSlope = (atrTf != EMPTY_VALUE && atrTf > 0.0) ? (e1 - e3) / atrTf : 0.0;
      if(InpTrendMaxSlope > 0.0 && MathAbs(g_trendSlope) > InpTrendMaxSlope && (up || dn))
        {
         why = StringFormat("trend %s troppo forte (pendenza EMA%d %.2f ATR > %.2f)", TfName(InpTrendTf), InpTrendEma, MathAbs(g_trendSlope), InpTrendMaxSlope);
         return(0);
        }
     }
   if(up) return(1);
   if(dn) return(-1);
   why = StringFormat("%s neutro (prezzo %s EMA%d, EMA %s)", TfName(InpTrendTf), (c1 > e1) ? "sopra" : "sotto", InpTrendEma, (e1 > e3) ? "sale" : "scende");
   return(0);
  }

//+------------------------------------------------------------------+
//| Memoria: rilegge lo storico del conto (solo i nostri magic) e    |
//| somma i risultati in R per strategia / verso / fascia oraria.    |
//| Una combinazione con almeno InpLearnMinTrades trade e somma      |
//| <= InpLearnBlockR viene bloccata finche' le vecchie perdite non  |
//| escono dalla finestra di InpLearnDays giorni.                    |
//+------------------------------------------------------------------+
string LearnBucketName(int idx, int dir, int hb)
  {
   int h0 = hb * InpLearnHourBlock, h1 = MathMin(24, h0 + InpLearnHourBlock);
   return(StringFormat("%s %s %02d-%02d", S[idx].tag, (dir == 0) ? "buy" : "sell", h0, h1));
  }

void LearnRebuild()
  {
   if(!InpLearnEnabled) return;
   datetime now = TimeCurrent();
   g_memBuilt = now;
   for(int i = 0; i < N_STRATEGIES; i++)
      for(int d = 0; d < 2; d++)
         for(int h = 0; h < LEARN_MAX_BLOCKS; h++) { g_mem[i][d][h].n = 0; g_mem[i][d][h].sumR = 0.0; }

   if(!HistorySelect(now - (datetime)InpLearnDays * 86400, now + 60)) return;

   // 1. deal -> posizioni (apertura: strategia, verso, ora, ordine; chiusure: P&L)
   long   ids[];  int pidx[]; int pdir[]; int phb[]; ulong pord[]; double ppnl[]; bool pclosed[]; double prisk[];
   int n = 0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      int idx;
      if(!IsOurMagic(HistoryDealGetInteger(deal, DEAL_MAGIC), idx)) continue;
      long posId = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      int k = -1;
      for(int j = 0; j < n; j++) if(ids[j] == posId) { k = j; break; }
      if(k < 0)
        {
         k = n++;
         ArrayResize(ids, n); ArrayResize(pidx, n); ArrayResize(pdir, n); ArrayResize(phb, n);
         ArrayResize(pord, n); ArrayResize(ppnl, n); ArrayResize(pclosed, n); ArrayResize(prisk, n);
         ids[k] = posId; pidx[k] = idx; pdir[k] = -1; phb[k] = -1; pord[k] = 0; ppnl[k] = 0.0; pclosed[k] = false; prisk[k] = 0.0;
        }
      double net = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
                   + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      ppnl[k] += net;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
        {
         pdir[k] = (HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BUY) ? 0 : 1;
         MqlDateTime t; TimeToStruct((datetime)HistoryDealGetInteger(deal, DEAL_TIME), t);
         phb[k]  = t.hour / InpLearnHourBlock;
         pord[k] = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
         string c = HistoryDealGetString(deal, DEAL_COMMENT);
         int rp = StringFind(c, " r");
         if(rp >= 0) prisk[k] = StringToDouble(StringSubstr(c, rp + 2));
        }
      else
         pclosed[k] = true;
     }

   // 2. rischio iniziale dall'ordine di apertura (SL) -> risultato in R
   int used = 0, noOrder = 0, noSl = 0, noRisk = 0;
   for(int k = 0; k < n; k++)
     {
      if(!pclosed[k] || pdir[k] < 0) continue;
      double risk = prisk[k];
      if(risk <= 0.0)   // trade aperti da versioni precedenti: rischio dallo SL dell'ordine di apertura
        {
         if(pord[k] == 0 || !HistoryOrderSelect(pord[k])) { noOrder++; continue; }
         double sl    = HistoryOrderGetDouble(pord[k], ORDER_SL);
         double price = HistoryOrderGetDouble(pord[k], ORDER_PRICE_OPEN);
         double vol   = HistoryOrderGetDouble(pord[k], ORDER_VOLUME_INITIAL);
         if(sl <= 0.0 || price <= 0.0 || vol <= 0.0) { noSl++; continue; }
         risk = PriceToMoney(MathAbs(price - sl), vol);
        }
      if(risk <= 0.0) { noRisk++; continue; }
      LearnBucket b = g_mem[pidx[k]][pdir[k]][phb[k]];
      b.n++; b.sumR += ppnl[k] / risk;
      g_mem[pidx[k]][pdir[k]][phb[k]] = b;
      used++;
     }
   static int lastUsed = -1;
   if(used != lastUsed && (used == 0 || used % 25 == 0 || !MQLInfoInteger(MQL_TESTER)))
     {
      lastUsed = used;
      int bi = 0, bd = 0, bh = 0;
      for(int i = 0; i < N_STRATEGIES; i++) for(int d = 0; d < 2; d++) for(int h = 0; h < LEARN_MAX_BLOCKS; h++)
         if(g_mem[i][d][h].n > g_mem[bi][bd][bh].n) { bi = i; bd = d; bh = h; }
      PrintFormat("MEMORIA: %d posizioni nello storico, %d usate (senza ordine %d, senza SL %d, senza rischio %d) | piu' popolata: %s %+.1fR su %d",
                  n, used, noOrder, noSl, noRisk, LearnBucketName(bi, bd, bh), g_mem[bi][bd][bh].sumR, g_mem[bi][bd][bh].n);
     }

   // 3. blocchi
   g_memBlocked = 0;
   for(int i = 0; i < N_STRATEGIES; i++)
      for(int d = 0; d < 2; d++)
         for(int h = 0; h < LEARN_MAX_BLOCKS; h++)
           {
            bool blk = (g_mem[i][d][h].n >= InpLearnMinTrades && g_mem[i][d][h].sumR <= InpLearnBlockR);
            if(blk != g_mem[i][d][h].blocked)
              {
               if(blk) PrintFormat("IMPARATO: %s bloccata (%+.1fR su %d trade negli ultimi %d giorni)", LearnBucketName(i, d, h), g_mem[i][d][h].sumR, g_mem[i][d][h].n, InpLearnDays);
               else    PrintFormat("MEMORIA: %s riabilitata (%+.1fR su %d trade)", LearnBucketName(i, d, h), g_mem[i][d][h].sumR, g_mem[i][d][h].n);
               g_mem[i][d][h].blocked = blk;
              }
            if(blk) g_memBlocked++;
           }
  }

// Ricostruisce la memoria al primo tick, quando una posizione si chiude, e comunque ogni 15 minuti
void LearnMaybeRebuild(int total)
  {
   if(!InpLearnEnabled) return;
   datetime now = TimeCurrent();
   bool closedSomething = (total < g_prevTotal);
   g_prevTotal = total;
   if(g_memBuilt == 0 || closedSomething || now - g_memBuilt >= 900) LearnRebuild();
  }

bool LearnBlocked(int idx, ENUM_ORDER_TYPE type, string &why)
  {
   if(!InpLearnEnabled) return(false);
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   int hb = t.hour / InpLearnHourBlock;
   int d  = (type == ORDER_TYPE_BUY) ? 0 : 1;
   if(!g_mem[idx][d][hb].blocked) return(false);
   why = StringFormat("memoria: %s bloccata (%+.1fR su %d)", LearnBucketName(idx, d, hb), g_mem[idx][d][hb].sumR, g_mem[idx][d][hb].n);
   return(true);
  }

string LearnSummary()
  {
   if(!InpLearnEnabled) return("memoria: off");
   if(g_memBlocked == 0) return("memoria: nessuna combinazione bloccata");
   string s = "";
   int shown = 0;
   for(int i = 0; i < N_STRATEGIES; i++)
      for(int d = 0; d < 2; d++)
         for(int h = 0; h < LEARN_MAX_BLOCKS; h++)
            if(g_mem[i][d][h].blocked)
              {
               if(shown < 6) s += ((shown > 0) ? ", " : "") + LearnBucketName(i, d, h);
               shown++;
              }
   if(shown > 6) s += StringFormat(" +%d", shown - 6);
   return(StringFormat("memoria: %d bloccate: %s", g_memBlocked, s));
  }

//+------------------------------------------------------------------+
//| Apre una posizione della strategia idx.                          |
//| slDist: distanza SL in prezzo (R). tpPrice>0: TP forzato (RNG).  |
//+------------------------------------------------------------------+
bool OpenPosition(int idx, ENUM_ORDER_TYPE type, double lots, double slDist, double tpPrice, string comment)
  {
   if(InpMinAtr > 0.0)
     {
      double atrNow = Ind(S[idx].hAtr, 0, 1);
      if(atrNow != EMPTY_VALUE && atrNow < InpMinAtr)
        {
         g_why[idx] = StringFormat("segnale %s ma ATR %s < minimo %s: troppo poco movimento", comment, DoubleToString(atrNow, _Digits), DoubleToString(InpMinAtr, _Digits));
         return(false);
        }
     }
   if(InpTrendFilter)
     {
      string why;
      int dir  = TrendDir(why);
      int want = (type == ORDER_TYPE_BUY) ? 1 : -1;
      if(InpTrendInvert) want = -want;
      if(dir == 0)    { g_why[idx] = "segnale " + comment + " ma " + why; return(false); }
      if(dir != want) { g_why[idx] = StringFormat("segnale %s %s il trend %s (EMA%d %s)", comment, InpTrendInvert ? "nel verso del" : "contro il", TfName(InpTrendTf), InpTrendEma, (dir > 0) ? "su" : "giu'"); return(false); }
     }
   string memWhy;
   if(LearnBlocked(idx, type, memWhy)) { g_why[idx] = memWhy; return(false); }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MinStopDistance();

   if(InpSlMode == SL_MONEY) slDist = MoneyToPrice(InpMaxLossMoney, lots);
   slDist = MathMax(slDist, minDist);
   if(slDist <= 0.0) { g_why[idx] = "SL non calcolabile"; return(false); }

   // Spread in rapporto allo stop: oltre la soglia lo scalp non ha senso
   double spreadPrice = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double spreadPct   = 100.0 * spreadPrice / slDist;
   if(spreadPct > InpMaxSpreadPctR)
     {
      g_why[idx] = StringFormat("spread %.0f%% di R > %.0f%%", spreadPct, InpMaxSpreadPctR);
      return(false);
     }

   // Lotto dal rischio: X% del capitale, entro il tetto in euro e il lotto massimo
   double riskPerLot = PriceToMoney(slDist, 1.0);
   if(InpLotMode == LOT_RISK_PCT)
     {
      if(riskPerLot <= 0.0) { g_why[idx] = "tick value non disponibile"; return(false); }
      double budget = MathMin(AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0, InpMaxLossMoney);
      double wanted = budget / riskPerLot;
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(wanted < minLot)
        {
         g_why[idx] = StringFormat("rischio %.0f€ al lotto minimo > budget %.0f€", riskPerLot * minLot, budget);
         return(false);
        }
      lots = NormalizeLot(MathMin(wanted, InpLotSize));
     }
   double riskMoney = riskPerLot * lots;

   // Tetto di perdita in euro: riduci il lotto oppure salta
   if(riskMoney > InpMaxLossMoney + 0.01)
     {
      if(InpLotMode != LOT_FIXED_SKIP && riskPerLot > 0.0)
        {
         double fitted = NormalizeLot(InpMaxLossMoney / riskPerLot);
         if(riskPerLot * fitted > InpMaxLossMoney + 0.01)
           {
            g_why[idx] = StringFormat("rischio %.0f€ al lotto minimo > tetto %.0f€", riskPerLot * fitted, InpMaxLossMoney);
            return(false);
           }
         PrintFormat("%s: lotto %.2f -> %.2f per restare nel tetto di %.0f€ (R=%s)", S[idx].tag, lots, fitted, InpMaxLossMoney, DoubleToString(slDist, _Digits));
         lots = fitted;
         riskMoney = riskPerLot * lots;
        }
      else
        {
         g_why[idx] = StringFormat("rischio %.0f€ > tetto %.0f€ (lotto fisso)", riskMoney, InpMaxLossMoney);
         PrintFormat("SKIP %s: rischio %.2f€ > tetto %.2f€ (SL %s)", S[idx].tag, riskMoney, InpMaxLossMoney, DoubleToString(slDist, _Digits));
         return(false);
        }
     }
   trade.SetDeviationInPoints((int)MathMax(InpSlippage, MathRound(0.1 * slDist / _Point)));

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
   // Il rischio iniziale viaggia nel commento (es. "PB sell r38.14"): la memoria lo rilegge dallo storico
   string orderComment = comment + StringFormat(" r%.2f", riskMoney);
   bool sent = (type == ORDER_TYPE_BUY)
               ? trade.Buy(lots, _Symbol, ask, sl, tp, orderComment)
               : trade.Sell(lots, _Symbol, bid, sl, tp, orderComment);
   bool ok = sent && LogTradeResult(comment);
   if(ok)
     {
      lastTradeTime = TimeCurrent();
      S[idx].lastEntryBar = iTime(_Symbol, S[idx].tf, 0);
      g_why[idx] = "in posizione";
      PrintFormat("  %s %.2f lotti, rischio %.2f€ (R=%s), spread %.0f%% di R, TP %s, pendenza trend %.2f ATR", S[idx].tag, lots, riskMoney, DoubleToString(slDist, _Digits), spreadPct, DoubleToString(tp, _Digits), g_trendSlope);
     }
   else
      g_why[idx] = "ordine rifiutato: " + trade.ResultRetcodeDescription();
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
      double beBuffer = MathMax(InpBeBufferPoints * _Point, MoneyToPrice(-info.commission, volume));
      newSL = openPrice + dir * beBuffer;
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
   // Il trailing si muove a scatti (min % di R): niente modifica a ogni tick
   if(why == "trail" && MathAbs(newSL - PositionGetDouble(POSITION_SL)) < InpTrailStepPctR / 100.0 * R)
      newSL = 0.0;
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
   if(atr == EMPTY_VALUE || adx == EMPTY_VALUE || atr <= 0.0) { g_why[idx] = "indicatori non pronti"; return(false); }
   if(adx >= InpAdxRangeMax) { g_why[idx] = StringFormat("ADX %.0f >= %.0f: mercato non laterale", adx, InpAdxRangeMax); return(false); }

   double hi, lo;
   if(!BoxOfCandles(tf, InpRngCandles, 1, hi, lo)) { g_why[idx] = "box non calcolabile"; return(false); }
   double width = hi - lo;
   if(width > InpRngMaxAtr * atr) { g_why[idx] = StringFormat("box %.1f ATR > %.1f: troppo largo", width / atr, InpRngMaxAtr); return(false); }
   if(width < InpRngMinAtr * atr) { g_why[idx] = StringFormat("box %.1f ATR < %.1f: troppo stretto", width / atr, InpRngMinAtr); return(false); }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tol = InpRngTolAtr * atr;
   double body0 = iClose(_Symbol, tf, 0) - iOpen(_Symbol, tf, 0);
   double push  = InpMomMinBodyAtr * atr;
   double slDist = S[idx].slAtr * atr;

   // SELL sul bordo alto: prezzo dentro il box, candela corrente non in rottura
   if(bid >= hi - tol && bid <= hi + tol)
     {
      if(body0 >= push) { g_why[idx] = "sul bordo alto ma la candela sta rompendo"; return(false); }
      double tp = lo + tol;
      double rr = (bid - tp) / slDist;
      if(rr < InpRngMinRR) { g_why[idx] = StringFormat("bordo alto, RR %.2f < %.2f", rr, InpRngMinRR); return(false); }
      return(OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, tp, "RNG sell"));
     }
   if(ask <= lo + tol && ask >= lo - tol)
     {
      if(body0 <= -push) { g_why[idx] = "sul bordo basso ma la candela sta rompendo"; return(false); }
      double tp = hi - tol;
      double rr = (tp - ask) / slDist;
      if(rr < InpRngMinRR) { g_why[idx] = StringFormat("bordo basso, RR %.2f < %.2f", rr, InpRngMinRR); return(false); }
      return(OpenPosition(idx, ORDER_TYPE_BUY, lots, slDist, tp, "RNG buy"));
     }
   g_why[idx] = StringFormat("box ok (%.1f ATR), prezzo lontano dai bordi", width / atr);
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
   if(atr == EMPTY_VALUE || adx == EMPTY_VALUE || atr <= 0.0) { g_why[idx] = "indicatori non pronti"; return(false); }
   if(adx < InpAdxTrendMin) { g_why[idx] = StringFormat("ADX %.0f < %.0f: mercato non direzionale", adx, InpAdxTrendMin); return(false); }

   double body = iClose(_Symbol, tf, 0) - iOpen(_Symbol, tf, 0);
   double minB = InpMomMinBodyAtr * atr, maxB = InpMomMaxBodyAtr * atr;
   double slDist = S[idx].slAtr * atr;
   double bodyAtr = body / atr;

   if(MathAbs(body) < minB) { g_why[idx] = StringFormat("ADX %.0f ok, corpo %.2f ATR (serve >= %.1f)", adx, bodyAtr, InpMomMinBodyAtr); return(false); }
   if(MathAbs(body) > maxB) { g_why[idx] = StringFormat("corpo %.2f ATR > %.1f: non inseguo", bodyAtr, InpMomMaxBodyAtr); return(false); }
   if(body > 0.0 && plusDI <= minusDI) { g_why[idx] = "candela verde ma -DI > +DI: contro trend"; return(false); }
   if(body < 0.0 && minusDI <= plusDI) { g_why[idx] = "candela rossa ma +DI > -DI: contro trend"; return(false); }

   if(body > 0.0) return(OpenPosition(idx, ORDER_TYPE_BUY,  lots, slDist, 0.0, "MOM buy"));
   return(OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, 0.0, "MOM sell"));
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

   double atr = Ind(S[idx].hAtr, 0, 1);
   if(atr == EMPTY_VALUE || atr <= 0.0) { g_why[idx] = "indicatori non pronti"; return(false); }   // senza segnare la candela: si riprova al tick dopo
   S[idx].lastSignalBar = bar0;

   double hi, lo;
   if(InpBrkBoxMode == BOX_CANDLES)
     {
      if(!BoxOfCandles(tf, InpBrkCandles, 2, hi, lo)) { g_why[idx] = "box non calcolabile"; return(false); }
     }
   else
     {
      MqlDateTime t; TimeToStruct(TimeCurrent(), t);
      if(t.hour >= InpBrkSessionUntil) { g_why[idx] = StringFormat("sessione: breakout valido solo fino alle %02d", InpBrkSessionUntil); return(false); }
      if(S[idx].sessionTradeDay == t.day_of_year) { g_why[idx] = "sessione: breakout già fatto oggi"; return(false); }
      if(!BoxOfSession(tf, hi, lo)) { g_why[idx] = StringFormat("sessione %02d-%02d non ancora chiusa", InpBrkSessionStart, InpBrkSessionEnd); return(false); }
     }
   if(hi - lo > InpBrkBoxMaxAtr * atr) { g_why[idx] = StringFormat("box %.1f ATR > %.1f: troppo largo", (hi - lo) / atr, InpBrkBoxMaxAtr); return(false); }

   double open1 = iOpen(_Symbol, tf, 1), close1 = iClose(_Symbol, tf, 1);
   double body1 = close1 - open1;
   double buffer = InpBrkBufferAtr * atr;
   double slDist = S[idx].slAtr * atr;
   bool ok = false;

   if(close1 > hi + buffer)
     {
      if(body1 < InpBrkMinBodyAtr * atr) { g_why[idx] = StringFormat("rottura sopra ma corpo %.2f ATR < %.1f", body1 / atr, InpBrkMinBodyAtr); return(false); }
      ok = OpenPosition(idx, ORDER_TYPE_BUY, lots, slDist, 0.0, "BRK buy");
     }
   else if(close1 < lo - buffer)
     {
      if(-body1 < InpBrkMinBodyAtr * atr) { g_why[idx] = StringFormat("rottura sotto ma corpo %.2f ATR < %.1f", -body1 / atr, InpBrkMinBodyAtr); return(false); }
      ok = OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, 0.0, "BRK sell");
     }
   else
     {
      g_why[idx] = StringFormat("box ok (%.1f ATR), ultima candela chiusa dentro", (hi - lo) / atr);
      return(false);
     }

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

   double atr  = Ind(S[idx].hAtr, 0, 1);
   double adx  = Ind(S[idx].hAdx, 0, 1);
   double emaF = Ind(S[idx].hEmaFast, 0, 1);
   double emaS1 = Ind(S[idx].hEmaSlow, 0, 1);
   double emaS3 = Ind(S[idx].hEmaSlow, 0, 3);
   if(atr == EMPTY_VALUE || adx == EMPTY_VALUE || emaF == EMPTY_VALUE || emaS1 == EMPTY_VALUE || emaS3 == EMPTY_VALUE || atr <= 0.0)
     { g_why[idx] = "indicatori non pronti"; return(false); }
   S[idx].lastSignalBar = bar0;
   if(adx < InpAdxTrendMin) { g_why[idx] = StringFormat("ADX %.0f < %.0f: mercato non direzionale", adx, InpAdxTrendMin); return(false); }

   double open1 = iOpen(_Symbol, tf, 1), close1 = iClose(_Symbol, tf, 1);
   double high1 = iHigh(_Symbol, tf, 1), low1 = iLow(_Symbol, tf, 1);
   double touch = InpPbTouchAtr * atr;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool upTrend   = (emaF > emaS1 && emaS1 > emaS3);
   bool downTrend = (emaF < emaS1 && emaS1 < emaS3);
   if(!upTrend && !downTrend) { g_why[idx] = StringFormat("ADX %.0f ok, EMA%d/%d non allineate", adx, InpPbEmaFast, InpPbEmaSlow); return(false); }

   if(upTrend)
     {
      if(low1 > emaF + touch) { g_why[idx] = "trend su, nessun pullback sulla EMA"; return(false); }
      if(!(close1 > emaF && close1 > open1)) { g_why[idx] = "trend su, pullback ma candela non conferma"; return(false); }
      double slDist = MathMax(S[idx].slAtr * atr, ask - (low1 - 0.2 * atr));
      return(OpenPosition(idx, ORDER_TYPE_BUY, lots, slDist, 0.0, "PB buy"));
     }
   if(high1 < emaF - touch) { g_why[idx] = "trend giù, nessun pullback sulla EMA"; return(false); }
   if(!(close1 < emaF && close1 < open1)) { g_why[idx] = "trend giù, pullback ma candela non conferma"; return(false); }
   double slDist = MathMax(S[idx].slAtr * atr, (high1 + 0.2 * atr) - bid);
   return(OpenPosition(idx, ORDER_TYPE_SELL, lots, slDist, 0.0, "PB sell"));
  }

//+------------------------------------------------------------------+
//| Stato: sul grafico a ogni tick, nel journal ogni N minuti        |
//+------------------------------------------------------------------+
string TfName(ENUM_TIMEFRAMES tf)
  {
   return(StringSubstr(EnumToString(tf), 7));   // PERIOD_M5 -> M5
  }

void ReportStatus(int total, int &perStrategy[])
  {
   datetime now = TimeCurrent();
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double lots = NormalizeLot(InpLotSize);
   string lines[N_STRATEGIES + 3];

   double realized; int consec; datetime lastLoss;
   TodayStats(realized, consec, lastLoss);
   double todayPnL = realized + FloatingNetPnL();
   string goal = (InpDailyTarget > 0.0) ? StringFormat(" / target +%.0f€", InpDailyTarget) : "";
   lines[0] = StringFormat("ScalperBot v" + BOT_VERSION + " | %s | spread %d pt = %.2f€ | posizioni %d/%d | oggi %+.2f€%s / max -%.0f€ | %s",
                           _Symbol, (int)spread, PriceToMoney(spread * _Point, lots), total, InpMaxPositions,
                           todayPnL, goal, InpMaxDailyLoss, TimeToString(now, TIME_DATE | TIME_MINUTES));
   lines[1] = (g_globalWhy == "") ? "ingressi: aperti" : "INGRESSI BLOCCATI: " + g_globalWhy;

   for(int i = 0; i < N_STRATEGIES; i++)
     {
      string tag = S[i].tag + " " + TfName(S[i].tf);
      if(!S[i].enabled) { lines[i + 2] = tag + " | off"; continue; }
      double atr = Ind(S[i].hAtr, 0, 1);
      if(atr == EMPTY_VALUE || atr <= 0.0) { lines[i + 2] = tag + " | ATR non pronto"; continue; }
      double R   = atr * S[i].slAtr;
      double eur = PriceToMoney(R, lots);
      string cap = "";
      double perLot = PriceToMoney(R, 1.0);
      if(InpLotMode == LOT_RISK_PCT && perLot > 0.0)
        {
         double budget = MathMin(AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0, InpMaxLossMoney);
         double l = NormalizeLot(MathMin(budget / perLot, InpLotSize));
         cap = StringFormat(" | lotto %.2f = %.0f€", l, perLot * l);
        }
      else if(eur > InpMaxLossMoney) cap = (InpLotMode == LOT_FIT_RISK) ? StringFormat(" -> lotto %.2f", NormalizeLot(InpMaxLossMoney / perLot)) : " > TETTO";
      string state = (perStrategy[i] > 0) ? "IN POSIZIONE" : g_why[i];
      lines[i + 2] = StringFormat("%s | ATR %s | R %s%s | spread %.0f%% di R | %s",
                                  tag, DoubleToString(atr, _Digits), DoubleToString(R, _Digits),
                                  (InpLotMode == LOT_RISK_PCT) ? cap : StringFormat(" = %.0f€%s", eur, cap),
                                  100.0 * spread * _Point / R, state);
     }

   lines[N_STRATEGIES + 2] = LearnSummary();
   if(InpTrendFilter)
     {
      string why; int dir = TrendDir(why);
      lines[N_STRATEGIES + 2] += " | trend " + TfName(InpTrendTf) + ": " + ((dir > 0) ? "SU" : (dir < 0) ? "GIU'" : "neutro")
                                 + ((g_hTrendAtr != INVALID_HANDLE) ? StringFormat(" (pendenza %.2f ATR)", g_trendSlope) : "");
     }
   string all = "";
   for(int i = 0; i < N_STRATEGIES + 3; i++) all += lines[i] + "\n";
   Comment(all);

   int every = InpStatusEveryMin;
   if(every <= 0) return;
   if(MQLInfoInteger(MQL_TESTER)) every = MathMax(every, 60);   // nel tester non intasare il journal
   if(g_lastStatusLog != 0 && now - g_lastStatusLog < every * 60) return;
   g_lastStatusLog = now;
   for(int i = 0; i < N_STRATEGIES + 3; i++) Print(lines[i]);
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
   LearnMaybeRebuild(total);

   // 2. Filtri globali per i nuovi ingressi
   g_globalWhy = "";
   if(total >= InpMaxPositions)
      g_globalWhy = StringFormat("%d/%d posizioni aperte", total, InpMaxPositions);
   else if(GlobalEntryFiltersOk())
     {
      double lots = NormalizeLot(InpLotSize);

      // 3. Strategie: una posizione per strategia, una apertura per candela
      for(int i = 0; i < N_STRATEGIES; i++)
        {
         if(!S[i].enabled || perStrategy[i] > 0) continue;
         if(iTime(_Symbol, S[i].tf, 0) == S[i].lastEntryBar) { g_why[i] = "già entrata su questa candela"; continue; }

         bool opened = false;
         switch(i)
           {
            case IDX_RNG: opened = TryRNG(lots); break;
            case IDX_MOM: opened = TryMOM(lots); break;
            case IDX_BRK: opened = TryBRK(lots); break;
            case IDX_PB:  opened = TryPB(lots);  break;
           }
         if(opened) { total++; perStrategy[i]++; break; }   // massimo un ingresso per tick
        }
     }

   ReportStatus(total, perStrategy);
  }
//+------------------------------------------------------------------+
