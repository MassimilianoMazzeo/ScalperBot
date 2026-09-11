//+------------------------------------------------------------------+
//|                                 Scalper_Advanced_Strategy_v4.mq5 |
//|                                  Copyright 2026, Il Tuo Nome     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property version   "4.00"

#include <Trade\Trade.mqh>
CTrade trade;

// --- PARAMETRI DI INPUT
input group "--- Parametri Generali ---"
input double   InpLotSize       = 0.1;      // Dimensione Lotto base
input double   InpMaxLoss       = 20.0;     // Stop Loss monetario massimo (€) - Margine Drawdown
input int      InpMaxSpread     = 30;       // Spread massimo tollerato (Punti)
input ulong    InpMagicNumber   = 998877;   // Magic Number

input group "--- Parametri Consolidation Range ---"
input int      InpRangeCandles  = 15;       // Candele per definire il Range
input double   InpRangeMaxPips  = 150.0;    // Ampiezza massima del Range (in Punti)

// --- VARIABILI GLOBALI
bool hasPyramided = false;

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
   // Controlla lo spread prima di aprire
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   int totalPositions = 0;

   // 1. GESTIONE A SCAGLIONI DI PROFITTO E SL (STEP PROGRESSIVI CON MARGINE)
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

         // A. Chiusura al Target Finale (+15€) o allo Stop Loss Massimo
         if(profit >= 15.0 || profit <= -InpMaxLoss)
           {
            trade.PositionClose(ticket);
            hasPyramided = false;
            return;
           }

         // B. Step 1: A +2.50€ -> SL a Break-Even (Prezzo di Ingresso 0€ di rischio)
         if(profit >= 2.50 && profit < 5.00)
           {
            if(currentSL != openPrice)
               trade.PositionModify(ticket, openPrice, PositionGetDouble(POSITION_TP));

            // Piramidazione: apre la 2° posizione lasciandola lavorare
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

         // C. Step 2: A +5.00€ -> SL bloccato a +2.50€ di profitto garantito
         else if(profit >= 5.00 && profit < 10.00)
           {
            double pointOffset = (2.50 / (InpLotSize * 10)) * _Point; 
            double targetSL = (posType == POSITION_TYPE_BUY) ? openPrice + pointOffset : openPrice - pointOffset;
            if(currentSL != targetSL) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
           }

         // D. Step 3: A +10.00€ -> SL bloccato a +5.00€ di profitto garantito
         else if(profit >= 10.00)
           {
            double pointOffset = (5.00 / (InpLotSize * 10)) * _Point;
            double targetSL = (posType == POSITION_TYPE_BUY) ? openPrice + pointOffset : openPrice - pointOffset;
            if(currentSL != targetSL) trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
           }
        }
     }

   // Reset dello stato piramidazione se non ci sono posizioni aperte
   if(totalPositions == 0) hasPyramided = false;
   else return; // Se un'operazione è aperta, la gestiamo senza aprire nuovi ordini

   // 2. LOGICA RANGE DI CONSOLIDAMENTO (Entra sui Minimi in BUY e sui Massimi in SELL)
   int highestBar = iHighest(_Symbol, _Period, MODE_HIGH, InpRangeCandles, 1);
   int lowestBar  = iLowest(_Symbol, _Period, MODE_LOW, InpRangeCandles, 1);
   double rangeHigh = iHigh(_Symbol, _Period, highestBar);
   double rangeLow  = iLow(_Symbol, _Period, lowestBar);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Se il mercato è in un range di consolidamento
   if((rangeHigh - rangeLow) <= (InpRangeMaxPips * _Point))
     {
      // Massimi del Range -> APRI SELL con Target sul Minimo
      if(currentBid >= rangeHigh - (10 * _Point))
        {
         trade.Sell(InpLotSize, _Symbol, currentBid, 0, rangeLow, "Range SELL");
         return;
        }
      // Minimi del Range -> APRI BUY con Target sul Massimo
      else if(currentAsk <= rangeLow + (10 * _Point))
        {
         trade.Buy(InpLotSize, _Symbol, currentAsk, 0, rangeHigh, "Range BUY");
         return;
        }
     }

   // 3. SCALPING PRICE ACTION (Candela Direzionale)
   double open0  = iOpen(_Symbol, _Period, 0);
   double close0 = iClose(_Symbol, _Period, 0);

   // Candela fortemente rialzista -> Entra BUY
   if(close0 > open0 + (15 * _Point))
     {
      trade.Buy(InpLotSize, _Symbol, currentAsk, 0, 0, "Candle Momentum BUY");
     }
   // Candela fortemente ribassista -> Entra SELL
   else if(close0 < open0 - (15 * _Point))
     {
      trade.Sell(InpLotSize, _Symbol, currentBid, 0, 0, "Candle Momentum SELL");
     }
  }
