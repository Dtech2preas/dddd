//+------------------------------------------------------------------+
//|                                                 DTECH_BOT_V1.mq5 |
//|                                  Copyright 2025, D-TECH Services |
//|                                      https://preasx24.co.za      |
//+------------------------------------------------------------------+
#property copyright "D-TECH Services"
#property link      "https://preasx24.co.za"
#property version   "1.00"
#property strict

// Include the standard trade library to handle order execution easily
#include <Trade/Trade.mqh>

// Create an instance of the execution object
CTrade trade;

// --- D-TECH INPUTS ---
input double LotSize = 0.01;      // Volume to trade
input int    StopLossPoints = 200; // Stop Loss in Points (20 pips on 5-digit broker)
input int    TakeProfitPoints = 400; // Take Profit in Points (40 pips on 5-digit broker)
input int    FastMA_Period = 10;   // Fast EMA Period
input int    SlowMA_Period = 20;   // Slow EMA Period

// Global variables for our indicators
int maFastHandle;
int maSlowHandle;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // 1. Define the indicators
   maFastHandle = iMA(_Symbol, PERIOD_CURRENT, FastMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   maSlowHandle = iMA(_Symbol, PERIOD_CURRENT, SlowMA_Period, 0, MODE_EMA, PRICE_CLOSE);

   // 2. Check if handles were created successfully
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE)
   {
      Print("CRITICAL ERROR: Failed to create MA handles.");
      return(INIT_FAILED);
   }

   // 3. Set magic number (ID) so the bot knows which trades are its own
   trade.SetExpertMagicNumber(123456);

   Print(">> DTECH BOT V1 INITIALIZED <<");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Define dynamic arrays to hold the MA values
   double maFast[], maSlow[];

   // Sort arrays so index [0] is the current candle, [1] is the previous
   ArraySetAsSeries(maFast, true);
   ArraySetAsSeries(maSlow, true);

   // Copy the last 3 values (enough to check for a crossover)
   // Handle, Buffer 0, Start at 0, Copy 3 items, Target Array
   if(CopyBuffer(maFastHandle, 0, 0, 3, maFast) < 3 || CopyBuffer(maSlowHandle, 0, 0, 3, maSlow) < 3)
   {
      // If we don't have data yet, wait for next tick
      Print("Waiting for data...");
      return;
   }

   // HEARTBEAT: Print the values once per candle to prove we are alive
   static datetime lastPrint = 0;
   if(iTime(_Symbol, PERIOD_CURRENT, 0) != lastPrint)
   {
      Print("Bot Alive | Fast MA: ", maFast[0], " | Slow MA: ", maSlow[0]);
      lastPrint = iTime(_Symbol, PERIOD_CURRENT, 0);
   }

   // CHECK FOR OPEN POSITIONS
   // We only want to open a trade if we don't already have one
   if(PositionsTotal() == 0)
   {
      // --- BUY SIGNAL (CROSSOVER) ---
      // Strategy: Fast MA was BELOW Slow MA yesterday [1], but is ABOVE today [0]
      if(maFast[1] < maSlow[1] && maFast[0] > maSlow[0])
      {
         Print("!!! CROSSOVER DETECTED - ATTEMPTING BUY !!!");
         Print("Buy Signal Detected: Fast EMA crossed above Slow EMA");
         tradeBuy();
      }

      // --- SELL SIGNAL (CROSSUNDER) ---
      // Strategy: Fast MA was ABOVE Slow MA yesterday [1], but is BELOW today [0]
      else if(maFast[1] > maSlow[1] && maFast[0] < maSlow[0])
      {
         Print("!!! CROSSOVER DETECTED - ATTEMPTING SELL !!!");
         Print("Sell Signal Detected: Fast EMA crossed below Slow EMA");
         tradeSell();
      }
   }
}

//+------------------------------------------------------------------+
//| Helper Function: Execute Buy                                     |
//+------------------------------------------------------------------+
void tradeBuy()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Calculate SL and TP based on Points
   // Note: On IC Markets, 1 Point = 0.00001 (for EURUSD).
   double sl = ask - StopLossPoints * _Point;
   double tp = ask + TakeProfitPoints * _Point;

   // Execute
   trade.Buy(LotSize, _Symbol, ask, sl, tp, "DTECH Buy");
}

//+------------------------------------------------------------------+
//| Helper Function: Execute Sell                                    |
//+------------------------------------------------------------------+
void tradeSell()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Calculate SL and TP
   double sl = bid + StopLossPoints * _Point;
   double tp = bid - TakeProfitPoints * _Point;

   // Execute
   trade.Sell(LotSize, _Symbol, bid, sl, tp, "DTECH Sell");
}
