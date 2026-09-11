//+------------------------------------------------------------------+
//|                                 Scalper_Advanced_Strategy_2026.mq5|
//|                                  Copyright 2026, Il Tuo Nome     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "3.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- PARAMETRI DI INPUT
input group "--- Parametri Generali ---"
input double   InpLotSize       = 0.1;      // Dimensione Lotto base
input double   InpMaxLoss       = 15.0;     // Stop Loss monetario massimo (€)
input int      InpMaxSpread     = 25;       // Spread massimo tollerato (Punti)
input ulong    InpMagicNumber   = 998877;   // Magic Number

input group "--- Parametri Consolidation Range ---"
input int      InpRangeCandles  = 15;       // Candele per definire il Range
input double   InpRangeMaxPips  = 100.0;    // Ampiezza massima del Range (in Punti)

// --- VARIABILI GLOBALI
bool hasPyramided = false;
datetime lastCandleTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Controlla lo spread prima di fare qualsiasi cosa
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   int totalPositions = 0;
   double totalProfit = 0.0;

   // 1. GESTIONE A SCAGLIONI DI PROFITTO E SL (STEP PROGRESSIVI)
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
         totalProfit     += profit;

         // A. Chiusura a 15€ o Stop Loss Massimo
         if(profit >= 15.0 || profit <= -InpMaxLoss)
           {
            trade.PositionClose(ticket);
            hasPyramided = false;
            return;
           }

         // B. Step 1: A 2.50€ -> SL a Break-Even (Prezzo di Ingresso)
         if(profit >= 2.50 && profit < 5.00)
           {
            if(currentSL != openPrice)
               trade.PositionModify(ticket, openPrice, PositionGetDouble(POSITION_TP));

            // PIRAMIDAZIONE: Entra con la seconda posizione allo stesso SL dell'operazione precedente
            if(!hasPyramided && totalPositions < 2)
              {
               hasPyramided = true;
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               if(posType == POSITION_TYPE_BUY)
                  trade.Buy(InpLotSize, _Symbol, ask, openPrice, 0, "Pyramid BUY");
               else if(posType == POSITION_TYPE_SELL)
                  trade.Sell(InpLotSize, _Symbol, bid, openPrice, 0, "Pyramid SELL");
              }
           }

         // C. Step 2: A 5.00€ -> SL garantito a +2.50€ di profitto
         else if(profit >= 5.00 && profit < 10.00)
           {
            double pointOffset = (2.50 / (InpLotSize * 10)) * _Point; 
            double targetSL = (posType == POSITION_TYPE_BUY) ? openPrice + pointOffset : openPrice - pointOffset;
            if(currentSL != targetSL) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
           }

         // D. Step 3: A 10.00€ -> SL garantito a +5.00€ di profitto
         else if(profit >= 10.00)
           {
            double pointOffset = (5.00 / (InpLotSize * 10)) * _Point;
            double targetSL = (posType == POSITION_TYPE_BUY) ? openPrice + pointOffset : openPrice - pointOffset;
            if(currentSL != targetSL) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
           }

         // E. RIFIUTO CANDELA SULLA POSIZIONE APERTA (Uscita immediata su ritracciamento)
         double openCandle = iOpen(_Symbol, _Period, 0);
         double closeCandle = iClose(_Symbol, _Period, 0);
         double highCandle  = iHigh(_Symbol, _Period, 0);
         double lowCandle   = iLow(_Symbol, _Period, 0);

         // Rifiuto in BUY: la candela sta creando una wick superiore evidente rispetto al corpo
         if(posType == POSITION_TYPE_BUY && closeCandle < (highCandle - ((highCandle - openCandle) * 0.4)))
           {
            trade.PositionClose(ticket);
            hasPyramided = false;
            return;
           }
         // Rifiuto in SELL: la candela sta creando una wick inferiore
         else if(posType == POSITION_TYPE_SELL && closeCandle > (lowCandle + ((openCandle - lowCandle) * 0.4)))
           {
            trade.PositionClose(ticket);
            hasPyramided = false;
            return;
           }
        }
     }

   // Reset dello stato piramidazione se non ci sono posizioni aperte
   if(totalPositions == 0) hasPyramided = false;
   else return; // Se c'è già un'operazione, gestiamo quella senza aprire nuovi pattern di range

   // 2. LOGICA RANGE DI CONSOLIDAMENTO (Entra ai minimi in BUY e ai massimi in SELL)
   int highestBar = iHighest(_Symbol, _Period, MODE_HIGH, InpRangeCandles, 1);
   int lowestBar  = iLowest(_Symbol, _Period, MODE_LOW, InpRangeCandles, 1);
   double rangeHigh = iHigh(_Symbol, _Period, highestBar);
   double rangeLow  = iLow(_Symbol, _Period, lowestBar);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Se il range è stretto (fase di consolidamento attiva)
   if((rangeHigh - rangeLow) <= (InpRangeMaxPips * _Point))
     {
      // Vicino ai Massimi del Range -> APRI SELL con Target sul Minimo del Range
      if(currentBid >= rangeHigh - (5 * _Point))
        {
         trade.Sell(InpLotSize, _Symbol, currentBid, 0, rangeLow, "Range SELL");
         return;
        }
      // Vicino ai Minimi del Range -> APRI BUY con Target sul Massimo del Range
      else if(currentAsk <= rangeLow + (5 * _Point))
        {
         trade.Buy(InpLotSize, _Symbol, currentAsk, 0, rangeHigh, "Range BUY");
         return;
        }
     }

   // 3. SCALPING PRICE ACTION SULLA CANDELA IN CORSO (Wick / Momentum)
   double open0  = iOpen(_Symbol, _Period, 0);
   double close0 = iClose(_Symbol, _Period, 0);

   // Candela fortemente rialzista -> Entra BUY
   if(close0 > open0 + (10 * _Point))
     {
      trade.Buy(InpLotSize, _Symbol, currentAsk, 0, 0, "Candle Momentum BUY");
     }
   // Candela fortemente ribassista -> Entra SELL
   else if(close0 < open0 - (10 * _Point))
     {
      trade.Sell(InpLotSize, _Symbol, currentBid, 0, 0, "Candle Momentum SELL");
     }
  }
