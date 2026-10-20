//+------------------------------------------------------------------+
//|                      AbdeeFX_EA.mq5                              |
//|             Risk-Managed MT5 Expert Advisor                      |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

// STRATEGY SETTINGS
input ENUM_TIMEFRAMES Timeframe = PERIOD_M15;
input int FastEMA = 20;
input int SlowEMA = 50;
input int RSIPeriod = 14;
input double BuyRSI = 52.0;
input double SellRSI = 48.0;
input int ATRPeriod = 14;
input double ATRMultiplier = 1.8;
input double RiskReward = 1.5;

// RISK MANAGEMENT
input double RiskPercent = 0.25;
input double MaxDailyLossPercent = 2.0;
input double MaxOverallDrawdownPercent = 5.0;
input double DailyProfitStopPercent = 2.0;
input int MaxTradesPerDay = 3;
input int MaxOpenPositions = 1;
input int MaxSpreadPoints = 80;
input ulong MagicNumber = 20261020;

// SAFETY SETTINGS
input bool ManualNewsBlock = false;
input bool UseTradingHours = false;
input int StartHour = 7;
input int EndHour = 20;

int fastHandle, slowHandle, rsiHandle, atrHandle;
datetime lastBar = 0;
int currentDay = -1;
double dayStartEquity = 0;
double startingBalance = 0;
bool tradingStopped = false;

int GetDayKey()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.year*10000 + t.mon*100 + t.day;
}

void ResetDaily()
{
   int today = GetDayKey();
   if(today != currentDay)
   {
      currentDay = today;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingStopped = false;
   }
}

bool NewBar()
{
   datetime t = iTime(_Symbol, Timeframe, 0);
   if(t == 0 || t == lastBar)
      return false;
   lastBar = t;
   return true;
}

bool CanTrade()
{
   ResetDaily();

   if(ManualNewsBlock)
      return false;

   if(UseTradingHours)
   {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      if(StartHour < EndHour && (t.hour < StartHour || t.hour >= EndHour))
         return false;
      if(StartHour > EndHour && (t.hour < StartHour && t.hour >= EndHour))
         return false;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(dayStartEquity > 0)
   {
      double dailyLoss   = (dayStartEquity - equity) / dayStartEquity * 100.0;
      double dailyProfit = (equity - dayStartEquity) / dayStartEquity * 100.0;

      if(dailyLoss >= MaxDailyLossPercent)
         tradingStopped = true;
      if(DailyProfitStopPercent > 0 && dailyProfit >= DailyProfitStopPercent)
         tradingStopped = true;
   }

   if(startingBalance > 0 &&
      equity <= startingBalance * (1.0 - MaxOverallDrawdownPercent/100.0))
      tradingStopped = true;

   if(tradingStopped)
      return false;

   if((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints)
      return false;

   return true;
}

int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            count++;
      }
   }
   return count;
}

int CountEntriesToday()
{
   datetime start = iTime(_Symbol, PERIOD_D1, 0);
   if(start <= 0)
      start = TimeCurrent() - 86400;

   if(!HistorySelect(start, TimeCurrent()))
      return 0;

   int count = 0;
   for(int i = HistoryDealsTotal()-1; i >= 0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

bool ReadIndicator(int handle, int shift, double &value)
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return false;
   value = buffer[0];
   return true;
}

double CalculateLot(ENUM_ORDER_TYPE type, double entry, double stopLoss)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0;
   double profit = 0;

   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, stopLoss, profit))
      return 0;

   double lossPerLot = MathAbs(profit);
   if(lossPerLot <= 0)
      return 0;

   double rawLot = riskMoney / lossPerLot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0 || rawLot < minLot)
      return 0;

   double lots = MathFloor(rawLot / step) * step;
   lots = MathMin(lots, maxLot);

   double margin = 0;
   if(!OrderCalcMargin(type, _Symbol, lots, entry, margin))
      return 0;
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
      return 0;

   return NormalizeDouble(lots, 8);
}

void CheckEntry()
{
   if(!CanTrade()) return;
   if(CountPositions() >= MaxOpenPositions) return;
   if(CountEntriesToday() >= MaxTradesPerDay) return;

   double fast, slow, rsi, atr;
   if(!ReadIndicator(fastHandle, 1, fast)) return;
   if(!ReadIndicator(slowHandle, 1, slow)) return;
   if(!ReadIndicator(rsiHandle, 1, rsi)) return;
   if(!ReadIndicator(atrHandle, 1, atr)) return;
   if(atr <= 0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minimumStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double distance = MathMax(atr * ATRMultiplier, minimumStop + 2*_Point);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(fast > slow && rsi >= BuyRSI)
   {
      double entry = tick.ask;
      double sl = NormalizeDouble(entry - distance, digits);
      double tp = NormalizeDouble(entry + distance * RiskReward, digits);
      double lot = CalculateLot(ORDER_TYPE_BUY, entry, sl);
      if(lot > 0)
         trade.Buy(lot, _Symbol, 0, sl, tp, "AbdeeFX BUY");
   }
   else if(fast < slow && rsi <= SellRSI)
   {
      double entry = tick.bid;
      double sl = NormalizeDouble(entry + distance, digits);
      double tp = NormalizeDouble(entry - distance * RiskReward, digits);
      double lot = CalculateLot(ORDER_TYPE_SELL, entry, sl);
      if(lot > 0)
         trade.Sell(lot, _Symbol, 0, sl, tp, "AbdeeFX SELL");
   }
}

int OnInit()
{
   startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   currentDay = GetDayKey();
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   fastHandle = iMA(_Symbol, Timeframe, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, Timeframe, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle  = iRSI(_Symbol, Timeframe, RSIPeriod, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, Timeframe, ATRPeriod);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
      return INIT_FAILED;

   Print("AbdeeFX EA initialized. Test on demo first.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE) IndicatorRelease(fastHandle);
   if(slowHandle != INVALID_HANDLE) IndicatorRelease(slowHandle);
   if(rsiHandle  != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle  != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

void OnTick()
{
   ResetDaily();
   if(!NewBar())
      return;
   CheckEntry();
}
//+------------------------------------------------------------------+
