//+------------------------------------------------------------------+
//|                                Scalper_Advanced_Fix_Commission.mq5|
//|                                  Copyright 2026, Il Tuo Nome     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "5.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- PARAMETRI DI INPUT
input group "--- Parametri Generali ---"
input double   InpLotSize       = 0.1;      // Dimensione Lotto base
input double   InpMaxLoss       = 20.0;     // Stop Loss monetario massimo (€)
input int      InpMaxSpread     = 20;       // Spread massimo tollerato (Punti)
input ulong    InpMagicNumber   = 998877;   // Magic Number

input group "--- Filtri Anti-Overtrading ---"
input int      InpMinSecBetweenTrades = 15; // Attesa minima in SECONDI tra 2 operazioni
input int      InpMinCandlePoints     = 50; // Punti minimi spinta candela (es. 5 pips su EURUSD)

input group "--- Parametri Consolidation Range ---"
input int      InpRangeCandles  = 15;       
input double   InpRangeMaxPips  = 150.0;    

// --- VARIABILI GLOBALI
bool     hasPyramided = false;
datetime lastTradeTime = 0;
datetime lastBarTime   = 0;

int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) {}

void OnTick()
  {
   // 1. FILTRO COOLDOWN TEMPORALE (Blocca le 9000 operazioni al giorno)
   if(TimeCurrent() - lastTradeTime < InpMinSecBetweenTrades) return;

   // 2. FILTRO SPREAD
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   int totalPositions = 0;

   // 3. GESTIONE POSIZIONI APERTE (Profit / Loss / Step)
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
         totalPositions++;
         double profit    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         long posType     = PositionGetInteger(POSITION_TYPE);

         // Target Finale (+15€) o Stop Loss Massimo (-20€)
         if(profit >= 15.0 || profit <= -InpMaxLoss)
           {
            trade.PositionClose(ticket);
            hasPyramided = false;
            lastTradeTime = TimeCurrent();
            return;
           }

         // Step 1: A +2.50€ -> SL a Break-Even (0€)
         if(profit >= 2.50 && profit < 5.00)
           {
            if(currentSL != openPrice)
               trade.PositionModify(ticket, openPrice, PositionGetDouble(POSITION_TP));

            if(!hasPyramided && totalPositions < 2)
              {
               hasPyramided = true;
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               if(posType == POSITION_TYPE_BUY)
                  trade.Buy(InpLotSize, _Symbol, ask, openPrice, 0, "Pyramid BUY");
               else if(posType == POSITION_TYPE_SELL)
                  trade.Sell(InpLotSize, _Symbol, bid, openPrice, 0, "Pyramid SELL");
               
               lastTradeTime = TimeCurrent();
              }
           }

         // Step 2: A +5.00€ -> SL a +2.50€
         else if(profit >= 5.00 && profit < 10.00)
           {
            double pointOffset = (2.50 / (InpLotSize * 10)) * _Point; 
            double targetSL = (posType == POSITION_TYPE_BUY) ? openPrice + pointOffset : openPrice - pointOffset;
            if(currentSL != targetSL) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
           }

         // Step 3: A +10.00€ -> SL a +5.00€
         else if(profit >= 10.00)
           {
            double pointOffset = (5.00 / (InpLotSize * 10)) * _Point;
            double targetSL = (posType == POSITION_TYPE_BUY) ? openPrice + pointOffset : openPrice - pointOffset;
            if(currentSL != targetSL) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
           }
        }
     }

   if(totalPositions == 0) hasPyramided = false;
   else return; 

   // 4. FILTRO NUOVA CANDELA PER GLI INGRESSI (Esegue la valutazione solo a inizio candela)
   datetime currentBar = iTime(_Symbol, _Period, 0);
   if(currentBar == lastBarTime) return; 

   // 5. LOGICA RANGE DI CONSOLIDAMENTO
   int highestBar = iHighest(_Symbol, _Period, MODE_HIGH, InpRangeCandles, 1);
   int lowestBar  = iLowest(_Symbol, _Period, MODE_LOW, InpRangeCandles, 1);
   double rangeHigh = iHigh(_Symbol, _Period, highestBar);
   double rangeLow  = iLow(_Symbol, _Period, lowestBar);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if((rangeHigh - rangeLow) <= (InpRangeMaxPips * _Point))
     {
      if(currentBid >= rangeHigh - (10 * _Point))
        {
         if(trade.Sell(InpLotSize, _Symbol, currentBid, 0, rangeLow, "Range SELL"))
           {
            lastTradeTime = TimeCurrent();
            lastBarTime   = currentBar;
            return;
           }
        }
      else if(currentAsk <= rangeLow + (10 * _Point))
        {
         if(trade.Buy(InpLotSize, _Symbol, currentAsk, 0, rangeHigh, "Range BUY"))
           {
            lastTradeTime = TimeCurrent();
            lastBarTime   = currentBar;
            return;
           }
        }
     }

   // 6. SCALPING MOMENTUM CANDELA (Filtro a 50 Punti)
   double open0  = iOpen(_Symbol, _Period, 0);
   double close0 = iClose(_Symbol, _Period, 0);

   if(close0 > open0 + (InpMinCandlePoints * _Point))
     {
      if(trade.Buy(InpLotSize, _Symbol, currentAsk, 0, 0, "Candle Momentum BUY"))
        {
         lastTradeTime = TimeCurrent();
         lastBarTime   = currentBar;
        }
     }
   else if(close0 < open0 - (InpMinCandlePoints * _Point))
     {
      if(trade.Sell(InpLotSize, _Symbol, currentBid, 0, 0, "Candle Momentum SELL"))
        {
         lastTradeTime = TimeCurrent();
         lastBarTime   = currentBar;
        }
     }
  }
