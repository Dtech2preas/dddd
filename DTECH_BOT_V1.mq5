//+------------------------------------------------------------------+
//|                                                 DTECH_BOT_V1.mq5 |
//|                                  Copyright 2025, D-TECH Services |
//|                                      https://preasx24.co.za      |
//+------------------------------------------------------------------+
#property copyright "D-TECH Services"
#property link      "https://preasx24.co.za"
#property version   "2.00"
#property strict

//+------------------------------------------------------------------+
//| INCLUDES                                                         |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| ENUMS & CONSTANTS                                                |
//+------------------------------------------------------------------+
enum ENUM_RISK_MODE
  {
   RISK_FIXED,    // Fixed Lot Size
   RISK_PERCENT   // Percentage of Equity
  };

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
// --- Risk Management (AGGRESSOR MODE) ---
input group             "=== Money Management ==="
input ENUM_RISK_MODE    InpRiskMode          = RISK_PERCENT; // Risk Mode
input double            InpRiskPercent       = 5.0;          // Risk Percent (Aggressor: 5-10%)
input bool              InpUseRiskFallback   = true;         // Use Minimum Lot if risk calc is too low
input double            InpFixedLot          = 0.01;         // Fixed Lot Size (if Fixed Mode)
input double            InpMaxLot            = 100.0;        // Maximum allowed lot size

// --- Strategy Settings (MACHINE GUN MODE) ---
input group             "=== Strategy Settings ==="
input int               InpTrendPeriod       = 50;           // Trend EMA Period (Faster Trend)
input int               InpRsiPeriod         = 9;            // RSI Period (Sensitive)
input int               InpRsiOverbought     = 70;           // RSI Overbought Level
input int               InpRsiOversold       = 30;           // RSI Oversold Level
input int               InpStopLoss          = 200;          // Stop Loss (Points)
input int               InpTakeProfit        = 400;          // Take Profit (Points)

// --- Trade Management ---
input group             "=== Trade Management ==="
input bool              InpUseTrailing       = true;         // Use Trailing Stop
input int               InpTrailStart        = 100;          // Start Trailing after X Points profit
input int               InpTrailDist         = 50;           // Trailing Distance (Points)

// --- Filters ---
input group             "=== Filters ==="
input int               InpMaxSpread         = 20;           // Max Spread (Points)
input int               InpStartHour         = 0;            // Start Trading Hour (0-23)
input int               InpEndHour           = 23;           // End Trading Hour (0-23)
input int               InpMaxPositions      = 5;            // Max Open Positions
input int               InpMagicNum          = 123456;       // Magic Number
input bool              InpForceHistoryDownload = true;      // Force History Download (Live Chart)

// --- Debugging ---
input group             "=== Debugging ==="
input bool              InpForceTestTrade    = false;        // Force Immediate Test Trade

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade         trade;
int            handleTrendEMA;
int            handleRSI;
bool           g_hasForcedTrade = false;

// Forward Declaration
void UpdateStatus();

//+------------------------------------------------------------------+
//| INITIALIZATION                                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. Initialize Indicators
   handleTrendEMA = iMA(_Symbol, PERIOD_CURRENT, InpTrendPeriod, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, PERIOD_CURRENT, InpRsiPeriod, PRICE_CLOSE);

   // 2. Validate Handles
   if(handleTrendEMA == INVALID_HANDLE || handleRSI == INVALID_HANDLE)
     {
      Print("CRITICAL: Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   // 3. Setup Trade Object
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);

   // 4. Force History Download (if not in Tester)
   if(InpForceHistoryDownload && !MQLInfoInteger(MQL_TESTER))
     {
      DownloadHistory();
     }

   Print(">> DTECH BOT V2 (AGGRESSOR) INITIALIZED <<");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   // Release handles
   IndicatorRelease(handleTrendEMA);
   IndicatorRelease(handleRSI);
   Print(">> DTECH BOT STOPPED <<");
  }

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 0. Update Status (Comment on Chart)
   UpdateStatus();

   // 1. Check basic conditions (Terminal connected, Spread, etc.)
   if(!CheckEnvironment()) return;

   // --- FORCE TEST TRADE LOGIC ---
   if(InpForceTestTrade && !g_hasForcedTrade)
     {
      Print(">>> FORCE TRADE: Initiating one-time test trade...");

      // Get Trend Direction from EMA
      double emaArr[], closeArr[];
      ArraySetAsSeries(emaArr, true);
      ArraySetAsSeries(closeArr, true);

      if(CopyBuffer(handleTrendEMA, 0, 0, 1, emaArr) == 1 &&
         CopyClose(_Symbol, PERIOD_CURRENT, 0, 1, closeArr) == 1)
        {
         double ema   = emaArr[0];
         double close = closeArr[0];
         double lot   = CalculateLotSize(InpStopLoss);

         if(lot > 0)
           {
            if(close > ema)
              {
               double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               double sl  = ask - InpStopLoss * _Point;
               double tp  = ask + InpTakeProfit * _Point;
               Print(">>> FORCE TRADE: Executing BUY (Price > EMA).");
               trade.Buy(lot, _Symbol, ask, sl, tp, "DTECH Force Test");
              }
            else
              {
               double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
               double sl  = bid + InpStopLoss * _Point;
               double tp  = bid - InpTakeProfit * _Point;
               Print(">>> FORCE TRADE: Executing SELL (Price < EMA).");
               trade.Sell(lot, _Symbol, bid, sl, tp, "DTECH Force Test");
              }
           }
         else
           {
            Print(">>> FORCE TRADE FAILED: Lot size is 0 (Check Risk Settings).");
           }
        }
      else
        {
         Print(">>> FORCE TRADE ERROR: Could not get data.");
        }

      g_hasForcedTrade = true; // Mark as done regardless of success to prevent loop
     }

   // 2. Manage Open Positions (Trailing Stop)
   ManagePositions();

   // 3. Check for New Entry Signals
   // Check total positions for this EA
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      if(PositionGetTicket(i) > 0)
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol)
            count++;
     }

   if(count < InpMaxPositions)
     {
      CheckForEntry();
     }
  }

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                 |
//+------------------------------------------------------------------+

//--- Check Trading Environment (Spread, Time, Connection)
bool CheckEnvironment()
  {
   // Check if terminal is connected
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return(false);

   // Check Spread
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > InpMaxSpread)
     {
      // Optional: Print only occasionally to avoid spam
      return(false);
     }

   // Check Time (Server Time)
   datetime timeCurrent = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(timeCurrent, dt);

   if(InpStartHour < InpEndHour)
     {
      // Standard day session (e.g. 8 to 20)
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour) return(false);
     }
   else if(InpStartHour > InpEndHour)
     {
      // Overnight session (e.g. 22 to 8)
      if(dt.hour < InpStartHour && dt.hour >= InpEndHour) return(false);
     }

   return(true);
  }

//--- Calculate Lot Size based on Risk
double CalculateLotSize(double slPoints, bool verbose=true)
  {
   double volume = 0.0;

   if(InpRiskMode == RISK_FIXED)
     {
      volume = InpFixedLot;
     }
   else // RISK_PERCENT
     {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskMoney = balance * (InpRiskPercent / 100.0);

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      // Fallback if tick value is unknown or zero to prevent div by zero
      if(tickValue <= 0) tickValue = 1.0;

      double moneyLossPerLot = slPoints * tickValue;
      if(moneyLossPerLot <= 0) moneyLossPerLot = 1.0;

      volume = riskMoney / moneyLossPerLot;
     }

   // Normalize Volume
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max  = InpMaxLot; // User defined max or Symbol max
   double symMax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(max > symMax) max = symMax;

   // Round to step
   volume = MathFloor(volume / step) * step;

   // Clamp to limits
   if(volume < min)
     {
      if(InpUseRiskFallback)
        {
         if(verbose) Print(StringFormat("RISK WARNING: Calculated volume %.5f is below min. FALLBACK used: %.2f.", volume, min));
         volume = min;
        }
      else
        {
         if(verbose) Print(StringFormat("RISK ALERT: Calculated volume %.5f is below minimum %.2f. Balance too low for %.1f%% risk.", volume, min, InpRiskPercent));
         return(0.0);
        }
     }
   if(volume > max) volume = max;

   return(volume);
  }

//--- Manage Open Positions (Trailing Stop)
void ManagePositions()
  {
   if(!InpUseTrailing) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      // Select the position to access its properties
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      // Filter by Symbol and Magic Number
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNum)
         continue;

      // Get Position details
      long   type     = PositionGetInteger(POSITION_TYPE);
      double open     = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl       = PositionGetDouble(POSITION_SL);
      double priceCurrent = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double point    = _Point;
      int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      // --- TRAILING STOP LOGIC ---

      if(type == POSITION_TYPE_BUY)
        {
         // If profit > Start Level
         if(priceCurrent - open > InpTrailStart * point)
           {
            double newSL = priceCurrent - InpTrailDist * point;

            // Check if new SL is higher than current SL (or if no SL exists)
            // Also ensure new SL is not too close to current price (StopLevel check handled by Trade class mostly, but good to be safe)
            if(newSL > sl + point) // Add a small buffer to avoid constant tiny updates
              {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
              }
           }
        }
      else if(type == POSITION_TYPE_SELL)
        {
         // If profit > Start Level (Open - Current > Start)
         if(open - priceCurrent > InpTrailStart * point)
           {
            double newSL = priceCurrent + InpTrailDist * point;

            // Check if new SL is lower than current SL (or if no SL exists aka 0)
            if(sl == 0 || newSL < sl - point)
              {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
              }
           }
        }
     }
  }
//--- Check for Entry Signals
void CheckForEntry()
  {
   // 0. Pre-check: Ensure sufficient history bars exist for indicators
   if(Bars(_Symbol, PERIOD_CURRENT) < InpTrendPeriod)
     {
      static int barWaitCount = 0;
      if(barWaitCount++ % 100 == 0)
         Print("Waiting for sufficient history data... (Have ", Bars(_Symbol, PERIOD_CURRENT), " bars, Need ", InpTrendPeriod, ")");
      return;
     }

   // Define arrays for data
   double trendMA[];
   double rsi[];
   double close[];

   ArraySetAsSeries(trendMA, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(close, true);

   // Copy data (need at least 2 candles for crossover check)
   if(CopyBuffer(handleTrendEMA, 0, 0, 3, trendMA) < 3 ||
      CopyBuffer(handleRSI, 0, 0, 3, rsi) < 3 ||
      CopyClose(_Symbol, PERIOD_CURRENT, 0, 3, close) < 3)
     {
      static int retryCount = 0;
      if(retryCount++ % 10 == 0) // Reduce spam
         Print("Waiting for data... (Buffers not ready)");
      return;
     }

   // --- STRATEGY LOGIC ---

   // 1. Trend Direction
   bool isUptrend   = close[1] > trendMA[1];
   bool isDowntrend = close[1] < trendMA[1];

   // 2. Buy Signal (Uptrend + RSI crossover out of Oversold)
   // RSI was below 30, now is above 30
   if(isUptrend && rsi[1] < InpRsiOversold && rsi[0] > InpRsiOversold)
     {
      Print(">>> BUY SIGNAL: Price > EMA and RSI crossing up from Oversold");

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = ask - InpStopLoss * _Point;
      double tp  = ask + InpTakeProfit * _Point;
      double lot = CalculateLotSize(InpStopLoss);

      // Execute only if lot size is valid (Risk Management)
      if(lot > 0)
        {
         trade.Buy(lot, _Symbol, ask, sl, tp, "DTECH Machine Gun Buy");
        }
      else
        {
         // Log explicit reason for skip (Risk % too high for balance)
         Print(">>> TRADE SKIPPED: Risk check failed (Volume 0.0).");
        }
     }

   // 3. Sell Signal (Downtrend + RSI crossover out of Overbought)
   // RSI was above 70, now is below 70
   else if(isDowntrend && rsi[1] > InpRsiOverbought && rsi[0] < InpRsiOverbought)
     {
      Print(">>> SELL SIGNAL: Price < EMA and RSI crossing down from Overbought");

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = bid + InpStopLoss * _Point;
      double tp  = bid - InpTakeProfit * _Point;
      double lot = CalculateLotSize(InpStopLoss);

      // Execute only if lot size is valid (Risk Management)
      if(lot > 0)
        {
         trade.Sell(lot, _Symbol, bid, sl, tp, "DTECH Machine Gun Sell");
        }
      else
        {
         // Log explicit reason for skip (Risk % too high for balance)
         Print(">>> TRADE SKIPPED: Risk check failed (Volume 0.0).");
        }
     }
  }

//--- Force History Download
void DownloadHistory()
  {
   Print(">> FORCE DOWNLOAD: Attempting to synchronize history data for ", _Symbol);

   // Check if synchronized
   if(!SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_SYNCHRONIZED))
     {
      Print(">> Series not synchronized. Requesting data...");
     }

   // Attempt to copy deep history (e.g., last 3 years)
   datetime startTime = TimeCurrent() - 3 * 365 * 24 * 3600; // Approx 3 years ago
   MqlRates rates[];

   // Requesting data forces the terminal to download it
   int copied = CopyRates(_Symbol, PERIOD_CURRENT, startTime, TimeCurrent(), rates);

   if(copied > 0)
     Print(">> Successfully accessed ", copied, " bars of history. Data should be downloading.");
   else
     Print(">> Warning: Could not immediately access deep history. Terminal will download in background.");
  }

//--- Update Status (Chart Comment & Log)
void UpdateStatus()
  {
   // Only update if connected
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;

   double rsiArr[];
   double emaArr[];
   double closeArr[];
   ArraySetAsSeries(rsiArr, true);
   ArraySetAsSeries(emaArr, true);
   ArraySetAsSeries(closeArr, true);

   // Get current values (buffer 0, index 0, count 1)
   if(CopyBuffer(handleRSI, 0, 0, 1, rsiArr) < 1 ||
      CopyBuffer(handleTrendEMA, 0, 0, 1, emaArr) < 1 ||
      CopyClose(_Symbol, PERIOD_CURRENT, 0, 1, closeArr) < 1)
     {
      return;
     }

   double rsi = rsiArr[0];
   double ema = emaArr[0];
   double close = closeArr[0];
   string trend = (close > ema) ? "UPTREND (Price > EMA)" : "DOWNTREND (Price < EMA)";

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double nextLot = CalculateLotSize(InpStopLoss, false);

   string msg = StringFormat(
      "=== DTECH BOT V2 (AGGRESSOR) ===\n"
      "--------------------------------\n"
      "Balance: %.2f | Equity: %.2f\n"
      "Risk: %.1f%% | NEXT LOT: %.2f%s\n"
      "--------------------------------\n"
      "Price: %.5f | EMA(%d): %.5f\n"
      "Trend: %s\n"
      "RSI(%d): %.2f %s\n"
      "Spread: %d | Time: %s",
      bal, eq,
      InpRiskPercent, nextLot, (nextLot == 0.0 ? " (BLOCKED)" : ""),
      close, InpTrendPeriod, ema,
      trend,
      InpRsiPeriod, rsi, (rsi > InpRsiOverbought ? "(OB)" : (rsi < InpRsiOversold ? "(OS)" : "")),
      (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), TimeToString(TimeCurrent(), TIME_MINUTES)
   );

   Comment(msg);

   // Log status periodically (every 60 seconds)
   static datetime lastLog = 0;
   if(TimeCurrent() - lastLog >= 60)
     {
      Print("STATUS UPDATE: ", msg);
      lastLog = TimeCurrent();
     }
  }
