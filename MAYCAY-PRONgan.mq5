//+------------------------------------------------------------------+
//| Hedge Grid EA                                                    |
//| Logic:                                                           |
//| - Không dùng trend                                               |
//| - Không còn BUY -> vào BUY mới                                   |
//| - Không còn SELL -> vào SELL mới                                 |
//| - Giá cách lệnh gần nhất X pip -> nhồi thêm cùng chiều           |
//| - Mỗi lần chỉ mở tối đa 1 lệnh                                   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;
CTrade closeTrade;


// ===== INPUT =====
input bool   AutoTrade = true; // bật/tắt bot

input bool   EnableTradeTime = false; // bật/tắt tự động dừng/mở bot theo giờ Nhật

input int    StopHour_JST = 5; // giờ Nhật để tắt bot
input int    StopMinute_JST = 30; // phút tắt bot

input int    StartHour_JST = 8; // giờ Nhật để mở lại bot
input int    StartMinute_JST = 0; // phút mở lại bot

input bool   CloseAllAtStopTime = true; // đến giờ tắt thì đóng toàn bộ lệnh

input bool   EnableBuy = true; // cho phép mở lệnh BUY
input bool   EnableSell = true; // cho phép mở lệnh SELL

input double Lot = 0.01; // lot lệnh đầu tiên

enum LotMode
{
   FIX_LOT = 0,
   MULTIPLY_LOT = 1,
   ADD_LOT = 2
};

input LotMode AddLotMode = MULTIPLY_LOT; // kiểu tăng lot: cố định / nhân lot / cộng lot

input double LotMultiplier = 2.0; // hệ số nhân lot khi chọn MULTIPLY_LOT
input double LotAddStep = 0.01; // số lot cộng thêm khi chọn ADD_LOT

input double TrailStart_Gia = 3; // lời bao nhiêu giá thì bắt đầu dời SL
input double TrailLock_Gia = 1; // khi bắt đầu trailing thì khóa lời bao nhiêu giá

input double TrailStep_Gia = 0.5; // giá chạy thêm bao nhiêu giá thì dời SL tiếp
input double TrailStepLock_Gia = 0.5; // mỗi lần dời thêm thì khóa thêm bao nhiêu giá

input double AddStep_Gia = 3; // giá đi ngược bao nhiêu giá thì nhồi thêm lệnh
input bool EnableAIRiskControl = true; // bật/tắt AI quản lý rủi ro theo khoảng cách từ lệnh đầu tiên

input double AI_FirstMoveLevel1_Gia = 20; // giá đi ngược từ lệnh đầu tiên mức 1
input double AI_FirstMoveLevel2_Gia = 30; // giá đi ngược từ lệnh đầu tiên mức 2
input double AI_FirstMoveLevel3_Gia = 60; // giá đi ngược từ lệnh đầu tiên mức 3

input double AI_GridLevel1_Gia = 4; // grid khi đi ngược mức 1
input double AI_GridLevel2_Gia = 6; // grid khi đi ngược mức 2
input double AI_GridLevel3_Gia = 8; // grid khi đi ngược mức 3

input double AI_MultiplierLevel1 = 1.8; // multiplier mức 1
input double AI_MultiplierLevel2 = 1.6; // multiplier mức 2
input double AI_MultiplierLevel3 = 1.5; // multiplier mức 3


input int    MaxBuyPositions = 12; // số lệnh BUY tối đa
input int    MaxSellPositions = 12; // số lệnh SELL tối đa

input bool   EnableMaxLossClose = true; // bật/tắt cắt lỗ tổng
input double MaxLossClose_USD = 30000.0; // âm bao nhiêu USD thì đóng toàn bộ lệnh
input bool   StopEA_AfterMaxLoss = true; // sau khi cắt lỗ tổng thì dừng bot
input bool   EnableTotalProfitStepClose = true; // bật/tắt clear lệnh theo profit tổng từng mốc
input double TotalProfitStep_USD = 100.0; // cứ lãi thêm bao nhiêu USD thì clear toàn bộ

input int    AddCooldownSeconds = 3; // thời gian chờ tối thiểu giữa 2 lần vào lệnh
input double MaxSpread_Gia = 0.4; // spread tối đa cho phép vào lệnh, tính theo giá

input int    MagicNumber = 20260506; // mã magic để bot nhận diện lệnh của mình


// ===== TELEGRAM =====
input string BotToken = ""; // nhập trong Inputs, không commit token thật
input string ChatID = ""; // nhập trong Inputs, không commit chat id thật

bool   EnableDailyReport = true;
int    DailyReportHour_JST = 6;
int    DailyReportMinute_JST = 0;

bool   EnableWeeklyReport = true;
int    WeeklyReportDay_JST = 6;
int    WeeklyReportHour_JST = 6;
int    WeeklyReportMinute_JST = 0;

double CommissionPercent = 30.0;

// ===== GLOBAL =====
// ===== FAST CLOSE SETTINGS =====
input ulong CloseDeviationPoints = 100; // độ lệch tối đa khi đóng
input int   CloseRetrySeconds    = 1;   // thời gian retry nếu còn lệnh

bool     CloseInProgress       = false;
bool     CloseStopEA           = false;
string   CloseReason           = "";
double   CloseTriggerProfit    = 0;

datetime CloseHistoryFrom        = 0;
ulong LastCloseRequestMilliseconds = 0;
ulong    CloseStartMilliseconds  = 0;
ulong    CloseNoPositionMilliseconds = 0;
struct ClosePositionItem
{
   ulong  ticket;
   double volume;
};
double pip;

datetime lastOrderTime = 0;
datetime lastBarTime   = 0;
datetime lastTradeExecution = 0;

bool EmergencyStop = false;
bool tradeTimeStopped = false;
int lastTradeTimeDay = -1;
datetime totalProfitSessionStart = 0;
int totalProfitStepCount = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   pip = (_Digits == 3 || _Digits == 5)
      ? _Point * 10
      : _Point;
      

   trade.SetExpertMagicNumber(MagicNumber);
trade.SetTypeFillingBySymbol(_Symbol);

closeTrade.SetExpertMagicNumber(MagicNumber);
closeTrade.SetDeviationInPoints(CloseDeviationPoints);
closeTrade.SetTypeFillingBySymbol(_Symbol);
closeTrade.SetAsyncMode(true);
   

   EmergencyStop = false;
   totalProfitSessionStart = TimeCurrent();
   totalProfitStepCount = 0;

SendTelegram("Báo cáo các Sếp EA MAYCAY đã được gắn thành công");
EventSetTimer(1);
return INIT_SUCCEEDED;


}

//+------------------------------------------------------------------+
void OnTick()
{
   // Ưu tiên tuyệt đối cho quá trình đóng
   if(ProcessCloseAllPositions())
      return;

   CheckTradeTime();

   if(ProcessCloseAllPositions())
      return;

   if(tradeTimeStopped)
      return;

   if(CheckMaxLossClose())
      return;

   if(ProcessCloseAllPositions())
      return;

   if(CheckTotalProfitStepClose())
      return;

   if(ProcessCloseAllPositions())
      return;

   ManageTrailingStop();

   CheckAddPosition();

   // Báo cáo để cuối cùng, không cản quá trình đóng
   CheckDailyReport();
   CheckWeeklyReport();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   // Khi đang đóng thì không chạy Telegram hoặc việc khác
   if(ProcessCloseAllPositions())
      return;

   CheckDailyReport();
   CheckWeeklyReport();
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}
//+------------------------------------------------------------------+
void CheckTradeTime()
{
   if(!EnableTradeTime)
      return;

   MqlDateTime jst;
   TimeToStruct(TimeGMT() + 9 * 3600, jst);

   int nowMinutes =
      jst.hour * 60 + jst.min;

   int stopMinutes =
      StopHour_JST * 60 + StopMinute_JST;

   int startMinutes =
      StartHour_JST * 60 + StartMinute_JST;

   // reset mỗi ngày
   if(lastTradeTimeDay != jst.day_of_year)
   {
      lastTradeTimeDay = jst.day_of_year;
   }

   bool shouldStop = false;

   // Trường hợp thường: tắt 5:00, mở 9:00
   if(stopMinutes < startMinutes)
   {
      if(nowMinutes >= stopMinutes && nowMinutes < startMinutes)
         shouldStop = true;
   }
   // Trường hợp qua ngày: tắt 22:00, mở 6:00
   else
   {
      if(nowMinutes >= stopMinutes || nowMinutes < startMinutes)
         shouldStop = true;
   }

   if(shouldStop)
   {
      if(!tradeTimeStopped)
      {
         Print("TRADE TIME STOP");

         

         if(CloseAllAtStopTime && HasAnyPosition())
{
   StartCloseAllPositions(
      "TRADE TIME STOP CLOSED",
      false,
      GetTotalProfit()
   );
}

         tradeTimeStopped = true;
      }

      return;
   }

   if(tradeTimeStopped)
   {
      Print("TRADE TIME START");

      

      tradeTimeStopped = false;
      EmergencyStop = false;
   }
}

//+------------------------------------------------------------------+
bool CheckMaxLossClose()
{
   if(!EnableMaxLossClose)
      return false;

   if(!HasAnyPosition())
      return false;

   if(MaxLossClose_USD <= 0)
      return false;

   double totalProfit = GetTotalProfit();

   if(totalProfit <= -MaxLossClose_USD)
   {
      Print("MAX LOSS HIT: ", totalProfit);

StartCloseAllPositions(
   "MAX LOSS CLOSED",
   StopEA_AfterMaxLoss,
   totalProfit
);

return true;
   }

   return false;
}

bool CheckTotalProfitStepClose()
{
   if(!EnableTotalProfitStepClose)
      return false;

   if(TotalProfitStep_USD <= 0)
      return false;

   if(!HasAnyPosition())
      return false;

   if(totalProfitSessionStart <= 0)
      totalProfitSessionStart = TimeCurrent();

   double closedProfit =
      GetClosedProfit(totalProfitSessionStart, TimeCurrent());

   double floatingProfit =
      GetTotalProfit();

   double totalProfit =
      closedProfit + floatingProfit;

   double nextTarget =
      TotalProfitStep_USD * (totalProfitStepCount + 1);

   if(totalProfit < nextTarget)
      return false;

   int reachedStep =
      (int)MathFloor(totalProfit / TotalProfitStep_USD);

   if(reachedStep <= totalProfitStepCount)
      reachedStep = totalProfitStepCount + 1;

   totalProfitStepCount = reachedStep;

   Print(
      "TOTAL PROFIT STEP HIT. Step=",
      totalProfitStepCount,
      " Target=",
      nextTarget,
      " Closed=",
      closedProfit,
      " Floating=",
      floatingProfit,
      " Total=",
      totalProfit
   );

   StartCloseAllPositions(
      "TOTAL PROFIT STEP "
      + IntegerToString(totalProfitStepCount)
      + " CLOSED",
      false,
      totalProfit
   );

   return true;
}
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double stopLevel =
      SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
      {
         double profitGia = bid - openPrice;

         if(profitGia >= TrailStart_Gia)
         {
            double extraGia = profitGia - TrailStart_Gia;

            int stepCount = 0;

            if(TrailStep_Gia > 0)
               stepCount = (int)MathFloor(extraGia / TrailStep_Gia);

            double lockGia =
               TrailLock_Gia + (stepCount * TrailStepLock_Gia);

            double newSL =
               NormalizeDouble(openPrice + lockGia, _Digits);

            if((bid - newSL) >= (stopLevel + (2 * _Point)))
            {
               if(currentSL == 0 ||
                  NormalizeDouble(newSL, _Digits) >
                  NormalizeDouble(currentSL, _Digits))
               {
                  if(!trade.PositionModify(ticket, newSL, currentTP))
                  {
                     Print("BUY TRAIL FAILED: ",
                        trade.ResultRetcode(),
                        " / ",
                        trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }

      if(type == POSITION_TYPE_SELL)
      {
         double profitGia = openPrice - ask;

         if(profitGia >= TrailStart_Gia)
         {
            double extraGia = profitGia - TrailStart_Gia;

            int stepCount = 0;

            if(TrailStep_Gia > 0)
               stepCount = (int)MathFloor(extraGia / TrailStep_Gia);

            double lockGia =
               TrailLock_Gia + (stepCount * TrailStepLock_Gia);

            double newSL =
               NormalizeDouble(openPrice - lockGia, _Digits);

            if((newSL - ask) >= (stopLevel + (2 * _Point)))
            {
               if(currentSL == 0 ||
                  NormalizeDouble(newSL, _Digits) <
                  NormalizeDouble(currentSL, _Digits))
               {
                  if(!trade.PositionModify(ticket, newSL, currentTP))
                  {
                     Print("SELL TRAIL FAILED: ",
                        trade.ResultRetcode(),
                        " / ",
                        trade.ResultRetcodeDescription());
                  }
               }
            }
         }
      }
   }
}

      

//+------------------------------------------------------------------+
void CheckAddPosition()
{
   if(CloseInProgress)
      return;

   if(!AutoTrade)
      return;

   if(EmergencyStop)
      return;

   if(TimeCurrent() == lastTradeExecution)
      return;

   // ===== spread filter =====
   if(!IsSpreadOK())
      return;

   // ===== chỉ 1 lệnh mỗi nến M1 =====
   datetime currentBar =
      iTime(_Symbol, PERIOD_M1, 0);

   bool canOpenNewBar =
      (currentBar != lastBarTime);

   double bid =
      SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double ask =
      SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
   // int aiScore = GetAIRiskScore();

// Print("AI RISK => Score=", aiScore,
//       " Grid=", dynamicAddStep,
//       " Multiplier=", GetAIDynamicMultiplier());

   // =====================================================
   // CHƯA CÓ LỆNH -> BUY + SELL CÙNG LÚC
   // =====================================================

   if(!HasAnyPosition())
   {
      bool opened = false;

      if(EnableBuy)
      {
         if(OpenBuy("🕷SpiderX🕷️"))
            opened = true;
      }

      if(EnableSell)
      {
         if(OpenSell("🕷SpiderX🕷"))
            opened = true;
      }

      if(opened)
      {
         lastBarTime = currentBar;
      }

      return;
   }

   // =====================================================
   // BUY
   // =====================================================

   if(EnableBuy)
   {
      int buyCount = CountBuyPositions();

      // ===== KHÔNG CÒN BUY =====
      if(buyCount == 0)
      {
         if(canOpenNewBar &&
            CooldownPassed() &&
            OpenBuy("🕷SpiderX🕷"))
         {
            lastBarTime = currentBar;
            return;
         }
      }
      else
      {
         double lastBuyPrice =
            GetLastPositionPrice(POSITION_TYPE_BUY);
            double dynamicAddStep =
   GetDynamicAddStepGia(POSITION_TYPE_BUY);

         if(lastBuyPrice > 0)
         {
            double distance =
   NormalizeDouble(lastBuyPrice - bid, _Digits);

            if(distance >= dynamicAddStep)
            {
               if(buyCount < MaxBuyPositions)
               {
                  double lastLot =
                     GetLastPositionLot(POSITION_TYPE_BUY);

                  double nextLot = Lot;

                  switch(AddLotMode)
                  {
                     case FIX_LOT:
                        nextLot = Lot;
                        break;

                     case MULTIPLY_LOT:
   nextLot = lastLot * GetAIDynamicMultiplier(POSITION_TYPE_BUY);
   break;
                     case ADD_LOT:
                        nextLot = lastLot + LotAddStep;
                        break;
                  }

                  nextLot =
                     NormalizeDouble(nextLot, 2);

                  if(canOpenNewBar &&
                     CooldownPassed() &&
                     OpenBuy("🕷SpiderX🕷", nextLot))
                  {
                     lastBarTime = currentBar;
                     return;
                  }
               }
            }
         }
      }
   }

   // =====================================================
   // SELL
   // =====================================================

   if(EnableSell)
   {
      int sellCount = CountSellPositions();

      // ===== KHÔNG CÒN SELL =====
      if(sellCount == 0)
      {
         if(canOpenNewBar &&
            CooldownPassed() &&
            OpenSell("🕷SpiderX🕷"))
         {
            lastBarTime = currentBar;
            return;
         }
      }
      else
      {
         double lastSellPrice =
            GetLastPositionPrice(POSITION_TYPE_SELL);
            double dynamicAddStep =
   GetDynamicAddStepGia(POSITION_TYPE_SELL);

         if(lastSellPrice > 0)
         {
            double distance =
   NormalizeDouble(ask - lastSellPrice, _Digits);

            if(distance >= dynamicAddStep)
            {
               if(sellCount < MaxSellPositions)
               {
                  double lastLot =
                     GetLastPositionLot(POSITION_TYPE_SELL);

                  double nextLot = Lot;

                  switch(AddLotMode)
                  {
                     case FIX_LOT:
                        nextLot = Lot;
                        break;

                     case MULTIPLY_LOT:
   nextLot = lastLot * GetAIDynamicMultiplier(POSITION_TYPE_SELL);
   break;
                     case ADD_LOT:
                        nextLot = lastLot + LotAddStep;
                        break;
                  }

                  nextLot =
                     NormalizeDouble(nextLot, 2);

                  if(canOpenNewBar &&
                     CooldownPassed() &&
                     OpenSell("🕷SpiderX🕷", nextLot))
                  {
                     lastBarTime = currentBar;
                     return;
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
bool OpenBuy(string reason, double customLot = -1)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double finalLot =
   (customLot > 0)
   ? customLot
   : Lot;

   double sl = 0;
   double tp = 0;

double stopLevel =
   SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

if(sl > 0 && (price - sl) < stopLevel)
   sl = 0;

if(tp > 0 && (tp - price) < stopLevel)
   tp = 0;
   Print("BUY DEBUG => price=", price,
      " sl=", sl,
      " tp=", tp,
      " stopLevel=", stopLevel,
      " pip=", pip,
      " digits=", _Digits);

   bool result = trade.Buy(finalLot, _Symbol, price, sl, tp, reason);

   if(result)
   {
      lastOrderTime = TimeCurrent();
      lastTradeExecution = TimeCurrent();

      // SendTelegram(
//    "BUY OPEN\n" +
//    "Symbol: " + _Symbol + "\n" +
//    "Price: " + DoubleToString(price, _Digits) + "\n" +
//    "Reason: " + reason
// );

      Print("BUY OPEN: ", reason);
   }
   else
   {
      Print("BUY FAILED: ",
            trade.ResultRetcode(),
            " / ",
            trade.ResultRetcodeDescription());
   }

   return result;
}

//+------------------------------------------------------------------+
bool OpenSell(string reason, double customLot = -1)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double finalLot =
   (customLot > 0)
   ? customLot
   : Lot;

   double sl = 0;
   double tp = 0;

double stopLevel =
   SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

if(sl > 0 && (sl - price) < stopLevel)
   sl = 0;

if(tp > 0 && (price - tp) < stopLevel)
   tp = 0;

   Print("SELL DEBUG => price=", price,
      " sl=", sl,
      " tp=", tp,
      " stopLevel=", stopLevel,
      " pip=", pip,
      " digits=", _Digits);
   bool result = trade.Sell(finalLot, _Symbol, price, sl, tp, reason);

   if(result)
   {
      lastOrderTime = TimeCurrent();
      lastTradeExecution = TimeCurrent();

      // SendTelegram(
//    "SELL OPEN\n" +
//    "Symbol: " + _Symbol + "\n" +
//    "Price: " + DoubleToString(price, _Digits) + "\n" +
//    "Reason: " + reason
// );

      Print("SELL OPEN: ", reason);
   }
   else
   {
      Print("SELL FAILED: ",
            trade.ResultRetcode(),
            " / ",
            trade.ResultRetcodeDescription());
   }

   return result;
}

//+------------------------------------------------------------------+
int CountBuyPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
int CountSellPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         count++;
   }

   return count;
}

bool HasAnyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      return true;
   }

   return false;
}
//+------------------------------------------------------------------+
//| Đếm số position của EA trên symbol hiện tại                      |
//+------------------------------------------------------------------+
int CountBotPositions()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      count++;
   }

   return count;
}

//+------------------------------------------------------------------+
double GetTotalProfit()
{
   double totalProfit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      totalProfit +=
         PositionGetDouble(POSITION_PROFIT);
   }

   return totalProfit;
}
//+------------------------------------------------------------------+
double GetLastPositionPrice(long type)
{
   double lastPrice = 0;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      datetime openTime =
         (datetime)PositionGetInteger(POSITION_TIME);

      if(openTime > lastTime)
      {
         lastTime  = openTime;
         lastPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return lastPrice;
}

double GetLastPositionLot(long type)
{
   double lastLot = Lot;
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      datetime openTime =
         (datetime)PositionGetInteger(POSITION_TIME);

      if(openTime > lastTime)
      {
         lastTime = openTime;

         lastLot =
            PositionGetDouble(POSITION_VOLUME);
      }
   }

   return lastLot;
}
double GetFirstPositionPrice(long type)
{
   double firstPrice = 0;
   datetime firstTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(PositionGetInteger(POSITION_TYPE) != type)
         continue;

      datetime openTime =
         (datetime)PositionGetInteger(POSITION_TIME);

      if(firstTime == 0 || openTime < firstTime)
      {
         firstTime = openTime;
         firstPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }

   return firstPrice;
}
double GetFirstMoveGia(long type)
{
   double firstPrice = GetFirstPositionPrice(type);

   if(firstPrice <= 0)
      return 0;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(type == POSITION_TYPE_BUY)
      return NormalizeDouble(firstPrice - bid, _Digits);

   if(type == POSITION_TYPE_SELL)
      return NormalizeDouble(ask - firstPrice, _Digits);

   return 0;
}



double GetDynamicAddStepGia(long type)
{
   double step = AddStep_Gia;

   if(!EnableAIRiskControl)
      return step;

   double firstMove = GetFirstMoveGia(type);

   if(firstMove >= AI_FirstMoveLevel3_Gia)
      step = MathMax(step, AI_GridLevel3_Gia);
   else if(firstMove >= AI_FirstMoveLevel2_Gia)
      step = MathMax(step, AI_GridLevel2_Gia);
   else if(firstMove >= AI_FirstMoveLevel1_Gia)
      step = MathMax(step, AI_GridLevel1_Gia);

   return step;
}



   
double GetAIDynamicMultiplier(long type)
{
   if(!EnableAIRiskControl)
      return LotMultiplier;

   double firstMove = GetFirstMoveGia(type);

   if(firstMove >= AI_FirstMoveLevel3_Gia)
      return AI_MultiplierLevel3;

   if(firstMove >= AI_FirstMoveLevel2_Gia)
      return AI_MultiplierLevel2;

   if(firstMove >= AI_FirstMoveLevel1_Gia)
      return AI_MultiplierLevel1;

   return LotMultiplier;
}

//+------------------------------------------------------------------+
bool IsSpreadOK()
{
   double spread =
      SymbolInfoDouble(_Symbol, SYMBOL_ASK)
      - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   return spread <= MaxSpread_Gia;
}

bool CooldownPassed()

{
   return (TimeCurrent() - lastOrderTime >= AddCooldownSeconds);
}

//+------------------------------------------------------------------+
//| Gửi hàng loạt yêu cầu đóng, ưu tiên lệnh lot lớn trước           |
//+------------------------------------------------------------------+
//| Gửi nhanh hàng loạt yêu cầu đóng                                |
//+------------------------------------------------------------------+
int FastCloseAllPositions()
{
   ClosePositionItem positions[];
   int count = 0;

   // Chụp danh sách ticket trước khi gửi yêu cầu đóng
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      ArrayResize(positions, count + 1);

      positions[count].ticket = ticket;
      positions[count].volume =
         PositionGetDouble(POSITION_VOLUME);

      count++;
   }

   if(count == 0)
      return 0;

   // Lot lớn được gửi yêu cầu đóng trước
   for(int i = 0; i < count - 1; i++)
   {
      for(int j = i + 1; j < count; j++)
      {
         if(positions[j].volume > positions[i].volume)
         {
            ClosePositionItem temp = positions[i];
            positions[i] = positions[j];
            positions[j] = temp;
         }
      }
   }

   int requestSent = 0;

   for(int i = 0; i < count; i++)
   {
      ResetLastError();

      bool sent =
         closeTrade.PositionClose(
            positions[i].ticket,
            CloseDeviationPoints
         );

      if(sent)
      {
         requestSent++;
      }
      else
      {
         Print(
            "FAST CLOSE REQUEST FAILED"
            " | Ticket=", positions[i].ticket,
            " | Error=", GetLastError(),
            " | Retcode=", closeTrade.ResultRetcode(),
            " | Description=",
            closeTrade.ResultRetcodeDescription()
         );
      }
   }

   LastCloseRequestMilliseconds =
   GetTickCount64();

   Print(
   "FAST CLOSE ASYNC REQUESTS SENT: ",
   requestSent,
   "/",
   count,
   " | Remaining positions: ",
   CountBotPositions()
);

   return requestSent;
}

//+------------------------------------------------------------------+
//| Bắt đầu quá trình đóng toàn bộ lệnh                               |
//+------------------------------------------------------------------+
void StartCloseAllPositions(
   string reason,
   bool stopEA,
   double triggerProfit
)
{
   if(CloseInProgress)
      return;

   CloseInProgress = true;
   CloseStopEA = stopEA;
   CloseReason = reason;

   CloseTriggerProfit = triggerProfit;

   CloseHistoryFrom = TimeCurrent();
   CloseStartMilliseconds = GetTickCount64();
   CloseNoPositionMilliseconds = 0;
   LastCloseRequestMilliseconds = 0;

   // Gửi yêu cầu đóng ngay, chưa Telegram
   FastCloseAllPositions();
}

//+------------------------------------------------------------------+
//| Theo dõi cho đến khi đóng hết position                           |
//+------------------------------------------------------------------+
bool ProcessCloseAllPositions()
{
   if(!CloseInProgress)
      return false;

   // =====================================================
   // VẪN CÒN POSITION
   // =====================================================
   if(HasAnyPosition())
   {
      CloseNoPositionMilliseconds = 0;

      ulong retryMilliseconds =
         (ulong)MathMax(1, CloseRetrySeconds) * 1000;

      if(
         LastCloseRequestMilliseconds == 0 ||
         GetTickCount64() - LastCloseRequestMilliseconds
            >= retryMilliseconds
      )
      {
         FastCloseAllPositions();
      }

      return true;
   }

   // =====================================================
   // KHÔNG CÒN POSITION
   // Chờ lịch sử deal được cập nhật
   // =====================================================
   if(CloseNoPositionMilliseconds == 0)
   {
      CloseNoPositionMilliseconds = GetTickCount64();
      return true;
   }

   if(
      GetTickCount64() - CloseNoPositionMilliseconds
      < 500
   )
   {
      return true;
   }

   ulong durationMs =
      GetTickCount64() - CloseStartMilliseconds;

   double realizedProfit =
      GetClosedProfit(
         CloseHistoryFrom,
         TimeCurrent() + 2
      );

   long accountID =
   AccountInfoInteger(ACCOUNT_LOGIN);

string accountName =
   AccountInfoString(ACCOUNT_NAME);

string accountServer =
   AccountInfoString(ACCOUNT_SERVER);

string message =
   CloseReason + "\n"
   + "Tài khoản: "
   + IntegerToString(accountID)
   + "\n"
   + "Tên: "
   + accountName
   + "\n"
   + "Server: "
   + accountServer
   + "\n"
   + "Symbol: "
   + _Symbol
   + "\n\n"
   + "Profit khi kích hoạt: "
   + DoubleToString(CloseTriggerProfit, 2)
   + " USD\n";
   

   message +=
      "Lãi/lỗ thực tế sau khi đóng: "
      + DoubleToString(realizedProfit, 2)
      + " USD\n"
      + "Thời gian đóng: "
      + DoubleToString(
         (double)durationMs / 1000.0,
         3
      )
      + " giây";

   Print(message);

   if(CloseStopEA)
   {
      EmergencyStop = true;
   }
   else
   {
      EmergencyStop = false;

      // Không mở lại lệnh ngay trong cùng thời điểm
      lastBarTime =
         iTime(_Symbol, PERIOD_M1, 0);

      lastTradeExecution =
         TimeCurrent();

      lastOrderTime =
         TimeCurrent();
   }

   string finalMessage = message;

   // Reset toàn bộ trạng thái đóng
   CloseInProgress = false;
   CloseStopEA = false;
   CloseReason = "";

   CloseTriggerProfit = 0;

   CloseHistoryFrom = 0;
   LastCloseRequestMilliseconds = 0;
   CloseStartMilliseconds = 0;
   CloseNoPositionMilliseconds = 0;

   // Chỉ Telegram sau khi chắc chắn đã đóng xong
   SendTelegram(finalMessage);

   return true;
}

datetime GetJSTDateTime(int hour, int minute, int dayOffset)
{
   datetime gmtNow = TimeGMT();
   datetime jstNow = gmtNow + 9 * 3600;

   MqlDateTime dt;
   TimeToStruct(jstNow, dt);

   dt.hour = hour;
   dt.min  = minute;
   dt.sec  = 0;

   datetime targetJST = StructToTime(dt);
   targetJST += dayOffset * 86400;

   datetime targetGMT =
      targetJST - 9 * 3600;

   int serverOffset =
      (int)(TimeTradeServer() - TimeGMT());

   return targetGMT + serverOffset;
}
datetime ServerTimeToJST(datetime serverTime)
{
   int serverOffset =
      (int)(TimeTradeServer() - TimeGMT());

   datetime gmtTime =
      serverTime - serverOffset;

   return gmtTime + 9 * 3600;
}
datetime GetBotSessionStart()
{
   datetime nowJST =
      TimeGMT() + 9 * 3600;

   MqlDateTime dt;
   TimeToStruct(nowJST, dt);

   int nowMinutes =
      dt.hour * 60 + dt.min;

   int sessionStartMinutes =
      StartHour_JST * 60
      + StartMinute_JST;

   int sessionEndMinutes =
      StopHour_JST * 60
      + StopMinute_JST;

   if(sessionEndMinutes < sessionStartMinutes)
   {
      if(nowMinutes < sessionStartMinutes)
      {
         return GetJSTDateTime(
            StartHour_JST,
            StartMinute_JST,
            -1
         );
      }

      return GetJSTDateTime(
         StartHour_JST,
         StartMinute_JST,
         0
      );
   }

   if(nowMinutes < sessionStartMinutes)
   {
      return GetJSTDateTime(
         StartHour_JST,
         StartMinute_JST,
         -1
      );
   }

   return GetJSTDateTime(
      StartHour_JST,
      StartMinute_JST,
      0
   );
}

datetime GetBotSessionEnd()
{
   datetime nowJST = TimeGMT() + 9 * 3600;

   MqlDateTime dt;
   TimeToStruct(nowJST, dt);

   int nowMinutes = dt.hour * 60 + dt.min;

   int sessionStartMinutes =
      StartHour_JST * 60 + StartMinute_JST;

   int sessionEndMinutes =
      StopHour_JST * 60 + StopMinute_JST;

   if(sessionEndMinutes < sessionStartMinutes)
   {
      if(nowMinutes < sessionStartMinutes)
         return GetJSTDateTime(StopHour_JST, StopMinute_JST, 0);

      return GetJSTDateTime(StopHour_JST, StopMinute_JST, 1);
   }

   return GetJSTDateTime(StopHour_JST, StopMinute_JST, 0);
}

datetime GetJSTStartOfWeek()
{
   datetime gmtNow = TimeGMT();
   datetime jstNow = gmtNow + 9 * 3600;

   MqlDateTime dt;
   TimeToStruct(jstNow, dt);

   int daysFromMonday =
      dt.day_of_week - 1;

   if(daysFromMonday < 0)
      daysFromMonday = 6;

   datetime jstWeekStart =
      jstNow - daysFromMonday * 86400;

   MqlDateTime ws;
   TimeToStruct(jstWeekStart, ws);

   ws.hour = 0;
   ws.min  = 0;
   ws.sec  = 0;

   jstWeekStart = StructToTime(ws);

   datetime gmtWeekStart =
      jstWeekStart - 9 * 3600;

   int serverOffset =
      (int)(TimeTradeServer() - TimeGMT());

   return gmtWeekStart + serverOffset;
}

double GetClosedProfit(datetime fromTime, datetime toTime)
{
   HistorySelect(fromTime, toTime);

   double profit = 0;

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);

      if(ticket == 0)
         continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);

      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT)
         continue;

      string symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);

      if(symbol != _Symbol)
         continue;

      if(magic != MagicNumber)
         continue;

      profit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
      profit += HistoryDealGetDouble(ticket, DEAL_SWAP);
      profit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }

   return profit;
}


void SendDailyReport()
{
   datetime fromTime = GetBotSessionStart();
   datetime toTime = TimeCurrent();

   double profit = GetClosedProfit(fromTime, toTime);

   long accountID = AccountInfoInteger(ACCOUNT_LOGIN);
   string accountName = AccountInfoString(ACCOUNT_NAME);
   string server = AccountInfoString(ACCOUNT_SERVER);

   string msg =
      "ID " + IntegerToString(accountID) + "\n"
      + "Tên " + accountName + "\n\n"
      + "Broker: " + server + "\n\n"
      + "Phiên bot:\n"
      + TimeToString(ServerTimeToJST(fromTime), TIME_DATE | TIME_MINUTES)
      + " JST → "
      + TimeToString(ServerTimeToJST(toTime), TIME_DATE | TIME_MINUTES)
      + " JST\n\n"
      + "Lợi nhuận phiên:\n"
      + DoubleToString(profit, 2) + " USD";

   SendTelegram(msg);
}

void SendWeeklyReport()
{
   datetime fromTime = GetJSTStartOfWeek();
   datetime toTime   = TimeCurrent();

   double profit = GetClosedProfit(fromTime, toTime);
   double commission = profit * CommissionPercent / 100.0;

   long accountID = AccountInfoInteger(ACCOUNT_LOGIN);
   string accountName = AccountInfoString(ACCOUNT_NAME);
   string server = AccountInfoString(ACCOUNT_SERVER);

   string msg =
      "ID " + IntegerToString(accountID) + "\n"
      + "Tên " + accountName + "\n\n"
      + "Broker: " + server + "\n\n"
      + "Lợi nhuận tuần:\n"
      + DoubleToString(profit, 2) + " USD\n\n"
      + "Hoa hồng "
      + DoubleToString(CommissionPercent, 0)
      + "%:\n"
      + DoubleToString(commission, 2) + " USD";

   SendTelegram(msg);
}


void CheckDailyReport()
{
   if(!EnableDailyReport)
      return;

   static int lastDailyReportDay = -1;

   MqlDateTime jst;
   TimeToStruct(TimeGMT() + 9 * 3600, jst);

   if(jst.hour == DailyReportHour_JST &&
      jst.min == DailyReportMinute_JST)
   {
      if(lastDailyReportDay != jst.day_of_year)
      {
         SendDailyReport();
         lastDailyReportDay = jst.day_of_year;
      }
   }
}

void CheckWeeklyReport()
{
   if(!EnableWeeklyReport)
      return;

   static int lastWeeklyReportDay = -1;

   MqlDateTime jst;
   TimeToStruct(TimeGMT() + 9 * 3600, jst);

   if(jst.day_of_week == WeeklyReportDay_JST &&
      jst.hour == WeeklyReportHour_JST &&
      jst.min == WeeklyReportMinute_JST)
   {
      if(lastWeeklyReportDay != jst.day_of_year)
      {
         SendWeeklyReport();
         lastWeeklyReportDay = jst.day_of_year;
      }
   }
}

//+------------------------------------------------------------------+
void SendTelegram(string text)
{
   if(BotToken == "" || ChatID == "")
      return;

   string url =
      "https://api.telegram.org/bot"
      + BotToken
      + "/sendMessage";

   string data =
      "chat_id=" + ChatID +
      "&text=" + UrlEncode(text);

   char post[];
   char result[];
   string headers;

   StringToCharArray(data, post, 0, WHOLE_ARRAY, CP_UTF8);

   ResetLastError();

   int res = WebRequest(
      "POST",
      url,
      "Content-Type: application/x-www-form-urlencoded\r\n",
      5000,
      post,
      result,
      headers
   );

   if(res == -1)
   {
      Print("Telegram Error: ", GetLastError());
   }
}
//+------------------------------------------------------------------+
string UrlEncode(string str)
{
   string result = "";
   uchar data[];

   StringToCharArray(str, data, 0, WHOLE_ARRAY, CP_UTF8);

   for(int i = 0; i < ArraySize(data) - 1; i++)
   {
      uchar c = data[i];

      if((c >= 'A' && c <= 'Z') ||
         (c >= 'a' && c <= 'z') ||
         (c >= '0' && c <= '9') ||
         c == '-' || c == '_' ||
         c == '.' || c == '~')
      {
         result += CharToString(c);
      }
      else if(c == ' ')
      {
         result += "+";
      }
      else
      {
         result += "%" + StringFormat("%02X", c);
      }
   }

   return result;
}
//+------------------------------------------------------------------+
