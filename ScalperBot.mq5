//+------------------------------------------------------------------+
//|                                                   ScalperBot.mq5 |
//|                                   Copyright 2026, Mazzeo/Tavelli |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "6.00"

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| v6.00 - review e correzioni rispetto alla v5.00                  |
//|  - conversione euro -> prezzo con tick value/size reali          |
//|    (la v5 faceva euro/(lotti*10): su XAUUSD 0.1 lotti gli step   |
//|    di SL erano 10 volte più stretti del dichiarato)              |
//|  - cooldown e filtro spread bloccano SOLO i nuovi ingressi, non  |
//|    più la gestione delle posizioni aperte                        |
//|  - SL e TP reali al broker già all'apertura (prima lo stop era   |
//|    solo software: terminale spento = posizione scoperta)         |
//|  - gli step di SL sono monotoni: lo stop non torna mai indietro  |
//|  - niente vendite dentro un breakout: il range si fa solo se il  |
//|    prezzo è ancora DENTRO il box                                 |
//|  - profitto al netto delle commissioni                           |
//|  - limite di perdita giornaliera e filtro orario (opzionali)     |
//|  - tutti i livelli monetari sono input, non più hard-coded       |
//+------------------------------------------------------------------+

// --- PARAMETRI DI INPUT
input group "--- Parametri Generali ---"
input double   InpLotSize        = 0.1;      // Dimensione Lotto base
input double   InpMaxLoss        = 20.0;     // Stop Loss monetario massimo (€) per posizione
input double   InpTakeProfit     = 15.0;     // Take Profit monetario finale (€) per posizione
input int      InpMaxSpread      = 20;       // Spread massimo tollerato per ENTRARE (Punti)
input int      InpSlippage       = 10;       // Slippage massimo (Punti)
input ulong    InpMagicNumber    = 998877;   // Magic Number

input group "--- Step di protezione (€) ---"
input double   InpStep1Trigger   = 2.50;     // Profitto a cui portare lo SL a Break-Even (e piramidare)
input double   InpStep2Trigger   = 5.00;     // Profitto a cui portare lo SL a +Step2Lock
input double   InpStep2Lock      = 2.50;     // Profitto bloccato dallo SL allo Step 2
input double   InpStep3Trigger   = 10.00;    // Profitto a cui portare lo SL a +Step3Lock
input double   InpStep3Lock      = 5.00;     // Profitto bloccato dallo SL allo Step 3
input bool     InpEnablePyramid  = true;     // Apre una seconda posizione allo Step 1
input bool     InpCommissionPerSide = true;  // Il broker addebita la commissione sia in entrata che in uscita

input group "--- Filtri Anti-Overtrading ---"
input int      InpMinSecBetweenTrades = 15;  // Attesa minima in SECONDI tra 2 operazioni
input double   InpMaxDailyLoss   = 50.0;     // Perdita massima giornaliera (€), 0 = disattivato
input int      InpStartHour      = 0;        // Ora server di inizio operatività (0-23)
input int      InpEndHour        = 24;       // Ora server di fine operatività (1-24), 0-24 = sempre

input group "--- Selezione Strategia ---"
enum ENUM_STRATEGY_MODE
  {
   STRATEGY_RANGE_ONLY,     // Solo mean-reversion sul range
   STRATEGY_MOMENTUM_ONLY,  // Solo momentum sulla candela
   STRATEGY_BOTH            // Entrambe (prima il range, poi il momentum)
  };
input ENUM_STRATEGY_MODE InpStrategyMode = STRATEGY_BOTH;

input group "--- Parametri Consolidation Range ---"
input int      InpRangeCandles   = 15;       // Candele (escluse la corrente) che definiscono il box
input double   InpRangeMaxPoints = 150.0;    // Ampiezza massima del box (Punti)
input int      InpRangeTolerance = 10;       // Tolleranza ai bordi del box (Punti)

input group "--- Parametri Momentum Candela ---"
input int      InpMinCandlePoints = 50;      // Corpo minimo della candela corrente (Punti)
input int      InpMaxCandlePoints = 0;       // Corpo massimo: oltre non si insegue (Punti), 0 = nessun limite

// --- VARIABILI GLOBALI
bool     pyramidDone   = false;   // già piramidato in questo ciclo di posizioni
datetime lastTradeTime = 0;
datetime lastBarTime   = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpStep1Trigger >= InpStep2Trigger || InpStep2Trigger >= InpStep3Trigger)
     {
      Print("ERRORE: gli step devono essere crescenti (Step1 < Step2 < Step3)");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpStep2Lock >= InpStep2Trigger || InpStep3Lock >= InpStep3Trigger)
     {
      Print("ERRORE: il profitto bloccato deve essere minore del trigger dello step");
      return(INIT_PARAMETERS_INCORRECT);
     }

   // Se l'EA riparte con posizioni già aperte, non piramida di nuovo
   if(CountOwnPositions() >= 2) pyramidDone = true;

   PrintFormat("ScalperBot v6 avviato su %s. %.2f€ = %s di prezzo per %.2f lotti",
               _Symbol, InpTakeProfit,
               DoubleToString(MoneyToPrice(InpTakeProfit, InpLotSize), _Digits), InpLotSize);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Converte un importo in valuta conto in una distanza di PREZZO    |
//| per il simbolo corrente, usando tick value e tick size reali.    |
//+------------------------------------------------------------------+
double MoneyToPrice(double money, double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0 || lots <= 0.0)
     {
      Print("ATTENZIONE: MoneyToPrice impossibile per ", _Symbol,
            " tickValue=", tickValue, " tickSize=", tickSize, " lots=", lots);
      return(0.0);
     }
   return((money * tickSize) / (tickValue * lots));
  }

//+------------------------------------------------------------------+
//| Distanza minima SL/TP imposta dal broker (in prezzo)             |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return((double)MathMax(stops, freeze) * _Point);
  }

//+------------------------------------------------------------------+
//| Normalizza il lotto su step/min/max del simbolo                  |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot > 0.0) lots = MathFloor(lots / stepLot + 0.0000001) * stepLot;
   return(MathMin(MathMax(lots, minLot), maxLot));
  }

//+------------------------------------------------------------------+
//| Conta le posizioni di questo EA su questo simbolo                |
//+------------------------------------------------------------------+
int CountOwnPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Profitto NETTO della posizione selezionata:                      |
//| profit + swap + commissioni già addebitate (+ stima uscita)      |
//+------------------------------------------------------------------+
double NetProfitOfSelectedPosition()
  {
   double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   long   posId  = PositionGetInteger(POSITION_IDENTIFIER);

   double commission = 0.0;
   if(HistorySelectByPosition(posId))
     {
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0) continue;
         commission += HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
        }
     }
   if(InpCommissionPerSide) commission *= 2.0;   // stima: in uscita pagheremo quanto in entrata
   return(profit + commission);                   // le commissioni sono già negative
  }

//+------------------------------------------------------------------+
//| P&L realizzato oggi (ora server) da questo EA su questo simbolo  |
//+------------------------------------------------------------------+
double TodayRealizedPnL()
  {
   datetime now      = TimeCurrent();
   datetime dayStart = now - (now % 86400);
   if(!HistorySelect(dayStart, now)) return(0.0);

   double sum = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;

      sum += HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
         sum += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP);
     }
   return(sum);
  }

//+------------------------------------------------------------------+
//| Somma del profitto netto delle posizioni aperte                  |
//+------------------------------------------------------------------+
double FloatingNetPnL()
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber)
         sum += NetProfitOfSelectedPosition();
     }
   return(sum);
  }

//+------------------------------------------------------------------+
//| Filtri che valgono SOLO per i nuovi ingressi                     |
//+------------------------------------------------------------------+
bool EntryFiltersOk()
  {
   if(TimeCurrent() - lastTradeTime < InpMinSecBetweenTrades) return(false);
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return(false);

   if(!(InpStartHour == 0 && InpEndHour == 24))
     {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      bool inside = (InpStartHour < InpEndHour)
                    ? (t.hour >= InpStartHour && t.hour < InpEndHour)
                    : (t.hour >= InpStartHour || t.hour < InpEndHour);   // fascia a cavallo della mezzanotte
      if(!inside) return(false);
     }

   if(InpMaxDailyLoss > 0.0)
     {
      double dailyPnL = TodayRealizedPnL() + FloatingNetPnL();
      if(dailyPnL <= -MathAbs(InpMaxDailyLoss))
        {
         static datetime lastWarn = 0;
         if(TimeCurrent() - lastWarn > 300)
           {
            PrintFormat("LIMITE GIORNALIERO raggiunto: %.2f€ (limite %.2f€). Nessun nuovo ingresso.", dailyPnL, -InpMaxDailyLoss);
            lastWarn = TimeCurrent();
           }
         return(false);
        }
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Log dell'esito dell'ultima richiesta di trade                    |
//+------------------------------------------------------------------+
bool LogTradeResult(string context)
  {
   uint retcode = trade.ResultRetcode();
   bool ok = (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED);
   if(!ok)
      Print("ERRORE TRADE [", context, "] retcode ", retcode, " (", trade.ResultRetcodeDescription(), ")");
   else
      Print("OK TRADE [", context, "] ticket ", trade.ResultOrder());
   return(ok);
  }

//+------------------------------------------------------------------+
//| Apre una posizione con SL/TP monetari reali al broker.           |
//| tpPrice > 0 forza un TP di prezzo (es. bordo del box) se più     |
//| vicino del TP monetario.                                         |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE type, double lots, double slPrice, double tpPrice, string comment)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MinStopDistance();

   double slDist = MathMax(MoneyToPrice(InpMaxLoss,    lots), minDist);
   double tpDist = MathMax(MoneyToPrice(InpTakeProfit, lots), minDist);
   if(slDist <= 0.0 || tpDist <= 0.0) return(false);

   double sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      sl = (slPrice > 0.0) ? MathMin(slPrice, bid - minDist) : ask - slDist;
      tp = ask + tpDist;
      if(tpPrice > 0.0 && tpPrice < tp && tpPrice >= ask + minDist) tp = tpPrice;
     }
   else
     {
      sl = (slPrice > 0.0) ? MathMax(slPrice, ask + minDist) : bid + slDist;
      tp = bid - tpDist;
      if(tpPrice > 0.0 && tpPrice > tp && tpPrice <= bid - minDist) tp = tpPrice;
     }
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);

   bool sent = (type == ORDER_TYPE_BUY)
               ? trade.Buy(lots, _Symbol, ask, sl, tp, comment)
               : trade.Sell(lots, _Symbol, bid, sl, tp, comment);
   bool ok = sent && LogTradeResult(comment);
   if(ok)
     {
      lastTradeTime = TimeCurrent();
      lastBarTime   = iTime(_Symbol, _Period, 0);
     }
   return(ok);
  }

//+------------------------------------------------------------------+
//| Sposta lo SL della posizione selezionata SOLO se lo migliora     |
//+------------------------------------------------------------------+
void TightenStopLoss(ulong ticket, double newSL)
  {
   long   posType   = PositionGetInteger(POSITION_TYPE);
   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = MinStopDistance();

   newSL = NormalizeDouble(newSL, _Digits);
   if(MathAbs(newSL - currentSL) < _Point / 2.0) return;   // già lì

   if(posType == POSITION_TYPE_BUY)
     {
      if(currentSL > 0.0 && newSL <= currentSL) return;    // non arretrare mai
      if(newSL > bid - minDist) return;                    // troppo vicino: riproviamo al prossimo tick
     }
   else
     {
      if(currentSL > 0.0 && newSL >= currentSL) return;
      if(newSL < ask + minDist) return;
     }

   if(trade.PositionModify(ticket, newSL, currentTP))
      PrintFormat("SL ticket %I64u -> %s", ticket, DoubleToString(newSL, _Digits));
   else
      LogTradeResult("Modify SL");
  }

//+------------------------------------------------------------------+
//| Gestione delle posizioni aperte: target, stop, step, piramide    |
//+------------------------------------------------------------------+
void ManagePositions(int positionsCount)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != (long)InpMagicNumber) continue;

      double net       = NetProfitOfSelectedPosition();
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume    = PositionGetDouble(POSITION_VOLUME);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      // Target finale o perdita massima (backup software: al broker c'è già SL/TP)
      if(net >= InpTakeProfit || net <= -InpMaxLoss)
        {
         if(trade.PositionClose(ticket))
           {
            PrintFormat("CHIUSA ticket %I64u a %.2f€ netti", ticket, net);
            lastTradeTime = TimeCurrent();
           }
         else
            LogTradeResult("Close");
         continue;
        }

      // Step di protezione: quanto profitto blocco con lo SL
      double lockMoney = -1.0;
      if(net >= InpStep3Trigger)      lockMoney = InpStep3Lock;
      else if(net >= InpStep2Trigger) lockMoney = InpStep2Lock;
      else if(net >= InpStep1Trigger) lockMoney = 0.0;          // Break-Even

      if(lockMoney >= 0.0)
        {
         double offset = MoneyToPrice(lockMoney, volume);
         double target = (posType == POSITION_TYPE_BUY) ? openPrice + offset : openPrice - offset;
         TightenStopLoss(ticket, target);
        }

      // Piramide: una sola volta per ciclo, nella zona dello Step 1
      if(InpEnablePyramid && !pyramidDone && positionsCount < 2 &&
         net >= InpStep1Trigger && net < InpStep2Trigger)
        {
         pyramidDone = true;   // anche se fallisce: non insistere ogni tick
         ENUM_ORDER_TYPE type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         // SL della piramide sul prezzo di apertura della base (come da design v5)
         OpenPosition(type, NormalizeLot(InpLotSize), openPrice, 0.0,
                      (type == ORDER_TYPE_BUY) ? "Pyramid BUY" : "Pyramid SELL");
        }
     }
  }

//+------------------------------------------------------------------+
//| Ingresso mean-reversion sui bordi del box di consolidamento      |
//+------------------------------------------------------------------+
bool TryRangeEntry(double lots)
  {
   int highestBar = iHighest(_Symbol, _Period, MODE_HIGH, InpRangeCandles, 1);
   int lowestBar  = iLowest(_Symbol, _Period, MODE_LOW,  InpRangeCandles, 1);
   if(highestBar < 0 || lowestBar < 0) return(false);

   double rangeHigh = iHigh(_Symbol, _Period, highestBar);
   double rangeLow  = iLow(_Symbol, _Period, lowestBar);
   if((rangeHigh - rangeLow) > InpRangeMaxPoints * _Point) return(false);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tol = InpRangeTolerance * _Point;
   double body = iClose(_Symbol, _Period, 0) - iOpen(_Symbol, _Period, 0);
   double push = InpMinCandlePoints * _Point;

   // SELL sul bordo alto: solo se il prezzo è ancora DENTRO il box
   // e la candela corrente non sta già rompendo verso l'alto
   if(bid >= rangeHigh - tol && bid <= rangeHigh + tol && body < push)
      return(OpenPosition(ORDER_TYPE_SELL, lots, 0.0, rangeLow, "Range SELL"));

   // BUY sul bordo basso, stesse condizioni speculari
   if(ask <= rangeLow + tol && ask >= rangeLow - tol && body > -push)
      return(OpenPosition(ORDER_TYPE_BUY, lots, 0.0, rangeHigh, "Range BUY"));

   return(false);
  }

//+------------------------------------------------------------------+
//| Ingresso momentum sul corpo della candela corrente               |
//+------------------------------------------------------------------+
bool TryMomentumEntry(double lots)
  {
   double body    = iClose(_Symbol, _Period, 0) - iOpen(_Symbol, _Period, 0);
   double minPush = InpMinCandlePoints * _Point;
   double maxPush = (InpMaxCandlePoints > 0) ? InpMaxCandlePoints * _Point : DBL_MAX;

   if(body >= minPush && body <= maxPush)
      return(OpenPosition(ORDER_TYPE_BUY, lots, 0.0, 0.0, "Candle Momentum BUY"));
   if(body <= -minPush && body >= -maxPush)
      return(OpenPosition(ORDER_TYPE_SELL, lots, 0.0, 0.0, "Candle Momentum SELL"));

   return(false);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. GESTIONE POSIZIONI APERTE: sempre, senza filtri
   int positionsCount = CountOwnPositions();
   if(positionsCount > 0)
     {
      ManagePositions(positionsCount);
      return;
     }
   pyramidDone = false;   // ciclo chiuso: la prossima base potrà piramidare

   // 2. FILTRI PER I NUOVI INGRESSI (cooldown, spread, orario, perdita giornaliera)
   if(!EntryFiltersOk()) return;

   // 3. MASSIMO UN INGRESSO PER CANDELA
   if(iTime(_Symbol, _Period, 0) == lastBarTime) return;

   double lots = NormalizeLot(InpLotSize);

   // 4. STRATEGIE
   if(InpStrategyMode != STRATEGY_MOMENTUM_ONLY && TryRangeEntry(lots)) return;
   if(InpStrategyMode != STRATEGY_RANGE_ONLY) TryMomentumEntry(lots);
  }
//+------------------------------------------------------------------+
