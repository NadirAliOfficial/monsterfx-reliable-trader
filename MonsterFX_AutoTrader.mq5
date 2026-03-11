#property copyright "MonsterFX Reliable Trader"
#property version   "5.0"
#property description "MonsterFX Pullback (Conservative) - Dual timeframe EMA strategy with VWAP, ATR-based SL/TP"

#include <Trade/Trade.mqh>

input group "=== SERVER SETTINGS ==="
input string   ServerURL = "http://127.0.0.1:5000";
input string   SecretKey = "Jx9B!p4t_92LmXz";

input group "=== RISK MANAGEMENT ==="
input double   DefaultLotSize = 0.01;
input double   MaxDrawdownPercent = 20.0;
input double   MaxDailyLossPercent = 10.0;
input int      MaxForexTradesPerDay = 7;
input int      MaxConcurrentTrades = 2;
input bool     UseATRBasedSLTP = true;
input double   ATRMultiplierSL = 1.5;
input double   ATRMultiplierTP = 3.0;
input int      ATRPeriod = 14;
input int      StopLossPips = 50;
input int      TakeProfitPips = 150;
input bool     UseTrailingStop = true;
input int      TrailingStopPips = 30;
input int      TrailingStepPips = 10;

input group "=== GOLD SIGNAL SETTINGS ==="
input bool     SendGoldSignals = true;
input int      MaxGoldSignalsPerDay = 5;
input int      GoldStopLossPips = 300;
input int      GoldTP1Pips = 300;
input int      GoldTP2Pips = 500;
input int      GoldTP3Pips = 800;

input group "=== STRATEGY SETTINGS ==="
input ENUM_TIMEFRAMES   TrendTF = PERIOD_M15;
input ENUM_TIMEFRAMES   EntryTF = PERIOD_M5;
input int               FastEMA = 21;
input int               SlowEMA = 50;
input int               TrendEMA = 200;
input bool              UseTrendFilter = true;
input bool              UseRSIFilter = true;
input bool              UseVWAPFilter = true;
input int               RSIPeriod = 14;
input int               RSIOverbought = 70;
input int               RSIOversold = 30;

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter = true;                      
input int      LondonStartHour = 8;                          
input int      LondonEndHour = 16;                           
input int      NewYorkStartHour = 13;                        
input int      NewYorkEndHour = 21;                          
input bool     TradeOnFriday = true;                         
input int      FridayStopHour = 20;

input group "=== NEWS FILTER ==="
input bool     UseNewsFilter = true;
input int      NewsAvoidMinutesBefore = 30;
input int      NewsAvoidMinutesAfter = 15;                          


input group "=== OTHER SETTINGS ==="
input ulong    MagicNumber = 202412;                         
input int      StatusUpdateSeconds = 30;                     


string TradingPairs[] = {"EURUSD", "USDCAD", "EURGBP"};
string GoldPair = "XAUUSD";
int    NumPairs;


CTrade   trade;
double   InitialBalance;
double   DailyStartingBalance = 0.0;
datetime DailyResetDate = 0;
int      DailyTradeCount = 0;
int      DailyGoldSignalCount = 0;
bool     TradingEnabled = true;
datetime LastStatusUpdate = 0;
datetime LastBarTime[];


int HandleFastEMA[];
int HandleSlowEMA[];
int HandleTrendEMA[];
int HandleRSI[];
int HandleATR[];
int HandleVWAP[];


int HandleGoldFastEMA;
int HandleGoldSlowEMA;
int HandleGoldTrendEMA;
int HandleGoldRSI;
datetime GoldLastBarTime = 0;


struct GoldSignalTrack
{
   bool     active;
   string   direction;    
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;
   double   tp3;
   bool     tp1_hit;
   bool     tp2_hit;
   bool     tp3_hit;
   bool     sl_hit;
   datetime signal_time;
};

GoldSignalTrack ActiveGoldSignals[10];  
int NumActiveGoldSignals = 0;




int OnInit()
{
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   NumPairs = ArraySize(TradingPairs);
   
   
   ArrayResize(LastBarTime, NumPairs);
   ArrayResize(HandleFastEMA, NumPairs);
   ArrayResize(HandleSlowEMA, NumPairs);
   ArrayResize(HandleTrendEMA, NumPairs);
   ArrayResize(HandleRSI, NumPairs);
   ArrayResize(HandleATR, NumPairs);
   ArrayResize(HandleVWAP, NumPairs);
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   DailyResetDate = StructToTime(dt);
   DailyResetDate = DailyResetDate - (dt.hour * 3600) - (dt.min * 60) - dt.sec;
   DailyStartingBalance = InitialBalance;
   
   for(int i = 0; i < NumPairs; i++)
   {
      LastBarTime[i] = 0;
      string symbol = TradingPairs[i];
      
      if(!SymbolSelect(symbol, true))
      {
         Print("WARNING: Could not select symbol: ", symbol);
         continue;
      }
      
      HandleFastEMA[i] = iMA(symbol, EntryTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
      HandleSlowEMA[i] = iMA(symbol, EntryTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
      HandleTrendEMA[i] = iMA(symbol, TrendTF, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
      HandleRSI[i] = iRSI(symbol, EntryTF, RSIPeriod, PRICE_CLOSE);
      HandleATR[i] = iATR(symbol, EntryTF, ATRPeriod);
      
      if(UseVWAPFilter)
      {
         HandleVWAP[i] = iCustom(symbol, EntryTF, "VWAP");
         if(HandleVWAP[i] == INVALID_HANDLE)
         {
            Print("WARNING: VWAP indicator not found. Trying alternative VWAP...");
            HandleVWAP[i] = iCustom(symbol, EntryTF, "VWAP_Indicator");
            if(HandleVWAP[i] == INVALID_HANDLE)
            {
               Print("WARNING: VWAP indicator not available for ", symbol, ". Continuing without VWAP filter.");
               HandleVWAP[i] = INVALID_HANDLE;
            }
         }
      }
      else
      {
         HandleVWAP[i] = INVALID_HANDLE;
      }
      
      if(HandleFastEMA[i] == INVALID_HANDLE || HandleSlowEMA[i] == INVALID_HANDLE ||
         HandleTrendEMA[i] == INVALID_HANDLE || HandleRSI[i] == INVALID_HANDLE || HandleATR[i] == INVALID_HANDLE)
   
   
   
   if(SendGoldSignals)
   {
      if(SymbolSelect(GoldPair, true))
      {
         HandleGoldFastEMA = iMA(GoldPair, EntryTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
         HandleGoldSlowEMA = iMA(GoldPair, EntryTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
         HandleGoldTrendEMA = iMA(GoldPair, TrendTF, TrendEMA, 0, MODE_EMA, PRICE_CLOSE);
         HandleGoldRSI = iRSI(GoldPair, EntryTF, RSIPeriod, PRICE_CLOSE);
         Print("Gold (XAUUSD) SIGNALS enabled - NO auto-trading");
      }
      else
      {
         Print("WARNING: Could not select XAUUSD for signals");
      }
   }
   
   
   Print("============================================");
   Print("   MonsterFX Pullback (Conservative) v5.0");
   Print("============================================");
   Print("Initial Balance: $", DoubleToString(InitialBalance, 2));
   Print("Max Drawdown: ", DoubleToString(MaxDrawdownPercent, 1), "%");
   Print("Max Daily Loss: ", DoubleToString(MaxDailyLossPercent, 1), "%");
   Print("Max Trades/Day: ", MaxForexTradesPerDay);
   Print("Max Concurrent: ", MaxConcurrentTrades);
   Print("Lot Size: ", DoubleToString(DefaultLotSize, 2));
   Print("");
   Print("STRATEGY:");
   Print("   Trend TF: ", EnumToString(TrendTF), " (EMA ", TrendEMA, ")");
   Print("   Entry TF: ", EnumToString(EntryTF), " (EMA ", FastEMA, "/", SlowEMA, ")");
(UseNewsFilter ? "ON" : "OFF"));
   Print("");
   Print("TRADING PAIRS:");
   for(int i = 0; i < NumPairs; i++)
      Print("   - ", TradingPairs[i]);
   Print("============================================");
   
   
   string pairsList = "";
   for(int i = 0; i < NumPairs; i++)
   {
      pairsList += TradingPairs[i];
      if(i < NumPairs - 1) pairsList += ", ";
   }
   
   
   string startupMsg = StringFormat(
      "MonsterFX Pullback (Conservative) Started\\n\\n" +
      "Strategy: EMA %d/%d Crossover\\n" +
      "Trend TF: %s (EMA %d)\\n" +
      "Entry TF: %s (EMA %d/%d)\\n" +
  
      "Max DD: %.1f%%\\n" +
      "Max Daily Loss: %.1f%%\\n" +
      "Max Trades/Day: %d\\n" +
      "Max Concurrent: %d\\n" +
      "Trailing Stop: %s\\n\\n" +
      "Pairs: %s",
      FastEMA, SlowEMA,
      EnumToString(TrendTF), TrendEMA,
      EnumToString(EntryTF), FastEMA, SlowEMA,
      (UseVWAPFilter ? "ON" : "OFF"),
      (UseRSIFilter ? "ON" : "OFF"),
      (UseATRBasedSLTP ? "ON" : "OFF"),
      (UseSessionFilter ? "ON" : "OFF"),
      DefaultLotSize,
      MaxDrawdownPercent,
      MaxDailyLossPercent,
      MaxForexTradesPerDay,
      MaxConcurrentTrades,
      (UseTrailingStop ? "ON" : "OFF"),
      pairsList
   );
   
   SendTradeUpdate("SYSTEM", "BOT", startupMsg, 0, 0, 0, 0, 0, 0.0);
   SendStatusUpdate();
   
   return(INIT_SUCCEEDED);
}




void OnDeinit(const int reason)
{
   
   for(int i = 0; i < NumPairs; i++)
   {
      if(HandleFastEMA[i] != INVALID_HANDLE) IndicatorRelease(HandleFastEMA[i]);
      if(HandleSlowEMA[i] != INVALID_HANDLE) IndicatorRelease(HandleSlowEMA[i]);
      if(HandleTrendEMA[i] != INVALID_HANDLE) IndicatorRelease(HandleTrendEMA[i]);
      if(HandleRSI[i] != INVALID_HANDLE) IndicatorRelease(HandleRSI[i]);
      if(HandleATR[i] != INVALID_HANDLE) IndicatorRelease(HandleATR[i]);
      if(HandleVWAP[i] != INVALID_HANDLE) IndicatorRelease(HandleVWAP[i]);
   }
   
   SendTradeUpdate("SYSTEM", "BOT", "MonsterFX Pullback (Conservative) Stopped", 0, 0, 0, 0, 0, 0.0);
   Print("MonsterFX Pullback (Conservative) Stopped");
}




void OnTick()
{
   CheckDaily
         TradingEnabled = false;
         double dd = GetCurrentDrawdown();
         double dailyLoss = GetDailyLoss();
         string reason = "";
         if(dd >= MaxDrawdownPercent)
            reason = StringFormat("MAX DRAWDOWN REACHED (%.2f%%)", dd);
         else if(dailyLoss >= MaxDailyLossPercent)
            reason = StringFormat("DAILY LOSS LIMIT REACHED (%.2f%%)", dailyLoss);
         
         SendTradeUpdate("DRAWDOWN", "ALERT",
            StringFormat("%s\\n\\nTrading stopped.\\nAll positions closed.\\n\\nInitial: $%.2f\\nEquity: $%.2f",
               reason, InitialBalance, AccountInfoDouble(ACCOUNT_EQUITY)),
            0, 0, 0, 0, 0, 0.0);
         CloseAllTrades(reason);
      }
      return;
   }
   TradingEnabled = true;
   
   
   if(UseTrailingStop)
      ManageTrailingStops();
   
   
   bool canTrade = true;
   if(UseSessionFilter)
      canTrade = IsValidTradingSession();
   
   
   if(canTrade)
   {
      for(int i = 0; i < NumPairs; i++)
      {
         RunStrategyForPair(i);
      }
      
      
      if(SendGoldSignals)
      {
         CheckGoldSignal();
      }
   }
   
   
   if(SendGoldSignals)
   {
      MonitorGoldSignals();
   }
   
   
   if(TimeCurrent() - LastStatusUpdate >= StatusUpdateSeconds)
   {
      SendStatusUpdate();
      LastStatusUpdate = TimeCurrent();
   }
}



   MqlDateTime dt;
   TimeGMT(dt);
   
   int hour = dt.hour;
   int dayOfWeek = dt.day_of_week;
   
   
   if(dayOfWeek == 0 || dayOfWeek == 6)
      return false;
   
   
   if(dayOfWeek == 5 && !TradeOnFriday)
      return false;
   
   if(dayOfWeek == 5 && hour >= FridayStopHour)
      return false;
   
   
   bool inLondon = (hour >= LondonStartHour && hour < LondonEndHour);
   
   
   bool inNewYork = (hour >= NewYorkStartHour && hour < NewYorkEndHour);
   
   return (inLondon || inNewYork);
}




double GetCurrentDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InitialBalance <= 0.0) return 0.0;
   return ((InitialBalance - equity) / InitialBalance) * 100.0;
}

bool CheckDrawdown()
{
   double drawdown = GetCurrentDrawdown();
   
   static bool warning_sent = false;
   if(drawdown >= 15.0 && drawdown < MaxDrawdownPercent && !warning_sent)
   {
      SendTradeUpdate("ALERT", "WARNING",
         StringFormat("Drawdown Warning: %.2f%%\\n\\nApproaching maximum limit.", drawdown),
         0, 0, 0, 0, 0, 0.0);
      warning_sent = true;
   }
   if(drawdown < 15.0) warning_sent = false;
   
   return (drawdown < MaxDrawdownPercent);
}

void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime currentDate = StructToTime(dt);
   currentDate = currentDate - (dt.hour * 3600) - (dt.min * 60) - dt.sec;
   
   if(currentDate > DailyResetDate)
   {
      DailyResetDate = currentDate;
      DailyStartingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      DailyTradeCount = 0;
      DailyGoldSignalCount = 0;
      Print("Daily counters reset. Starting balance: $", DoubleToString(DailyStartingBalance, 2));
   }
}

double GetDailyLoss()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(DailyStartingBalance <= 0.0) return 0.0;
   double loss = DailyStartingBalance - currentBalance;
   return (loss / DailyStartingBalance) * 100.0;
}

bool CheckDailyLoss()
{
   double dailyLoss = GetDailyLoss();
   return (dailyLoss < MaxDailyLossPercent);
}

int GetConcurrentTradesCount()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
            count++;
      }
   }
   return count;
}

bool IsNewsTime()
{
   if(!UseNewsFilter) return false;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   int hour = dt.hour;
   int minute = dt.min;
   
   int totalMinutes = hour * 60 + minute;
   
   int newsTimes[][2] = {
      {8*60 + 30, 8*60 + 45},
      {10*60 + 0, 10*60 + 15},
      {13*60 + 30, 13*60 + 45},
      {15*60 + 0, 15*60 + 15}
   };
   
   for(int i = 0; i < ArrayRange(newsTimes, 0); i++)
   {
      int start = newsTimes[i][0] - NewsAvoidMinutesBefore;
      int end = newsTimes[i][1] + NewsAvoidMinutesAfter;
      if(totalMinutes >= start && totalMinutes <= end)
         return true;
   }
   
   return false;
}




double CalculateVWAP(string symbol, ENUM_TIMEFRAMES tf, int periods = 20)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(symbol, tf, 0, periods, rates) < periods) return 0.0;
   
   double totalPV = 0.0;
   long totalVolume = 0;
   
   for(int i = 0; i < periods; i++)
   {
      double typicalPrice = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      long volume = rates[i].tick_volume;
      totalPV += typicalPrice * volume;
      totalVolume += volume;
   }
   
   if(totalVolume == 0) return 0.0;
   return totalPV / totalVolume;
}

bool GetIndicatorValues(int pairIndex, double &fastCurr, double &fastPrev, 
                        double &slowCurr, double &slowPrev,
                        double &trendEMA, double &rsiValue, double &atrValue, double &vwapValue)
{
   double fastBuffer[], slowBuffer[], trendBuffer[], rsiBuffer[], atrBuffer[], vwapBuffer[];
   ArraySetAsSeries(fastBuffer, true);
   ArraySetAsSeries(slowBuffer, true);
   ArraySetAsSeries(trendBuffer, true);
   ArraySetAsSeries(rsiBuffer, true);
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(vwapBuffer, true);
   
   if(CopyBuffer(HandleFastEMA[pairIndex], 0, 1, 2, fastBuffer) < 2) return false;
   if(CopyBuffer(HandleSlowEMA[pairIndex], 0, 1, 2, slowBuffer) < 2) return false;
   if(CopyBuffer(HandleTrendEMA[pairIndex], 0, 1, 1, trendBuffer) < 1) return false;
   if(CopyBuffer(HandleRSI[pairIndex], 0, 1, 1, rsiBuffer) < 1) return false;
   if(CopyBuffer(HandleATR[pairIndex], 0, 1, 1, atrBuffer) < 1) return false;
   
   fastCurr = fastBuffer[0];
   fastPrev = fastBuffer[1];
   slowCurr = slowBuffer[0];
   slowPrev = slowBuffer[1];
   trendEMA = trendBuffer[0];
   rsiValue = rsiBuffer[0];
   atrValue = atrBuffer[0];
   
   if(UseVWAPFilter)
   {
      if(HandleVWAP[pairIndex] != INVALID_HANDLE)
      {
         if(CopyBuffer(HandleVWAP[pairIndex], 0, 1, 1, vwapBuffer) >= 1)
            vwapValue = vwapBuffer[0];
         else
            vwapValue = CalculateVWAP(TradingPairs[pairIndex], EntryTF);
      }
      else
      {
         vwapValue = CalculateVWAP(TradingPairs[pairIndex], EntryTF);
      }
   }
   else
   {
      vwapValue = 0.0;
   }
   
   return true;
}




bool CheckBuySignal(int pairIndex, string symbol, string &reason)
{
   double fastCurr, fastPrev, slowCurr, slowPrev, trendEMA, rsiValue, atrValue, vwapValue;
   
   if(!GetIndicatorValues(pairIndex, fastCurr, fastPrev, slowCurr, slowPrev, trendEMA, rsiValue, atrValue, vwapValue))
      return false;
   
   double price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   
   bool emaCrossover = (fastPrev <= slowPrev && fastCurr > slowCurr);
   if(!emaCrossover) return false;
   
   if(UseTrendFilter)
   {
      if(price < trendEMA)
      {
         Print("INFO: ", symbol, " BUY signal rejected: Price below EMA ", TrendEMA, " (downtrend)");
         return false;
      }
   }
   
   if(UseVWAPFilter && vwapValue > 0.0)
   {
      if(price < vwapValue)
      {
         Print("INFO: ", symbol, " BUY signal rejected: Price below VWAP");
         return false;
      }
   }
   
   if(UseRSIFilter)
   {
      if(rsiValue > RSIOverbought)
      {
         Print("INFO: ", symbol, " BUY signal rejected: RSI overbought (", DoubleToString(rsiValue, 1), ")");
         return false;
      }
   }
   
   reason = StringFormat(
      "EMA %d crossed above EMA %d\\n" +
      "Trend: Price above EMA %d [OK]\\n" +
      "RSI: %.1f [OK]",
      FastEMA, SlowEMA, TrendEMA, rsiValue
   );
   
   if(UseVWAPFilter && vwapValue > 0.0)
      reason += StringFormat("\\nVWAP: %.5f [OK]", vwapValue);
   
   return true;
}




bool CheckSellSignal(int pairIndex, string symbol, string &reason)
{
   double fastCurr, fastPrev, slowCurr, slowPrev, trendEMA, rsiValue, atrValue, vwapValue;
   
   if(!GetIndicatorValues(pairIndex, fastCurr, fastPrev, slowCurr, slowPrev, trendEMA, rsiValue, atrValue, vwapValue))
      return false;
   
   double price = SymbolInfoDouble(symbol, SYMBOL_BID);
   
   bool emaCrossover = (fastPrev >= slowPrev && fastCurr < slowCurr);
   if(!emaCrossover) return false;
   
   if(UseTrendFilter)
   {
      if(price > trendEMA)
      {
         Print("INFO: ", symbol, " SELL signal rejected: Price above EMA ", TrendEMA, " (uptrend)");
         return false;
      }
   }
   
   if(UseVWAPFilter && vwapValue > 0.0)
   {
      if(price > vwapValue)
      {
         Print("INFO: ", symbol, " SELL signal rejected: Price above VWAP");
         return false;
      }
   }
   
   if(UseRSIFilter)
   {
      if(rsiValue < RSIOversold)
      {
         Print("INFO: ", symbol, " SELL signal rejected: RSI oversold (", DoubleToString(rsiValue, 1), ")");
         return false;
      }
   }
   
   reason = StringFormat(
      "EMA %d crossed below EMA %d\\n" +
      "Trend: Price below EMA %d [OK]\\n" +
      "RSI: %.1f [OK]",
      FastEMA, SlowEMA, TrendEMA, rsiValue
   );
   
   if(UseVWAPFilter && vwapValue > 0.0)
      reason += StringFormat("\\nVWAP: %.5f [OK]", vwapValue);
   
   return true;
}




bool GetSymbolPosition(string symbol, long &type, ulong &ticket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         if(PositionGetString(POSITION_SYMBOL) == symbol &&
            PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         {
            type = PositionGetInteger(POSITION_TYPE);
            ticket = t;
            return true;
         }
      }
   }
   return false;
}




void OpenPosition(string symbol, long posType, string reason)
{
   if(!TradingEnabled) return;
   if(!SymbolSelect(symbol, true)) return;
   
   if(IsNewsTime())
   {
      Print("INFO: Trading skipped due to news filter");
      return;
   }
   
   if(GetConcurrentTradesCount() >= MaxConcurrentTrades)
   {
      Print("WARNING: Maximum concurrent trades (", MaxConcurrentTrades, ") reached. Cannot open new position.");
      return;
   }
   
   if(DailyTradeCount >= MaxForexTradesPerDay)
   {
      Print("WARNING: Maximum daily trades (", MaxForexTradesPerDay, ") reached. Cannot open new position.");
      return;
   }
   
   long existingType;
   ulong existingTicket;
   if(GetSymbolPosition(symbol, existingType, existingTicket))
   {
      Print("WARNING: Already have position for ", symbol);
      return;
   }
   
   int pairIndex = -1;
   for(int i = 0; i < NumPairs; i++)
   {
      if(TradingPairs[i] == symbol)
      {
         pairIndex = i;
         break;
      }
   }
   
   if(pairIndex == -1) return;
   
   double atrValue = 0.0;
   if(UseATRBasedSLTP && HandleATR[pairIndex] != INVALID_HANDLE)
   {
      double atrBuffer[];
      ArraySetAsSeries(atrBuffer, true);
      if(CopyBuffer(HandleATR[pairIndex], 0, 1, 1, atrBuffer) >= 1)
         atrValue = atrBuffer[0];
   }
   
   double price = 0.0;
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int pipFactor = (digits == 3 || digits == 5) ? 10 : 1;
   
   double sl = 0.0, tp = 0.0;
   
   if(posType == POSITION_TYPE_BUY)
   {
      price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      
      if(UseATRBasedSLTP && atrValue > 0.0)
      {
         sl = NormalizeDouble(price - atrValue * ATRMultiplierSL, digits);
         tp = NormalizeDouble(price + atrValue * ATRMultiplierTP, digits);
      }
      else
      {
         if(StopLossPips > 0)
            sl = NormalizeDouble(price - StopLossPips * pipFactor * point, digits);
         if(TakeProfitPips > 0)
            tp = NormalizeDouble(price + TakeProfitPips * pipFactor * point, digits);
      }
      
      if(trade.Buy(DefaultLotSize, symbol, price, sl, tp, "MonsterFX EA"))
      {
         ulong ticket = trade.ResultOrder();
         DailyTradeCount++;
         Print("SUCCESS: BUY ", symbol, " @ ", DoubleToString(price, digits), " Ticket: ", ticket, " (", DailyTradeCount, "/", MaxForexTradesPerDay, " today)");
         
         SendTradeUpdate("BUY", symbol,
            StringFormat("RELIABLE BUY Signal\\n\\n%s", reason),
            price, sl, tp, DefaultLotSize, (long)ticket, 0.0);
      }
      else
      {
         Print("ERROR: BUY failed: ", trade.ResultRetcodeDescription());
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      price = SymbolInfoDouble(symbol, SYMBOL_BID);
      
      if(UseATRBasedSLTP && atrValue > 0.0)
      {
         sl = NormalizeDouble(price + atrValue * ATRMultiplierSL, digits);
         tp = NormalizeDouble(price - atrValue * ATRMultiplierTP, digits);
      }
      else
      {
         if(StopLossPips > 0)
            sl = NormalizeDouble(price + StopLossPips * pipFactor * point, digits);
         if(TakeProfitPips > 0)
            tp = NormalizeDouble(price - TakeProfitPips * pipFactor * point, digits);
      }
      
      if(trade.Sell(DefaultLotSize, symbol, price, sl, tp, "MonsterFX EA"))
      {
         ulong ticket = trade.ResultOrder();
         DailyTradeCount++;
         Print("SUCCESS: SELL ", symbol, " @ ", DoubleToString(price, digits), " Ticket: ", ticket, " (", DailyTradeCount, "/", MaxForexTradesPerDay, " today)");
         
         SendTradeUpdate("SELL", symbol,
            StringFormat("RELIABLE SELL Signal\\n\\n%s", reason),
            price, sl, tp, DefaultLotSize, (long)ticket, 0.0);
      }
      else
      {
         Print("ERROR: SELL failed: ", trade.ResultRetcodeDescription());
      }
   }
}




bool ClosePosition(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   
   string symbol = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double profit = PositionGetDouble(POSITION_PROFIT);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume = PositionGetDouble(POSITION_VOLUME);
   
   double closePrice = (type == POSITION_TYPE_BUY) ?
                       SymbolInfoDouble(symbol, SYMBOL_BID) :
                       SymbolInfoDouble(symbol, SYMBOL_ASK);
   
   if(trade.PositionClose(ticket))
   {
      string typeStr = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      string profitStr = (profit >= 0) ? StringFormat("+$%.2f", profit) : StringFormat("-$%.2f", MathAbs(profit));
      
      Print("SUCCESS: Closed ", symbol, " ", typeStr, " Profit: ", profitStr);
      
      SendTradeUpdate("CLOSE", symbol,
         StringFormat("Position Closed\\n\\n%s\\n\\nType: %s\\nOpen: %.5f\\nClose: %.5f\\nProfit: %s",
            reason, typeStr, openPrice, closePrice, profitStr),
         closePrice, 0, 0, volume, (long)ticket, profit);
      
      return true;
   }
   return false;
}




void ManageTrailingStops()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
      
      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int pipFactor = (digits == 3 || digits == 5) ? 10 : 1;
      
      double trailDistance = TrailingStopPips * pipFactor * point;
      double trailStep = TrailingStepPips * pipFactor * point;
      
      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDistance, digits);
         
         
         if(bid > openPrice + trailDistance)
         {
            if(newSL > currentSL + trailStep)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("INFO: Trailing SL updated for ", symbol, ": ", DoubleToString(newSL, digits));
            }
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDistance, digits);
         
         if(ask < openPrice - trailDistance)
         {
            if(currentSL == 0 || newSL < currentSL - trailStep)
            {
               trade.PositionModify(ticket, newSL, currentTP);
               Print("INFO: Trailing SL updated for ", symbol, ": ", DoubleToString(newSL, digits));
            }
         }
      }
   }
}




void RunStrategyForPair(int pairIndex)
{
   if(!TradingEnabled) return;
   
   string symbol = TradingPairs[pairIndex];
   
   MqlRates rates[1];
   if(CopyRates(symbol, EntryTF, 0, 1, rates) < 1) return;
   
   if(rates[0].time == LastBarTime[pairIndex]) return;
   LastBarTime[pairIndex] = rates[0].time;
   
   
   long posType;
   ulong posTicket;
   bool hasPos = GetSymbolPosition(symbol, posType, posTicket);
   
   
   string buyReason = "", sellReason = "";
   bool buySignal = CheckBuySignal(pairIndex, symbol, buyReason);
   bool sellSignal = CheckSellSignal(pairIndex, symbol, sellReason);
   
   
   if(!hasPos)
   {
      if(buySignal)
      {
         Print("SIGNAL: ", symbol, " - RELIABLE BUY signal detected");
         OpenPosition(symbol, POSITION_TYPE_BUY, buyReason);
      }
      else if(sellSignal)
      {
         Print("SIGNAL: ", symbol, " - RELIABLE SELL signal detected");
         OpenPosition(symbol, POSITION_TYPE_SELL, sellReason);
      }
      return;
   }
   
   
   if(hasPos)
   {
      if(posType == POSITION_TYPE_BUY && sellSignal)
      {
         Print("SIGNAL: ", symbol, " - Opposite signal: Closing BUY");
         if(ClosePosition(posTicket, "Opposite EMA signal"))
         {
            Sleep(500);
            OpenPosition(symbol, POSITION_TYPE_SELL, sellReason);
         }
      }
      else if(posType == POSITION_TYPE_SELL && buySignal)
      {
         Print("SIGNAL: ", symbol, " - Opposite signal: Closing SELL");
         if(ClosePosition(posTicket, "Opposite EMA signal"))
         {
            Sleep(500);
            OpenPosition(symbol, POSITION_TYPE_BUY, buyReason);
         }
      }
   }
}




void CloseAllTrades(string reason)
{
   double totalProfit = 0;
   int closedCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(trade.PositionClose(ticket))
            {
               totalProfit += profit;
               closedCount++;
            }
         }
      }
   }
   
   if(closedCount > 0)
   {
      string profitStr = (totalProfit >= 0) ?
                         StringFormat("+$%.2f", totalProfit) :
                         StringFormat("-$%.2f", MathAbs(totalProfit));
      
      SendTradeUpdate("CLOSE", "ALL",
         StringFormat("All Positions Closed\\n\\nReason: %s\\nClosed: %d trade(s)\\nTotal P/L: %s",
            reason, closedCount, profitStr),
         0, 0, 0, 0, 0, totalProfit);
   }
}




void CheckGoldSignal()
{
   if(DailyGoldSignalCount >= MaxGoldSignalsPerDay)
   {
      Print("WARNING: Maximum Gold signals per day (", MaxGoldSignalsPerDay, ") reached.");
      return;
   }
   
   MqlRates rates[1];
   if(CopyRates(GoldPair, EntryTF, 0, 1, rates) < 1) return;
   
   if(rates[0].time == GoldLastBarTime) return;
   GoldLastBarTime = rates[0].time;
   
   
   double fastBuffer[], slowBuffer[], trendBuffer[], rsiBuffer[];
   ArraySetAsSeries(fastBuffer, true);
   ArraySetAsSeries(slowBuffer, true);
   ArraySetAsSeries(trendBuffer, true);
   ArraySetAsSeries(rsiBuffer, true);
   
   if(CopyBuffer(HandleGoldFastEMA, 0, 1, 2, fastBuffer) < 2) return;
   if(CopyBuffer(HandleGoldSlowEMA, 0, 1, 2, slowBuffer) < 2) return;
   if(CopyBuffer(HandleGoldTrendEMA, 0, 1, 1, trendBuffer) < 1) return;
   if(CopyBuffer(HandleGoldRSI, 0, 1, 1, rsiBuffer) < 1) return;
   
   double fastCurr = fastBuffer[0];
   double fastPrev = fastBuffer[1];
   double slowCurr = slowBuffer[0];
   double slowPrev = slowBuffer[1];
   double trendEMA = trendBuffer[0];
   double rsiValue = rsiBuffer[0];
   
   double askPrice = SymbolInfoDouble(GoldPair, SYMBOL_ASK);
   double bidPrice = SymbolInfoDouble(GoldPair, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(GoldPair, SYMBOL_DIGITS);
   
   
   double pipValue = 0.1;
   
   
   bool buySignal = (fastPrev <= slowPrev && fastCurr > slowCurr);
   if(UseTrendFilter && askPrice < trendEMA) buySignal = false;
   if(UseRSIFilter && rsiValue > RSIOverbought) buySignal = false;
   
   
   bool sellSignal = (fastPrev >= slowPrev && fastCurr < slowCurr);
   if(UseTrendFilter && bidPrice > trendEMA) sellSignal = false;
   if(UseRSIFilter && rsiValue < RSIOversold) sellSignal = false;
   
   
   if(buySignal)
   {
      double entry = askPrice;
      double sl = NormalizeDouble(entry - GoldStopLossPips * pipValue, digits);
      double tp1 = NormalizeDouble(entry + GoldTP1Pips * pipValue, digits);
      double tp2 = NormalizeDouble(entry + GoldTP2Pips * pipValue, digits);
      double tp3 = NormalizeDouble(entry + GoldTP3Pips * pipValue, digits);
      
      Print("GOLD BUY SIGNAL detected - sending to Discord (no auto-trade)");
      SendGoldSignal("BUY", entry, sl, tp1, tp2, tp3, rsiValue);
      DailyGoldSignalCount++;
      StoreGoldSignal("BUY", entry, sl, tp1, tp2, tp3);
   }
   else if(sellSignal)
   {
      double entry = bidPrice;
      double sl = NormalizeDouble(entry + GoldStopLossPips * pipValue, digits);
      double tp1 = NormalizeDouble(entry - GoldTP1Pips * pipValue, digits);
      double tp2 = NormalizeDouble(entry - GoldTP2Pips * pipValue, digits);
      double tp3 = NormalizeDouble(entry - GoldTP3Pips * pipValue, digits);
      
      Print("GOLD SELL SIGNAL detected - sending to Discord (no auto-trade)");
      SendGoldSignal("SELL", entry, sl, tp1, tp2, tp3, rsiValue);
      DailyGoldSignalCount++;
      StoreGoldSignal("SELL", entry, sl, tp1, tp2, tp3);
   }
}




void StoreGoldSignal(string direction, double entry, double sl, double tp1, double tp2, double tp3)
{
   
   int slot = -1;
   for(int i = 0; i < 10; i++)
   {
      if(!ActiveGoldSignals[i].active)
      {
         slot = i;
         break;
      }
   }
   
   
   if(slot == -1) slot = 0;
   
   ActiveGoldSignals[slot].active = true;
   ActiveGoldSignals[slot].direction = direction;
   ActiveGoldSignals[slot].entry = entry;
   ActiveGoldSignals[slot].sl = sl;
   ActiveGoldSignals[slot].tp1 = tp1;
   ActiveGoldSignals[slot].tp2 = tp2;
   ActiveGoldSignals[slot].tp3 = tp3;
   ActiveGoldSignals[slot].tp1_hit = false;
   ActiveGoldSignals[slot].tp2_hit = false;
   ActiveGoldSignals[slot].tp3_hit = false;
   ActiveGoldSignals[slot].sl_hit = false;
   ActiveGoldSignals[slot].signal_time = TimeCurrent();
   
   Print("Gold signal stored for tracking: ", direction, " @ ", entry);
}




void MonitorGoldSignals()
{
   double bid = SymbolInfoDouble(GoldPair, SYMBOL_BID);
   double ask = SymbolInfoDouble(GoldPair, SYMBOL_ASK);
   
   for(int i = 0; i < 10; i++)
   {
      if(!ActiveGoldSignals[i].active) continue;
      
      double currentPrice = (ActiveGoldSignals[i].direction == "BUY") ? bid : ask;
      
      if(ActiveGoldSignals[i].direction == "BUY")
      {
         
         if(!ActiveGoldSignals[i].tp1_hit && currentPrice >= ActiveGoldSignals[i].tp1)
         {
            ActiveGoldSignals[i].tp1_hit = true;
            double pips = (ActiveGoldSignals[i].tp1 - ActiveGoldSignals[i].entry) * 10;
            SendGoldTPHit("TP1", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].tp1, pips);
            Print("GOLD TP1 HIT: ", ActiveGoldSignals[i].tp1);
         }
         if(!ActiveGoldSignals[i].tp2_hit && currentPrice >= ActiveGoldSignals[i].tp2)
         {
            ActiveGoldSignals[i].tp2_hit = true;
            double pips = (ActiveGoldSignals[i].tp2 - ActiveGoldSignals[i].entry) * 10;
            SendGoldTPHit("TP2", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].tp2, pips);
            Print("GOLD TP2 HIT: ", ActiveGoldSignals[i].tp2);
         }
         if(!ActiveGoldSignals[i].tp3_hit && currentPrice >= ActiveGoldSignals[i].tp3)
         {
            ActiveGoldSignals[i].tp3_hit = true;
            double pips = (ActiveGoldSignals[i].tp3 - ActiveGoldSignals[i].entry) * 10;
            SendGoldTPHit("TP3", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].tp3, pips);
            Print("GOLD TP3 HIT: ", ActiveGoldSignals[i].tp3);
            
            ActiveGoldSignals[i].active = false;
         }
         
         
         if(!ActiveGoldSignals[i].sl_hit && currentPrice <= ActiveGoldSignals[i].sl)
         {
            ActiveGoldSignals[i].sl_hit = true;
            double pips = (ActiveGoldSignals[i].entry - ActiveGoldSignals[i].sl) * 10;
            SendGoldTPHit("SL", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].sl, -pips);
            Print("GOLD SL HIT: ", ActiveGoldSignals[i].sl);
            
            ActiveGoldSignals[i].active = false;
         }
      }
      else 
      {
         
         if(!ActiveGoldSignals[i].tp1_hit && currentPrice <= ActiveGoldSignals[i].tp1)
         {
            ActiveGoldSignals[i].tp1_hit = true;
            double pips = (ActiveGoldSignals[i].entry - ActiveGoldSignals[i].tp1) * 10;
            SendGoldTPHit("TP1", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].tp1, pips);
            Print("GOLD TP1 HIT: ", ActiveGoldSignals[i].tp1);
         }
         if(!ActiveGoldSignals[i].tp2_hit && currentPrice <= ActiveGoldSignals[i].tp2)
         {
            ActiveGoldSignals[i].tp2_hit = true;
            double pips = (ActiveGoldSignals[i].entry - ActiveGoldSignals[i].tp2) * 10;
            SendGoldTPHit("TP2", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].tp2, pips);
            Print("GOLD TP2 HIT: ", ActiveGoldSignals[i].tp2);
         }
         if(!ActiveGoldSignals[i].tp3_hit && currentPrice <= ActiveGoldSignals[i].tp3)
         {
            ActiveGoldSignals[i].tp3_hit = true;
            double pips = (ActiveGoldSignals[i].entry - ActiveGoldSignals[i].tp3) * 10;
            SendGoldTPHit("TP3", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].tp3, pips);
            Print("GOLD TP3 HIT: ", ActiveGoldSignals[i].tp3);
            
            ActiveGoldSignals[i].active = false;
         }
         
         
         if(!ActiveGoldSignals[i].sl_hit && currentPrice >= ActiveGoldSignals[i].sl)
         {
            ActiveGoldSignals[i].sl_hit = true;
            double pips = (ActiveGoldSignals[i].sl - ActiveGoldSignals[i].entry) * 10;
            SendGoldTPHit("SL", ActiveGoldSignals[i].entry, ActiveGoldSignals[i].sl, -pips);
            Print("GOLD SL HIT: ", ActiveGoldSignals[i].sl);
            
            ActiveGoldSignals[i].active = false;
         }
      }
      
      
      if(TimeCurrent() - ActiveGoldSignals[i].signal_time > 86400)
      {
         ActiveGoldSignals[i].active = false;
         Print("Gold signal expired (24h)");
      }
   }
}




void SendGoldTPHit(string result, double entry, double hitPrice, double pips)
{
   string url = ServerURL + "/gold_tp_hit";
   string headers = "Content-Type: application/json\r\n";
   
   
   double profit = pips * 0.10;
   
   string json = "{";
   json += "\"secret\":\"" + SecretKey + "\",";
   json += "\"result\":\"" + result + "\",";
   json += "\"entry\":" + DoubleToString(entry, 2) + ",";
   json += "\"hit_price\":" + DoubleToString(hitPrice, 2) + ",";
   json += "\"pips\":" + DoubleToString(pips, 1) + ",";
   json += "\"profit\":" + DoubleToString(profit, 2);
   json += "}";
   
   char post[], resultArr[];
   string resultHeaders;
   
   int len = StringLen(json);
   ArrayResize(post, len);
   for(int i = 0; i < len; i++)
      post[i] = (char)StringGetCharacter(json, i);
   
   int res = WebRequest("POST", url, headers, 5000, post, resultArr, resultHeaders);
   if(res == -1)
      Print("SendGoldTPHit Error: ", GetLastError());
   else
      Print("Gold ", result, " notification sent to Discord");
}




void SendGoldSignal(string direction, double entry, double sl, 
                    double tp1, double tp2, double tp3, double rsiValue)
{
   string url = ServerURL + "/gold_signal";
   string headers = "Content-Type: application/json\r\n";
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   string json = "{";
   json += "\"secret\":\"" + SecretKey + "\",";
   json += "\"direction\":\"" + direction + "\",";
   json += "\"entry\":" + DoubleToString(entry, 2) + ",";
   json += "\"sl\":" + DoubleToString(sl, 2) + ",";
   json += "\"tp1\":" + DoubleToString(tp1, 2) + ",";
   json += "\"tp2\":" + DoubleToString(tp2, 2) + ",";
   json += "\"tp3\":" + DoubleToString(tp3, 2) + ",";
   json += "\"rsi\":" + DoubleToString(rsiValue, 1) + ",";
   json += "\"balance\":" + DoubleToString(balance, 2) + ",";
   json += "\"equity\":" + DoubleToString(equity, 2);
   json += "}";
   
   char post[], result[];
   string resultHeaders;
   
   int len = StringLen(json);
   ArrayResize(post, len);
   for(int i = 0; i < len; i++)
      post[i] = (char)StringGetCharacter(json, i);
   
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res == -1)
      Print("SendGoldSignal Error: ", GetLastError());
   else
      Print("Gold signal sent to Discord");
}




void SendTradeUpdate(string action, string symbol, string message,
                     double price, double sl, double tp,
                     double lot, long ticket, double profit)
{
   string url = ServerURL + "/trade";
   string headers = "Content-Type: application/json\r\n";
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   
   StringReplace(message, "\\", "\\\\");
   StringReplace(message, "\"", "\\\"");
   StringReplace(message, "\r", "");
   StringReplace(message, "\n", "\\n");
   StringReplace(message, "\t", "\\t");
   
   string json = "{";
   json += "\"secret\":\"" + SecretKey + "\",";
   json += "\"action\":\"" + action + "\",";
   json += "\"symbol\":\"" + symbol + "\",";
   json += "\"message\":\"" + message + "\",";
   json += "\"price\":" + DoubleToString(price, 5) + ",";
   json += "\"sl\":" + DoubleToString(sl, 5) + ",";
   json += "\"tp\":" + DoubleToString(tp, 5) + ",";
   json += "\"lot\":" + DoubleToString(lot, 2) + ",";
   json += "\"ticket\":" + IntegerToString(ticket) + ",";
   json += "\"balance\":" + DoubleToString(balance, 2) + ",";
   json += "\"equity\":" + DoubleToString(equity, 2) + ",";
   json += "\"margin\":" + DoubleToString(margin, 2) + ",";
   json += "\"free_margin\":" + DoubleToString(freeMargin, 2) + ",";
   json += "\"profit\":" + DoubleToString(profit, 2) + ",";
   json += "\"open_trades_count\":" + IntegerToString(PositionsTotal()) + ",";
   json += "\"trading_enabled\":" + (TradingEnabled ? "true" : "false") + ",";
   json += "\"time\":\"" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\"";
   json += "}";
   
   char post[], result[];
   string resultHeaders;
   
   
   int len = StringLen(json);
   ArrayResize(post, len);
   for(int i = 0; i < len; i++)
      post[i] = (char)StringGetCharacter(json, i);
   
   int res = WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
   if(res == -1)
   {
      int err = GetLastError();
      Print("SendTradeUpdate Error: ", err, " (4014 = WebRequest URL not whitelisted in MT5 Options)");
   }
}




void SendStatusUpdate()
{
   string url = ServerURL + "/status";
   string headers = "Content-Type: application/json\r\n";
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   
   
   string tradesJson = "[";
   int count = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         {
            if(count > 0) tradesJson += ",";
            tradesJson += "{";
            tradesJson += "\"ticket\":" + IntegerToString((long)ticket) + ",";
            tradesJson += "\"symbol\":\"" + PositionGetString(POSITION_SYMBOL) + "\",";
            tradesJson += "\"type\":\"" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL") + "\",";
            tradesJson += "\"lot\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + ",";
            tradesJson += "\"profit\":" + DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + ",";
            tradesJson += "\"price\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 5);
            tradesJson += "}";
            count++;
         }
      }
   }
   tradesJson += "]";
   
   string json = "{";
   json += "\"secret\":\"" + SecretKey + "\",";
   json += "\"balance\":" + DoubleToString(balance, 2) + ",";
   json += "\"equity\":" + DoubleToString(equity, 2) + ",";
   json += "\"margin\":" + DoubleToString(margin, 2) + ",";
   json += "\"free_margin\":" + DoubleToString(freeMargin, 2) + ",";
   json += "\"open_trades_count\":" + IntegerToString(count) + ",";
   json += "\"trading_enabled\":" + (TradingEnabled ? "true" : "false") + ",";
   json += "\"trades\":" + tradesJson;
   json += "}";
   
   char post[], result[];
   string resultHeaders;
   
   
   int len = StringLen(json);
   ArrayResize(post, len);
   for(int i = 0; i < len; i++)
      post[i] = (char)StringGetCharacter(json, i);
   
   WebRequest("POST", url, headers, 5000, post, result, resultHeaders);
}

