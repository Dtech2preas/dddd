//+------------------------------------------------------------------+
//|                                                 DTECH_BOT_V1.mq5 |
//|                                  Copyright 2025, D-TECH Services |
//|                                      https://preasx24.co.za      |
//+------------------------------------------------------------------+
#property copyright "D-TECH Services"
#property link      "https://preasx24.co.za"
#property version   "2.10" // Updated to 2.10 for Safety Pack
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
   RISK_FIXED,    // Fixed Lot Size (Manual)
   RISK_PERCENT   // Percentage of Equity (Auto)
  };

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

// --- SAFETY & CONTROL (BEGINNER PACK) ---
input group             "=== MAIN CONTROL ==="
input bool              InpMasterSwitch      = true;         // MASTER SWITCH (Turn False to STOP)
input bool              InpForceTestTrade    = false;        // Make ONE Test Trade Now (Verify System)

// --- Risk Management ---
input group             "=== Money & Risk ==="
input ENUM_RISK_MODE    InpRiskMode          = RISK_PERCENT; // Risk Calculation Mode
input double            InpRiskPercent       = 1.0;          // Risk % per Trade (Safe: 1%, Aggressive: 5%+)
input bool              InpUseRiskFallback   = true;         // Allow Min Lot if Account too small?
input double            InpFixedLot          = 0.01;         // Fixed Lot Size (if Fixed Mode used)
input double            InpMaxLot            = 100.0;        // Safety: Maximum allowed lot size

// --- Strategy Settings ---
input group             "=== Strategy Strategy ==="
input int               InpTrendPeriod       = 50;           // Trend Filter (EMA Period)
input int               InpRsiPeriod         = 9;            // Signal Sensor (RSI Period)
input int               InpRsiOverbought     = 70;           // Sell Zone (>70)
input int               InpRsiOversold       = 30;           // Buy Zone (<30)
input int               InpStopLoss          = 200;          // Stop Loss (Points) - Protection
input int               InpTakeProfit        = 400;          // Take Profit (Points) - Goal

// --- Trade Management ---
input group             "=== Trade Management ==="
input bool              InpUseTrailing       = true;         // Lock in Profits (Trailing Stop)
input int               InpTrailStart        = 100;          // Start locking after X points profit
input int               InpTrailDist         = 50;           // Keep Stop X points away from price

// --- Advanced Filters ---
input group             "=== Advanced Settings ==="
input int               InpMaxSpread         = 20;           // Max Spread (Points) - Avoid high costs
input int               InpStartHour         = 0;            // Start Trading Hour (0-23)
input int               InpEndHour           = 23;           // End Trading Hour (0-23)
input int               InpMaxPositions      = 5;            // Max Simultaneous Positions
input int               InpMagicNum          = 123456;       // Magic Number (ID)
input bool              InpForceHistoryDownload = true;      // Auto-Fix Charts (Download History)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+
CTrade         trade;
int            handleTrendEMA;
int            handleRSI;
bool           g_hasForcedTrade = false;

// Forward Declaration
void UpdateStatus();
bool CheckEnvironment();
void ManagePositions();
void CheckForEntry();
void DownloadHistory();
double CalculateLotSize(double slPoints, bool verbose=true);

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

   Print(">> DTECH BOT V2.1 (SAFETY MODE) INITIALIZED <<");
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
   Comment(""); // Clear chart
  }

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                               |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- MASTER SWITCH CHECK ---
   if(!InpMasterSwitch)
     {
      Comment("=== DTECH BOT PAUSED ===\nMaster Switch is OFF.\nTurn it ON in inputs to resume.");
      return;
     }

   // 0. Update Dashboard
   UpdateStatus();

   // 1. Check basic conditions (Terminal connected, Spread, etc.)
   if(!CheckEnvironment()) return;

   // --- FORCE TEST TRADE LOGIC (FIXED) ---
   // Only run if requested AND we haven't done it yet this session
   if(InpForceTestTrade && !g_hasForcedTrade)
     {
      // SAFETY: Check if a test trade is ALREADY open to prevent "Machine Gun" test trades
      bool testTradeExists = false;
      for(int i=PositionsTotal()-1; i>=0; i--)
        {
         if(PositionGetTicket(i) > 0)
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum &&
               PositionGetString(POSITION_COMMENT) == "DTECH Force Test")
              {
               testTradeExists = true;
               break;
              }
        }

      if(!testTradeExists)
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
        }
      else
        {
         // Quietly ignore if already open
        }

      g_hasForcedTrade = true; // Mark as done so we don't check again this session
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
      return(false); // Spread too high, unsafe to trade
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

      // --- TRAILING STOP LOGIC ---

      if(type == POSITION_TYPE_BUY)
        {
         // If profit > Start Level
         if(priceCurrent - open > InpTrailStart * point)
           {
            double newSL = priceCurrent - InpTrailDist * point;

            // Move SL up only
            if(newSL > sl + point)
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

            // Move SL down only
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
      return; // Waiting for data
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
      return;
     }

   // --- STRATEGY LOGIC ---

   // 1. Trend Direction
   bool isUptrend   = close[1] > trendMA[1];
   bool isDowntrend = close[1] < trendMA[1];

   // 2. Buy Signal (Uptrend + RSI crossover out of Oversold)
   if(isUptrend && rsi[1] < InpRsiOversold && rsi[0] > InpRsiOversold)
     {
      Print(">>> BUY SIGNAL DETECTED");

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = ask - InpStopLoss * _Point;
      double tp  = ask + InpTakeProfit * _Point;
      double lot = CalculateLotSize(InpStopLoss);

      if(lot > 0)
        {
         trade.Buy(lot, _Symbol, ask, sl, tp, "DTECH Machine Gun Buy");
        }
     }

   // 3. Sell Signal (Downtrend + RSI crossover out of Overbought)
   else if(isDowntrend && rsi[1] > InpRsiOverbought && rsi[0] < InpRsiOverbought)
     {
      Print(">>> SELL SIGNAL DETECTED");

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = bid + InpStopLoss * _Point;
      double tp  = bid - InpTakeProfit * _Point;
      double lot = CalculateLotSize(InpStopLoss);

      if(lot > 0)
        {
         trade.Sell(lot, _Symbol, bid, sl, tp, "DTECH Machine Gun Sell");
        }
     }
  }

//--- Force History Download
void DownloadHistory()
  {
   Print(">> DATA SYNC: Downloading history for ", _Symbol);
   datetime startTime = TimeCurrent() - 3 * 365 * 24 * 3600; // 3 years
   MqlRates rates[];
   CopyRates(_Symbol, PERIOD_CURRENT, startTime, TimeCurrent(), rates);
  }

//--- Update Status (Beginner Friendly Dashboard)
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

   if(CopyBuffer(handleRSI, 0, 0, 1, rsiArr) < 1 ||
      CopyBuffer(handleTrendEMA, 0, 0, 1, emaArr) < 1 ||
      CopyClose(_Symbol, PERIOD_CURRENT, 0, 1, closeArr) < 1)
     {
      return;
     }

   double rsi = rsiArr[0];
   double ema = emaArr[0];
   double close = closeArr[0];

   // Simplify Trend Status
   string trendMsg = "FLAT";
   if(close > ema) trendMsg = "UP (Look for Buys)";
   else trendMsg = "DOWN (Look for Sells)";

   // Simplify Account Info
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double nextLot = CalculateLotSize(InpStopLoss, false);

   string msg = StringFormat(
      "=== DTECH BOT V2.1 (SAFETY MODE) ===\n"
      "------------------------------------\n"
      "MASTER SWITCH:    %s\n"
      "------------------------------------\n"
      "Money (Banked):   $%.2f\n"
      "Equity (Live):    $%.2f\n"
      "Risk per Trade:   %.1f%% (Lot: %.2f)\n"
      "------------------------------------\n"
      "MARKET TREND:     %s\n"
      "SIGNAL STATUS:    RSI is %.1f %s\n"
      "Time:             %s",
      (InpMasterSwitch ? "ON (Trading Active)" : "OFF (Stopped)"),
      bal, eq,
      InpRiskPercent, nextLot,
      trendMsg,
      rsi, (rsi > InpRsiOverbought ? "(Overbought - Wait)" : (rsi < InpRsiOversold ? "(Oversold - Wait)" : "(Neutral)")),
      TimeToString(TimeCurrent(), TIME_MINUTES)
   );

   Comment(msg);
  }
