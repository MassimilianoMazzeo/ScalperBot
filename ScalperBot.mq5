//+------------------------------------------------------------------+
//|                                 Scalper_Advanced_Strategy_v5.mq5 |
//|                                  Copyright 2026, Massimiliano    |
//|                                                                  |
//| MODIFICHE RISPETTO A v4:                                         |
//| 1. Stop Loss reale impostato all'apertura di ogni posizione      |
//|    (non solo controllo software in OnTick)                       |
//| 2. Conversione denaro->punti corretta tramite TICK_VALUE/SIZE    |
//|    (funziona su qualsiasi simbolo, non solo forex 5 cifre)       |
//| 3. Controllo esiti di ogni chiamata trade.* con log degli errori |
//| 4. Deviation/slippage impostata sull'oggetto CTrade              |
//| 5. Limite di perdita giornaliera (daily loss limit)              |
//| 6. Switch per scegliere la logica di entrata (Range vs Momentum  |
//|    vs Entrambe) invece di eseguirle sempre entrambe in sequenza  |
//| 7. Normalizzazione prezzi/SL con NormalizeDouble e _Digits       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "5.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- PARAMETRI DI INPUT
input group "--- Parametri Generali ---"
input double   InpLotSize       = 0.1;      // Dimensione Lotto base
input double   InpMaxLoss       = 20.0;     // Stop Loss monetario massimo (€) per posizione
input double   InpTakeProfit    = 15.0;     // Take Profit monetario finale (€) per posizione
input int      InpMaxSpread     = 30;       // Spread massimo tollerato (Punti)
input ulong    InpMagicNumber   = 998877;   // Magic Number
input int      InpSlippage      = 10;       // Deviation/slippage massimo tollerato (Punti)
input double   InpMaxDailyLoss  = 50.0;     // Perdita massima giornaliera (€) - oltre, l'EA si ferma

input group "--- Parametri Consolidation Range ---"
input int      InpRangeCandles  = 15;       // Candele per definire il Range
input double   InpRangeMaxPips  = 150.0;    // Ampiezza massima del Range (in Punti)

input group "--- Selezione Strategia ---"
enum ENUM_STRATEGY_MODE
  {
   STRATEGY_RANGE_ONLY,     // Solo mean-reversion sul range
   STRATEGY_MOMENTUM_ONLY,  // Solo momentum breakout su candela
   STRATEGY_BOTH            // Entrambe (rischio: segnali contrastanti)
  };
input ENUM_STRATEGY_MODE InpStrategyMode = STRATEGY_RANGE_ONLY;

// --- VARIABILI GLOBALI
bool     hasPyramided   = false;
double   dailyStartEquity = 0.0;
datetime lastDayChecked   = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   lastDayChecked   = TimeCurrent();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Converte un importo in EUR/valuta conto in una distanza in punti |
//| per il simbolo corrente, usando tick value e tick size reali.    |
//+------------------------------------------------------------------+
double MoneyToPoints(double moneyAmount, double lots)
  {
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0 || lots <= 0.0)
     {
      Print("ATTENZIONE: impossibile calcolare MoneyToPoints per ", _Symbol,
            " - tickValue=", tickValue, " tickSize=", tickSize);
      return(0.0);
     }

   // Distanza in prezzo necessaria per ottenere 'moneyAmount' su 'lots' lotti
   double priceDistance = (moneyAmount * tickSize) / (tickValue * lots);
   return(priceDistance);
  }

//+------------------------------------------------------------------+
//| Controlla se abbiamo superato il limite di perdita giornaliera   |
//+------------------------------------------------------------------+
bool DailyLossLimitHit()
  {
   MqlDateTime nowStruct, lastStruct;
   TimeToStruct(TimeCurrent(), nowStruct);
   TimeToStruct(lastDayChecked, lastStruct);

   // Reset del contatore giornaliero a cambio giorno
   if(nowStruct.day != lastStruct.day || nowStruct.mon != lastStruct.mon || nowStruct.year != lastStruct.year)
     {
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      lastDayChecked   = TimeCurrent();
     }

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPnL       = currentEquity - dailyStartEquity;

   if(dailyPnL <= -MathAbs(InpMaxDailyLoss))
     {
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Log del risultato di un'operazione di trade                      |
//+------------------------------------------------------------------+
void LogTradeResult(string context)
  {
   uint retcode = trade.ResultRetcode();
   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED)
     {
      Print("ERRORE TRADE [", context, "] - Retcode: ", retcode,
            " (", trade.ResultRetcodeDescription(), ")");
     }
   else
     {
      Print("OK TRADE [", context, "] - Ticket: ", trade.ResultOrder());
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 0. Blocco totale se superata la perdita massima giornaliera
   if(DailyLossLimitHit())
     {
      static datetime lastWarning = 0;
      if(TimeCurrent() - lastWarning > 3600) // avvisa una volta all'ora, non ad ogni tick
        {
         Print("STOP OPERATIVO: limite di perdita giornaliera (€", InpMaxDailyLoss, ") raggiunto.");
         lastWarning = TimeCurrent();
        }
      return;
     }

   // Controlla lo spread prima di aprire
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   int totalPositions = 0;

   // 1. GESTIONE A SCAGLIONI DI PROFITTO E SL (STEP PROGRESSIVI CON MARGINE)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         totalPositions++;
         double profit    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         long   posType   = PositionGetInteger(POSITION_TYPE);

         // A. Chiusura al Target Finale o allo Stop Loss Massimo (doppia rete di sicurezza:
         //    questo controllo software si somma allo SL reale piazzato all'apertura)
         if(profit >= InpTakeProfit || profit <= -InpMaxLoss)
           {
            if(!trade.PositionClose(ticket))
               LogTradeResult("Chiusura posizione " + IntegerToString(ticket));
            hasPyramided = false;
            return;
           }

         // B. Step 1: A +2.50€ -> SL a Break-Even
         if(profit >= 2.50 && profit < 5.00)
           {
            double beSL = NormalizeDouble(openPrice, _Digits);
            if(MathAbs(currentSL - beSL) > _Point)
              {
               if(!trade.PositionModify(ticket, beSL, currentTP))
                  LogTradeResult("Modify BE posizione " + IntegerToString(ticket));
              }

            // Piramidazione: apre la 2° posizione con il suo SL reale, non a mercato "libero"
            if(!hasPyramided && totalPositions < 2)
              {
               hasPyramided = true;
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double slDistance = MoneyToPoints(InpMaxLoss, InpLotSize);

               if(posType == POSITION_TYPE_BUY)
                 {
                  double sl = (slDistance > 0) ? NormalizeDouble(ask - slDistance, _Digits) : 0.0;
                  if(trade.Buy(InpLotSize, _Symbol, ask, sl, openPrice, "Pyramid BUY"))
                     LogTradeResult("Pyramid BUY");
                  else
                     LogTradeResult("Pyramid BUY FALLITA");
                 }
               else if(posType == POSITION_TYPE_SELL)
                 {
                  double sl = (slDistance > 0) ? NormalizeDouble(bid + slDistance, _Digits) : 0.0;
                  if(trade.Sell(InpLotSize, _Symbol, bid, sl, openPrice, "Pyramid SELL"))
                     LogTradeResult("Pyramid SELL");
                  else
                     LogTradeResult("Pyramid SELL FALLITA");
                 }
              }
           }

         // C. Step 2: A +5.00€ -> SL bloccato a +2.50€ di profitto garantito
         else if(profit >= 5.00 && profit < 10.00)
           {
            double dist = MoneyToPoints(2.50, InpLotSize);
            if(dist > 0)
              {
               double targetSL = (posType == POSITION_TYPE_BUY) ?
                                  NormalizeDouble(openPrice + dist, _Digits) :
                                  NormalizeDouble(openPrice - dist, _Digits);
               if(MathAbs(currentSL - targetSL) > _Point)
                 {
                  if(!trade.PositionModify(ticket, targetSL, currentTP))
                     LogTradeResult("Modify Step2 posizione " + IntegerToString(ticket));
                 }
              }
           }

         // D. Step 3: A +10.00€ -> SL bloccato a +5.00€ di profitto garantito
         else if(profit >= 10.00)
           {
            double dist = MoneyToPoints(5.00, InpLotSize);
            if(dist > 0)
              {
               double targetSL = (posType == POSITION_TYPE_BUY) ?
                                  NormalizeDouble(openPrice + dist, _Digits) :
                                  NormalizeDouble(openPrice - dist, _Digits);
               if(MathAbs(currentSL - targetSL) > _Point)
                 {
                  if(!trade.PositionModify(ticket, targetSL, currentTP))
                     LogTradeResult("Modify Step3 posizione " + IntegerToString(ticket));
                 }
              }
           }
        }
     }

   // Reset dello stato piramidazione se non ci sono posizioni aperte
   if(totalPositions == 0) hasPyramided = false;
   else return; // Se un'operazione è aperta, la gestiamo senza aprire nuovi ordini

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDistanceEntry = MoneyToPoints(InpMaxLoss, InpLotSize);
   if(slDistanceEntry <= 0) return; // non entriamo se non riusciamo a calcolare uno SL valido

   // 2. LOGICA RANGE DI CONSOLIDAMENTO (mean-reversion)
   if(InpStrategyMode == STRATEGY_RANGE_ONLY || InpStrategyMode == STRATEGY_BOTH)
     {
      int highestBar = iHighest(_Symbol, _Period, MODE_HIGH, InpRangeCandles, 1);
      int lowestBar  = iLowest(_Symbol, _Period, MODE_LOW, InpRangeCandles, 1);
      double rangeHigh = iHigh(_Symbol, _Period, highestBar);
      double rangeLow  = iLow(_Symbol, _Period, lowestBar);

      if((rangeHigh - rangeLow) <= (InpRangeMaxPips * _Point))
        {
         // Massimi del Range -> APRI SELL con Target sul Minimo e SL reale sopra il range
         if(currentBid >= rangeHigh - (10 * _Point))
           {
            double sl = NormalizeDouble(currentBid + slDistanceEntry, _Digits);
            if(trade.Sell(InpLotSize, _Symbol, currentBid, sl, rangeLow, "Range SELL"))
               LogTradeResult("Range SELL");
            else
               LogTradeResult("Range SELL FALLITA");
            return;
           }
         // Minimi del Range -> APRI BUY con Target sul Massimo e SL reale sotto il range
         else if(currentAsk <= rangeLow + (10 * _Point))
           {
            double sl = NormalizeDouble(currentAsk - slDistanceEntry, _Digits);
            if(trade.Buy(InpLotSize, _Symbol, currentAsk, sl, rangeHigh, "Range BUY"))
               LogTradeResult("Range BUY");
            else
               LogTradeResult("Range BUY FALLITA");
            return;
           }
        }
     }

   // 3. SCALPING PRICE ACTION (momentum breakout)
   if(InpStrategyMode == STRATEGY_MOMENTUM_ONLY || InpStrategyMode == STRATEGY_BOTH)
     {
      double open0  = iOpen(_Symbol, _Period, 0);
      double close0 = iClose(_Symbol, _Period, 0);

      if(close0 > open0 + (15 * _Point))
        {
         double sl = NormalizeDouble(currentAsk - slDistanceEntry, _Digits);
         if(trade.Buy(InpLotSize, _Symbol, currentAsk, sl, 0, "Candle Momentum BUY"))
            LogTradeResult("Candle Momentum BUY");
         else
            LogTradeResult("Candle Momentum BUY FALLITA");
        }
      else if(close0 < open0 - (15 * _Point))
        {
         double sl = NormalizeDouble(currentBid + slDistanceEntry, _Digits);
         if(trade.Sell(InpLotSize, _Symbol, currentBid, sl, 0, "Candle Momentum SELL"))
            LogTradeResult("Candle Momentum SELL");
         else
            LogTradeResult("Candle Momentum SELL FALLITA");
        }
     }
  }
