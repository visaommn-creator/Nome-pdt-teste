//+------------------------------------------------------------------+
//| GONIM_DIRECTIONAL_CONTINUOUS_FLOW_CARPET_V3_SURVIVAL_FIRST.mq4   |
//| Continuous FRAMA flow carpet; no baskets and no long recovery.    |
//+------------------------------------------------------------------+
#property strict

//====================================================================
// GENERAL
//====================================================================
input int      MagicNumber                           = 90303;
input double   LotsPerOrder                          = 0.01;
input int      Slippage                              = 3;
input bool     PrintEvents                           = false;

//====================================================================
// DIRECTION SENSOR — EXTRACTED FRAMA HIGH/LOW + LIVE FLOW
//====================================================================
input int      DirectionMode                         = 0;       // 0=AUTO, 1=BUY_ONLY, 2=SELL_ONLY
input int      DirectionTimeframe                    = PERIOD_M5;
input int      FRAMAChannelPeriod                    = 3;       // effective minimum = 8
input int      FRAMAFastConstant                     = 4;
input int      FRAMASlowConstant                     = 300;
input int      DirectionSlopeBars                    = 2;
input double   MinChannelSlopePoints                 = 1.5;
input bool     RequireDirectionalCandle              = true;
input bool     RequireChannelBreak                   = true;
input double   LiveTickMinimumPoints                 = 0.5;
input int      InitialFlowConfirmTicks               = 3;
input int      FlipTicksWithBase                     = 2;
input int      FlipTicksAgainstBase                  = 4;
input double   FlipMinimumCumulativePoints           = 2.0;
input int      MinimumSecondsBetweenDirectionFlips   = 1;

//====================================================================
// CONTINUOUS ONE-POINT CARPET
//====================================================================
input int      PendingOrdersAhead                    = 50;
input double   CarpetSpacingPoints                   = 1.0;
input double   FirstPendingOffsetPoints              = 1.0;
input int      MaxPlacementsPerTick                  = 12;
input int      PlacementTimeBudgetMilliseconds       = 50;
input int      MaxTotalFlowOrders                    = 60;
input int      MaxConcurrentMarketOrders             = 12;
input double   MaxSpreadPoints                       = 4.0;
input bool     CancelPendingWhenSpreadHigh           = true;

//====================================================================
// MICRO TP — COST AWARE
//====================================================================
input double   NominalTakeProfitPoints               = 2.0;
input bool     AutoOptimizeTakeProfit                = true;
input double   EstimatedRoundTurnCommissionPerLot    = 7.0;
input double   MinimumExpectedNetPerOrderMoney       = 0.01;
input double   TakeProfitSafetyPoints                = 1.0;
input bool     MaintainNetPositiveTakeProfit         = true;
input int      TakeProfitRefreshSeconds              = 2;
input double   ManualProfitSweepMoney                = 0.01;

//====================================================================
// ZERO-TOLERANCE OFF-ORDER CLEANER
//====================================================================
input bool     CloseWrongSideImmediately             = true;
input int      MaximumMarketOrderAgeSeconds          = 12;
input double   MaximumAdversePointsPerOrder          = 4.0;
input double   BaseMicroLossCutMoney                 = 0.06;
input double   MinimumMicroLossCutMoney              = 0.02;
input double   MaximumMicroLossCutMoney              = 0.12;
input double   TargetAveragePayoffRatio              = 2.0;
input bool     AdaptiveMicroLossCut                  = true;
input double   MaximumFlowFloatingLossMoney          = 1.50;
input int      EmergencyPauseSeconds                 = 60;
input bool     FlatOrphansOnStartup                  = true;
input bool     FlatOnDeinit                          = true;

//====================================================================
// SURVIVAL WINDOWS
//====================================================================
input bool     AvoidRollover                         = true;
input int      RolloverStartHour                     = 23;
input int      RolloverStartMinute                   = 55;
input int      RolloverEndHour                       = 0;
input int      RolloverEndMinute                     = 10;
input bool     FridayFlat                            = true;
input int      FridayFlatHour                        = 20;
input int      FridayFlatMinute                      = 0;

//====================================================================
// LEARNING + CSV
//====================================================================
input double   LearningAlpha                         = 0.20;
input bool     ResetLearningInStrategyTester         = true;
input bool     EnableCSV                             = true;
input string   CSVFilePrefix                         = "GONIM_DIRECTIONAL_CONTINUOUS_FLOW_CARPET_V3_SURVIVAL_FIRST";
input int      StatusLogIntervalSeconds              = 60;

//====================================================================
// STATE
//====================================================================
int       g_baseDirection             = -1;
datetime  g_baseSignalBarTime         = 0;
int       g_flowDirection             = -1;
datetime  g_lastFlowSwitchTime        = 0;

double    g_lastMidPrice              = 0.0;
int       g_liveBuyTicks              = 0;
int       g_liveSellTicks             = 0;
double    g_liveBuyPoints             = 0.0;
double    g_liveSellPoints            = 0.0;

double    g_nextPendingPrice          = 0.0;
int       g_pendingSequence           = 0;
double    g_tpPoints                  = 0.0;
datetime  g_lastTPRefreshTime         = 0;
datetime  g_pauseUntil                = 0;
bool      g_startupCleanup            = false;

double    g_ewmaWin                   = 0.0;
double    g_ewmaLoss                  = 0.0;
int       g_winCount                  = 0;
int       g_lossCount                 = 0;
double    g_totalRealized             = 0.0;
int       g_lastProcessedHistoryTicket= 0;

datetime  g_lastStatusLogTime         = 0;
int       g_fileHandle                = INVALID_HANDLE;
string    g_fileName                  = "";

//+------------------------------------------------------------------+
int OnInit()
{
   if(LotsPerOrder <= 0.0 || PendingOrdersAhead <= 0 || CarpetSpacingPoints <= 0.0)
      return(INIT_PARAMETERS_INCORRECT);

   if(IsTesting() && ResetLearningInStrategyTester)
      ResetLearningState();
   else
      LoadLearningState();

   g_tpPoints = OptimizedTPPoints(LotsPerOrder);
   g_lastMidPrice = CurrentMidPrice();
   InitializeHistoryCursor();
   InitCSV();

   if(FlatOrphansOnStartup && CountAllFlowOrders() > 0)
      g_startupCleanup = true;

   LogEvent("INIT", StringFormat("tp=%.1f;pendingAhead=%d;spacing=%.1f;microCut=%.2f",
                                  g_tpPoints,
                                  PendingOrdersAhead,
                                  CarpetSpacingPoints,
                                  AdaptiveLossCutMoney()));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(FlatOnDeinit)
   {
      CancelAllPending();
      CloseAllMarketOrders("DEINIT_FLAT");
   }

   SaveLearningState();
   LogEvent("DEINIT", IntegerToString(reason));

   if(g_fileHandle != INVALID_HANDLE)
   {
      FileFlush(g_fileHandle);
      FileClose(g_fileHandle);
      g_fileHandle = INVALID_HANDLE;
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   RefreshRates();
   UpdateBaseDirection();
   UpdateLiveFlow();
   ProcessNewClosedOrders();
   MaintainPositiveTakeProfits();

   if(g_startupCleanup)
   {
      CancelAllPending();
      CloseAllMarketOrders("STARTUP_ORPHAN_FLAT");
      if(CountAllFlowOrders() <= 0)
      {
         g_startupCleanup = false;
         g_pauseUntil = TimeCurrent() + MathMax(1, EmergencyPauseSeconds);
         LogEvent("STARTUP_CLEAN", "COMPLETE");
      }
      return;
   }

   if(IsFridayFlatWindow())
   {
      CancelAllPending();
      CloseAllMarketOrders("FRIDAY_FLAT");
      LogPeriodicStatus();
      return;
   }

   if(IsRolloverWindow())
   {
      CancelAllPending();
      CloseAllMarketOrders("ROLLOVER_FLAT");
      LogPeriodicStatus();
      return;
   }

   int desiredDirection = EffectiveFlowDirection();
   if(desiredDirection == OP_BUY || desiredDirection == OP_SELL)
   {
      if(g_flowDirection != desiredDirection &&
         TimeCurrent() - g_lastFlowSwitchTime >= MathMax(0, MinimumSecondsBetweenDirectionFlips))
         SwitchFlowDirection(desiredDirection);
   }

   ManageMarketOrders();

   if(EmergencyLossGuard())
   {
      LogPeriodicStatus();
      return;
   }

   if(TimeCurrent() < g_pauseUntil)
   {
      CancelAllPending();
      LogPeriodicStatus();
      return;
   }

   if(g_flowDirection != OP_BUY && g_flowDirection != OP_SELL)
   {
      CancelAllPending();
      LogPeriodicStatus();
      return;
   }

   if(CurrentSpreadPoints() > MaxSpreadPoints)
   {
      if(CancelPendingWhenSpreadHigh)
         CancelAllPending();
      LogPeriodicStatus();
      return;
   }

   if(CountMarketOrders() >= MathMax(1, MaxConcurrentMarketOrders))
   {
      CancelAllPending();
      LogPeriodicStatus();
      return;
   }

   MaintainContinuousCarpet();
   LogPeriodicStatus();
}

//====================================================================
// DIRECTION MOTOR
//====================================================================
int DirectionTF()
{
   if(DirectionTimeframe <= 0)
      return(PERIOD_M5);
   return(DirectionTimeframe);
}

//+------------------------------------------------------------------+
double PriceByType(int appliedPrice, int shift)
{
   int tf = DirectionTF();
   if(appliedPrice == PRICE_HIGH) return(iHigh(Symbol(), tf, shift));
   if(appliedPrice == PRICE_LOW)  return(iLow(Symbol(), tf, shift));
   if(appliedPrice == PRICE_OPEN) return(iOpen(Symbol(), tf, shift));
   return(iClose(Symbol(), tf, shift));
}

//+------------------------------------------------------------------+
double FRAMAValue(int appliedPrice, int shift)
{
   int period = MathMax(8, FRAMAChannelPeriod);
   if(period % 2 != 0)
      period++;

   int half = period / 2;
   int bars = MathMax(period * 4, period + 40);
   double fr = PriceByType(appliedPrice, shift + bars);
   double slowAlpha = 2.0 / (MathMax(2, FRAMASlowConstant) + 1.0);
   double fastAlpha = 2.0 / (MathMax(1, FRAMAFastConstant) + 1.0);

   for(int i = bars - period - 1; i >= 0; i--)
   {
      double n1 = 0.0;
      double n2 = 0.0;
      double n3 = 0.0;

      for(int j = 0; j < half; j++)
      {
         n1 += MathAbs(PriceByType(appliedPrice, shift+i+j) - PriceByType(appliedPrice, shift+i+j+1));
         n2 += MathAbs(PriceByType(appliedPrice, shift+i+half+j) - PriceByType(appliedPrice, shift+i+half+j+1));
      }

      for(int k = 0; k < period; k++)
         n3 += MathAbs(PriceByType(appliedPrice, shift+i+k) - PriceByType(appliedPrice, shift+i+k+1));

      double dimension = 1.0;
      if(n1 > 0.0 && n2 > 0.0 && n3 > 0.0)
         dimension = (MathLog(n1 + n2) - MathLog(n3)) / MathLog(2.0);

      double alpha = MathExp(-4.6 * (dimension - 1.0));
      alpha = MathMax(slowAlpha, MathMin(fastAlpha, alpha));
      fr = alpha * PriceByType(appliedPrice, shift+i) + (1.0 - alpha) * fr;
   }

   return(fr);
}

//+------------------------------------------------------------------+
double ChannelUpper(int shift) { return(FRAMAValue(PRICE_HIGH, shift)); }
double ChannelLower(int shift) { return(FRAMAValue(PRICE_LOW, shift)); }

double ChannelCenter(int shift)
{
   double upper = ChannelUpper(shift);
   double lower = ChannelLower(shift);
   if(upper <= 0.0 || lower <= 0.0)
      return(0.0);
   return((upper + lower) / 2.0);
}

//+------------------------------------------------------------------+
int EvaluateClosedBarDirection()
{
   if(DirectionMode == 1) return(OP_BUY);
   if(DirectionMode == 2) return(OP_SELL);

   int tf = DirectionTF();
   int slopeBars = MathMax(1, DirectionSlopeBars);
   if(iBars(Symbol(), tf) < slopeBars + 60)
      return(-1);

   double open1 = iOpen(Symbol(), tf, 1);
   double close1 = iClose(Symbol(), tf, 1);
   double upper1 = ChannelUpper(1);
   double lower1 = ChannelLower(1);
   double center1 = (upper1 + lower1) / 2.0;
   double centerOld = ChannelCenter(1 + slopeBars);

   if(open1 <= 0.0 || close1 <= 0.0 || upper1 <= 0.0 || lower1 <= 0.0 || centerOld <= 0.0)
      return(-1);

   double slopePoints = (center1 - centerOld) / Point;

   bool buy = (slopePoints >= MinChannelSlopePoints);
   if(RequireDirectionalCandle) buy = buy && (close1 > open1);
   if(RequireChannelBreak) buy = buy && (close1 > upper1);

   bool sell = (slopePoints <= -MinChannelSlopePoints);
   if(RequireDirectionalCandle) sell = sell && (close1 < open1);
   if(RequireChannelBreak) sell = sell && (close1 < lower1);

   if(buy && !sell) return(OP_BUY);
   if(sell && !buy) return(OP_SELL);
   return(-1);
}

//+------------------------------------------------------------------+
void UpdateBaseDirection()
{
   datetime closedBarTime = iTime(Symbol(), DirectionTF(), 1);
   if(closedBarTime <= 0 || closedBarTime == g_baseSignalBarTime)
      return;

   g_baseSignalBarTime = closedBarTime;
   g_baseDirection = EvaluateClosedBarDirection();

   string dir = "NONE";
   if(g_baseDirection == OP_BUY) dir = "BUY";
   if(g_baseDirection == OP_SELL) dir = "SELL";
   LogEvent("BASE_DIRECTION", dir);
}

//+------------------------------------------------------------------+
double CurrentMidPrice()
{
   return((Bid + Ask) / 2.0);
}

//+------------------------------------------------------------------+
void UpdateLiveFlow()
{
   double mid = CurrentMidPrice();
   if(mid <= 0.0)
      return;

   if(g_lastMidPrice <= 0.0)
   {
      g_lastMidPrice = mid;
      return;
   }

   double deltaPoints = (mid - g_lastMidPrice) / Point;
   double threshold = MathMax(0.1, LiveTickMinimumPoints);

   if(deltaPoints >= threshold)
   {
      g_liveBuyTicks++;
      g_liveBuyPoints += deltaPoints;
      g_liveSellTicks = 0;
      g_liveSellPoints = 0.0;
   }
   else if(deltaPoints <= -threshold)
   {
      g_liveSellTicks++;
      g_liveSellPoints += MathAbs(deltaPoints);
      g_liveBuyTicks = 0;
      g_liveBuyPoints = 0.0;
   }

   g_lastMidPrice = mid;
}

//+------------------------------------------------------------------+
int EffectiveFlowDirection()
{
   if(DirectionMode == 1) return(OP_BUY);
   if(DirectionMode == 2) return(OP_SELL);

   if(g_flowDirection != OP_BUY && g_flowDirection != OP_SELL)
   {
      if(g_baseDirection == OP_BUY && g_liveBuyTicks >= MathMax(1, InitialFlowConfirmTicks))
         return(OP_BUY);
      if(g_baseDirection == OP_SELL && g_liveSellTicks >= MathMax(1, InitialFlowConfirmTicks))
         return(OP_SELL);
      return(-1);
   }

   int buyRequired = (g_baseDirection == OP_BUY ? FlipTicksWithBase : FlipTicksAgainstBase);
   int sellRequired = (g_baseDirection == OP_SELL ? FlipTicksWithBase : FlipTicksAgainstBase);
   double moveRequired = MathMax(0.1, FlipMinimumCumulativePoints);

   if(g_flowDirection == OP_BUY &&
      g_liveSellTicks >= MathMax(1, sellRequired) &&
      g_liveSellPoints >= moveRequired)
      return(OP_SELL);

   if(g_flowDirection == OP_SELL &&
      g_liveBuyTicks >= MathMax(1, buyRequired) &&
      g_liveBuyPoints >= moveRequired)
      return(OP_BUY);

   return(g_flowDirection);
}

//+------------------------------------------------------------------+
void SwitchFlowDirection(int newDirection)
{
   if(newDirection != OP_BUY && newDirection != OP_SELL)
      return;

   int oldDirection = g_flowDirection;
   CancelAllPending();

   g_flowDirection = newDirection;
   g_lastFlowSwitchTime = TimeCurrent();
   g_nextPendingPrice = 0.0;
   g_liveBuyTicks = 0;
   g_liveSellTicks = 0;
   g_liveBuyPoints = 0.0;
   g_liveSellPoints = 0.0;

   LogEvent("FLOW_SWITCH",
            StringFormat("from=%s;to=%s;open=%.2f",
                         DirectionName(oldDirection),
                         DirectionName(newDirection),
                         TotalOpenPnL()));

   if(CloseWrongSideImmediately)
      CloseWrongSideOrders(newDirection, "FLOW_SWITCH_OFF");
}

//====================================================================
// CONTINUOUS CARPET
//====================================================================
void MaintainContinuousCarpet()
{
   if(g_flowDirection != OP_BUY && g_flowDirection != OP_SELL)
      return;

   DeletePendingNotMatchingFlow();
   DeletePendingBehindPrice();

   int pending = CountPendingDirection(g_flowDirection);
   int target = MathMax(1, PendingOrdersAhead);
   if(pending >= target)
      return;

   if(CountAllFlowOrders() >= MathMax(1, MaxTotalFlowOrders))
      return;

   if(g_nextPendingPrice <= 0.0)
   {
      double furthest = FurthestPendingPrice(g_flowDirection);
      if(furthest > 0.0)
         g_nextPendingPrice = NormalizeDouble(furthest + DirectionSign(g_flowDirection) * CarpetSpacingPoints * Point, Digits);
      else
         g_nextPendingPrice = FirstValidPendingPrice(g_flowDirection);
   }

   int startMs = GetTickCount();
   int placed = 0;
   int maxBatch = MathMax(1, MaxPlacementsPerTick);

   while(pending < target && placed < maxBatch)
   {
      if(GetTickCount() - startMs >= MathMax(1, PlacementTimeBudgetMilliseconds))
         break;
      if(CountAllFlowOrders() >= MathMax(1, MaxTotalFlowOrders))
         break;
      if(CountMarketOrders() >= MathMax(1, MaxConcurrentMarketOrders))
         break;

      double minimumValid = FirstValidPendingPrice(g_flowDirection);
      if(g_flowDirection == OP_BUY && g_nextPendingPrice < minimumValid)
         g_nextPendingPrice = minimumValid;
      if(g_flowDirection == OP_SELL && g_nextPendingPrice > minimumValid)
         g_nextPendingPrice = minimumValid;

      double price = NormalizeDouble(g_nextPendingPrice, Digits);
      if(PendingExistsNear(price, g_flowDirection))
      {
         AdvancePendingCursor();
         continue;
      }

      if(!EnoughMarginForDirection(g_flowDirection, LotsPerOrder))
      {
         CancelAllPending();
         LogEvent("MARGIN_BLOCK", StringFormat("free=%.2f", AccountFreeMargin()));
         return;
      }

      int ticket = SendFlowPending(g_flowDirection, price);
      if(ticket < 0)
      {
         int err = GetLastError();
         ResetLastError();
         if(err != 1 && err != 130)
            LogEvent("ORDER_SEND_ERROR", StringFormat("error=%d;price=%.5f", err, price));
         break;
      }

      pending++;
      placed++;
      AdvancePendingCursor();
   }
}

//+------------------------------------------------------------------+
double FirstValidPendingPrice(int direction)
{
   double brokerPoints = MathMax(MarketInfo(Symbol(), MODE_STOPLEVEL),
                                 MarketInfo(Symbol(), MODE_FREEZELEVEL)) + 1.0;
   double offset = MathMax(FirstPendingOffsetPoints, brokerPoints);

   if(direction == OP_BUY)
      return(NormalizeDouble(Ask + offset * Point, Digits));
   return(NormalizeDouble(Bid - offset * Point, Digits));
}

//+------------------------------------------------------------------+
void AdvancePendingCursor()
{
   g_nextPendingPrice = NormalizeDouble(g_nextPendingPrice +
                                        DirectionSign(g_flowDirection) *
                                        MathMax(0.1, CarpetSpacingPoints) * Point,
                                        Digits);
}

//+------------------------------------------------------------------+
int SendFlowPending(int direction, double price)
{
   int type = (direction == OP_BUY ? OP_BUYSTOP : OP_SELLSTOP);
   double lots = NormalizeLots(LotsPerOrder);
   double tp = 0.0;

   if(direction == OP_BUY)
      tp = NormalizeDouble(price + g_tpPoints * Point, Digits);
   else
      tp = NormalizeDouble(price - g_tpPoints * Point, Digits);

   g_pendingSequence++;
   string side = (direction == OP_BUY ? "B" : "S");
   string comment = StringFormat("GFC3_%s_%d", side, g_pendingSequence);
   color arrow = (direction == OP_BUY ? clrBlue : clrRed);

   return(OrderSend(Symbol(), type, lots, price, Slippage, 0.0, tp, comment, MagicNumber, 0, arrow));
}

//+------------------------------------------------------------------+
bool PendingExistsNear(double price, int direction)
{
   int expectedType = (direction == OP_BUY ? OP_BUYSTOP : OP_SELLSTOP);
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != expectedType) continue;
      if(MathAbs(OrderOpenPrice() - price) <= 0.25 * Point)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
double FurthestPendingPrice(int direction)
{
   double value = 0.0;
   int expectedType = (direction == OP_BUY ? OP_BUYSTOP : OP_SELLSTOP);

   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(OrderType() != expectedType) continue;

      if(value <= 0.0)
         value = OrderOpenPrice();
      else if(direction == OP_BUY)
         value = MathMax(value, OrderOpenPrice());
      else
         value = MathMin(value, OrderOpenPrice());
   }

   return(value);
}

//+------------------------------------------------------------------+
void DeletePendingNotMatchingFlow()
{
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(!IsPendingType(OrderType())) continue;

      bool keep = (g_flowDirection == OP_BUY && OrderType() == OP_BUYSTOP) ||
                  (g_flowDirection == OP_SELL && OrderType() == OP_SELLSTOP);
      if(keep) continue;

      int ticket = OrderTicket();
      if(!OrderDelete(ticket, clrNONE))
      {
         int err = GetLastError();
         ResetLastError();
         if(err != 1)
            LogEvent("DELETE_ERROR", StringFormat("ticket=%d;error=%d", ticket, err));
      }
   }
}

//+------------------------------------------------------------------+
void DeletePendingBehindPrice()
{
   double stopDistance = MathMax(MarketInfo(Symbol(), MODE_STOPLEVEL),
                                 MarketInfo(Symbol(), MODE_FREEZELEVEL)) * Point;

   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(!IsPendingType(OrderType())) continue;

      bool invalid = false;
      if(OrderType() == OP_BUYSTOP && OrderOpenPrice() <= Ask + stopDistance)
         invalid = true;
      if(OrderType() == OP_SELLSTOP && OrderOpenPrice() >= Bid - stopDistance)
         invalid = true;
      if(!invalid) continue;

      int ticket = OrderTicket();
      OrderDelete(ticket, clrNONE);
   }
}

//+------------------------------------------------------------------+
void CancelAllPending()
{
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(!IsPendingType(OrderType())) continue;

      int ticket = OrderTicket();
      if(!OrderDelete(ticket, clrNONE))
      {
         int err = GetLastError();
         ResetLastError();
         if(err != 1)
            LogEvent("DELETE_ERROR", StringFormat("ticket=%d;error=%d", ticket, err));
      }
   }
   g_nextPendingPrice = 0.0;
}

//====================================================================
// MARKET ORDER CLEANER — NO LONG RECOVERY
//====================================================================
void ManageMarketOrders()
{
   if(g_flowDirection == OP_BUY || g_flowDirection == OP_SELL)
      CloseWrongSideOrders(g_flowDirection, "WRONG_SIDE_OFF");

   double lossCut = AdaptiveLossCutMoney();

   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(!IsMarketType(OrderType())) continue;

      int ticket = OrderTicket();
      double net = OrderProfit() + OrderSwap() + OrderCommission();
      int age = (int)(TimeCurrent() - OrderOpenTime());
      double adversePoints = 0.0;

      if(OrderType() == OP_BUY)
         adversePoints = MathMax(0.0, (OrderOpenPrice() - Bid) / Point);
      else
         adversePoints = MathMax(0.0, (Ask - OrderOpenPrice()) / Point);

      if(net >= MathMax(0.0, ManualProfitSweepMoney))
      {
         CloseSelectedOrder("MICRO_PROFIT_SWEEP");
         continue;
      }

      if(net <= -lossCut)
      {
         CloseSelectedOrder("MICRO_LOSS_CUT");
         continue;
      }

      if(adversePoints >= MathMax(0.1, MaximumAdversePointsPerOrder))
      {
         CloseSelectedOrder("ADVERSE_POINT_CUT");
         continue;
      }

      if(age >= MathMax(1, MaximumMarketOrderAgeSeconds))
      {
         CloseSelectedOrder("STALE_ORDER_CUT");
         continue;
      }
   }
}

//+------------------------------------------------------------------+
void CloseWrongSideOrders(int activeDirection, string reason)
{
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(!IsMarketType(OrderType())) continue;

      bool wrong = (activeDirection == OP_BUY && OrderType() == OP_SELL) ||
                   (activeDirection == OP_SELL && OrderType() == OP_BUY);
      if(wrong)
         CloseSelectedOrder(reason);
   }
}

//+------------------------------------------------------------------+
bool CloseSelectedOrder(string reason)
{
   int ticket = OrderTicket();
   int type = OrderType();
   double lots = OrderLots();
   double beforeNet = OrderProfit() + OrderSwap() + OrderCommission();

   RefreshRates();
   double closePrice = (type == OP_BUY ? Bid : Ask);
   bool closed = OrderClose(ticket, lots, closePrice, Slippage, clrNONE);

   if(closed)
   {
      LogEvent("ORDER_FLAT", StringFormat("ticket=%d;reason=%s;before=%.2f", ticket, reason, beforeNet));
      return(true);
   }

   int err = GetLastError();
   ResetLastError();
   LogEvent("CLOSE_ERROR", StringFormat("ticket=%d;reason=%s;error=%d", ticket, reason, err));
   return(false);
}

//+------------------------------------------------------------------+
void CloseAllMarketOrders(string reason)
{
   for(int pass = 0; pass < 2; pass++)
   {
      for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
      {
         if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
         if(!IsMarketType(OrderType())) continue;
         CloseSelectedOrder(reason);
      }
   }
}

//+------------------------------------------------------------------+
bool EmergencyLossGuard()
{
   double limit = MathMax(0.01, MaximumFlowFloatingLossMoney);
   double open = TotalOpenPnL();
   if(open > -limit)
      return(false);

   LogEvent("EMERGENCY_FLOW_CUT", StringFormat("open=%.2f;limit=%.2f", open, limit));
   CancelAllPending();
   CloseAllMarketOrders("EMERGENCY_FLOW_CUT");
   g_pauseUntil = TimeCurrent() + MathMax(1, EmergencyPauseSeconds);
   g_flowDirection = -1;
   g_nextPendingPrice = 0.0;
   return(true);
}

//====================================================================
// TP AND COST
//====================================================================
double MoneyPerPointPerLot()
{
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(0.0);
   return(tickValue * Point / tickSize);
}

//+------------------------------------------------------------------+
double OptimizedTPPoints(double lots)
{
   double minimum = MathMax(0.1, NominalTakeProfitPoints);
   if(!AutoOptimizeTakeProfit)
      return(minimum);

   double value = MoneyPerPointPerLot();
   if(value <= 0.0 || lots <= 0.0)
      return(minimum);

   double commission = MathMax(0.0, EstimatedRoundTurnCommissionPerLot) * lots;
   double requiredMoney = commission + MathMax(0.0, MinimumExpectedNetPerOrderMoney);
   double requiredPoints = requiredMoney / (value * lots);
   requiredPoints += MathMax(0.0, TakeProfitSafetyPoints);

   double brokerMinimum = MathMax(0.0, MarketInfo(Symbol(), MODE_STOPLEVEL)) + 1.0;
   return(MathMax(MathMax(minimum, brokerMinimum), MathCeil(requiredPoints)));
}

//+------------------------------------------------------------------+
void MaintainPositiveTakeProfits()
{
   if(!MaintainNetPositiveTakeProfit)
      return;

   int interval = MathMax(1, TakeProfitRefreshSeconds);
   if(g_lastTPRefreshTime > 0 && TimeCurrent() - g_lastTPRefreshTime < interval)
      return;
   g_lastTPRefreshTime = TimeCurrent();

   double value = MoneyPerPointPerLot();
   if(value <= 0.0)
      return;

   double brokerDistance = MathMax(MarketInfo(Symbol(), MODE_STOPLEVEL),
                                   MarketInfo(Symbol(), MODE_FREEZELEVEL)) + 1.0;

   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(!IsMarketType(OrderType())) continue;

      double lots = OrderLots();
      if(lots <= 0.0) continue;

      double estimatedCommission = MathMax(0.0, EstimatedRoundTurnCommissionPerLot) * lots;
      double observedCost = MathMax(0.0, -OrderCommission()) + MathMax(0.0, -OrderSwap());
      double requiredMoney = MathMax(estimatedCommission, observedCost) +
                             MathMax(0.0, MinimumExpectedNetPerOrderMoney);
      double points = requiredMoney / (value * lots);
      points = MathMax(g_tpPoints, MathCeil(points + MathMax(0.0, TakeProfitSafetyPoints)));

      double desiredTP = 0.0;
      if(OrderType() == OP_BUY)
      {
         desiredTP = MathMax(OrderOpenPrice() + points * Point,
                             Bid + brokerDistance * Point);
      }
      else
      {
         desiredTP = MathMin(OrderOpenPrice() - points * Point,
                             Ask - brokerDistance * Point);
      }
      desiredTP = NormalizeDouble(desiredTP, Digits);

      bool needsMove = false;
      if(OrderType() == OP_BUY)
         needsMove = (OrderTakeProfit() <= 0.0 || desiredTP > OrderTakeProfit() + 0.5 * Point);
      else
         needsMove = (OrderTakeProfit() <= 0.0 || desiredTP < OrderTakeProfit() - 0.5 * Point);

      if(!needsMove) continue;

      int ticket = OrderTicket();
      if(!OrderModify(ticket, OrderOpenPrice(), OrderStopLoss(), desiredTP, 0, clrNONE))
      {
         int err = GetLastError();
         ResetLastError();
         if(err != 1 && err != 130 && err != 145)
            LogEvent("TP_MODIFY_ERROR", StringFormat("ticket=%d;error=%d", ticket, err));
      }
   }
}

//====================================================================
// LEARNING
//====================================================================
void InitializeHistoryCursor()
{
   g_lastProcessedHistoryTicket = 0;
   int total = OrdersHistoryTotal();
   for(int pos = 0; pos < total; pos++)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      g_lastProcessedHistoryTicket = MathMax(g_lastProcessedHistoryTicket, OrderTicket());
   }
}

//+------------------------------------------------------------------+
void ProcessNewClosedOrders()
{
   int total = OrdersHistoryTotal();
   int maxTicket = g_lastProcessedHistoryTicket;

   for(int pos = 0; pos < total; pos++)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(!IsMarketType(OrderType())) continue;
      if(StringFind(OrderComment(), "GFC3_", 0) != 0) continue;
      if(OrderTicket() <= g_lastProcessedHistoryTicket) continue;

      double result = OrderProfit() + OrderSwap() + OrderCommission();
      UpdateLearning(result);
      g_totalRealized += result;
      maxTicket = MathMax(maxTicket, OrderTicket());

      LogEvent("ORDER_RESULT",
               StringFormat("ticket=%d;result=%.2f;avgWin=%.2f;avgLoss=%.2f;ratio=%.2f",
                            OrderTicket(), result, g_ewmaWin, g_ewmaLoss, CurrentPayoffRatio()));
   }

   g_lastProcessedHistoryTicket = maxTicket;
}

//+------------------------------------------------------------------+
void UpdateLearning(double result)
{
   double alpha = MathMax(0.01, MathMin(1.0, LearningAlpha));

   if(result > 0.0)
   {
      g_winCount++;
      if(g_ewmaWin <= 0.0) g_ewmaWin = result;
      else g_ewmaWin = alpha * result + (1.0 - alpha) * g_ewmaWin;
   }
   else if(result < 0.0)
   {
      double loss = MathAbs(result);
      g_lossCount++;
      if(g_ewmaLoss <= 0.0) g_ewmaLoss = loss;
      else g_ewmaLoss = alpha * loss + (1.0 - alpha) * g_ewmaLoss;
   }

   SaveLearningState();
}

//+------------------------------------------------------------------+
double AdaptiveLossCutMoney()
{
   double base = MathMax(MinimumMicroLossCutMoney,
                         MathMin(MaximumMicroLossCutMoney, BaseMicroLossCutMoney));
   if(!AdaptiveMicroLossCut || g_ewmaWin <= 0.0)
      return(base);

   double target = g_ewmaWin / MathMax(1.0, TargetAveragePayoffRatio);
   target = MathMax(MinimumMicroLossCutMoney, MathMin(MaximumMicroLossCutMoney, target));
   return(MathMin(base, target));
}

//+------------------------------------------------------------------+
double CurrentPayoffRatio()
{
   if(g_ewmaLoss <= 0.0)
      return(0.0);
   return(g_ewmaWin / g_ewmaLoss);
}

//+------------------------------------------------------------------+
string GVPrefix()
{
   return(StringFormat("GONIM_GFC3_%s_%d_", Symbol(), MagicNumber));
}

void ResetLearningState()
{
   g_ewmaWin = 0.0;
   g_ewmaLoss = 0.0;
   g_winCount = 0;
   g_lossCount = 0;
   g_totalRealized = 0.0;

   string p = GVPrefix();
   if(GlobalVariableCheck(p+"EWIN")) GlobalVariableDel(p+"EWIN");
   if(GlobalVariableCheck(p+"ELOSS")) GlobalVariableDel(p+"ELOSS");
   if(GlobalVariableCheck(p+"WINS")) GlobalVariableDel(p+"WINS");
   if(GlobalVariableCheck(p+"LOSSES")) GlobalVariableDel(p+"LOSSES");
   if(GlobalVariableCheck(p+"REALIZED")) GlobalVariableDel(p+"REALIZED");
}

void LoadLearningState()
{
   string p = GVPrefix();
   if(GlobalVariableCheck(p+"EWIN")) g_ewmaWin = GlobalVariableGet(p+"EWIN");
   if(GlobalVariableCheck(p+"ELOSS")) g_ewmaLoss = GlobalVariableGet(p+"ELOSS");
   if(GlobalVariableCheck(p+"WINS")) g_winCount = (int)GlobalVariableGet(p+"WINS");
   if(GlobalVariableCheck(p+"LOSSES")) g_lossCount = (int)GlobalVariableGet(p+"LOSSES");
   if(GlobalVariableCheck(p+"REALIZED")) g_totalRealized = GlobalVariableGet(p+"REALIZED");
}

void SaveLearningState()
{
   string p = GVPrefix();
   GlobalVariableSet(p+"EWIN", g_ewmaWin);
   GlobalVariableSet(p+"ELOSS", g_ewmaLoss);
   GlobalVariableSet(p+"WINS", g_winCount);
   GlobalVariableSet(p+"LOSSES", g_lossCount);
   GlobalVariableSet(p+"REALIZED", g_totalRealized);
}

//====================================================================
// SURVIVAL WINDOWS
//====================================================================
bool IsRolloverWindow()
{
   if(!AvoidRollover)
      return(false);

   int nowMinutes = TimeHour(TimeCurrent()) * 60 + TimeMinute(TimeCurrent());
   int startMinutes = RolloverStartHour * 60 + RolloverStartMinute;
   int endMinutes = RolloverEndHour * 60 + RolloverEndMinute;

   if(startMinutes <= endMinutes)
      return(nowMinutes >= startMinutes && nowMinutes < endMinutes);
   return(nowMinutes >= startMinutes || nowMinutes < endMinutes);
}

//+------------------------------------------------------------------+
bool IsFridayFlatWindow()
{
   if(!FridayFlat || DayOfWeek() != 5)
      return(false);

   int nowMinutes = TimeHour(TimeCurrent()) * 60 + TimeMinute(TimeCurrent());
   int flatMinutes = FridayFlatHour * 60 + FridayFlatMinute;
   return(nowMinutes >= flatMinutes);
}

//====================================================================
// HELPERS
//====================================================================
bool IsPendingType(int type)
{
   return(type == OP_BUYSTOP || type == OP_SELLSTOP || type == OP_BUYLIMIT || type == OP_SELLLIMIT);
}

bool IsMarketType(int type)
{
   return(type == OP_BUY || type == OP_SELL);
}

int DirectionSign(int direction)
{
   if(direction == OP_BUY) return(1);
   if(direction == OP_SELL) return(-1);
   return(0);
}

string DirectionName(int direction)
{
   if(direction == OP_BUY) return("BUY");
   if(direction == OP_SELL) return("SELL");
   return("NONE");
}

//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0) step = 0.01;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step + 0.0000001) * step;
   return(NormalizeDouble(lots, 2));
}

bool EnoughMarginForDirection(int direction, double lots)
{
   int marketType = (direction == OP_BUY ? OP_BUY : OP_SELL);
   return(AccountFreeMarginCheck(Symbol(), marketType, NormalizeLots(lots)) > 0.0);
}

double CurrentSpreadPoints()
{
   if(Point <= 0.0) return(999999.0);
   return((Ask - Bid) / Point);
}

//+------------------------------------------------------------------+
int CountPendingDirection(int direction)
{
   int expectedType = (direction == OP_BUY ? OP_BUYSTOP : OP_SELLSTOP);
   int count = 0;
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && OrderType() == expectedType)
         count++;
   }
   return(count);
}

int CountPendingOrders()
{
   int count = 0;
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && IsPendingType(OrderType()))
         count++;
   }
   return(count);
}

int CountMarketOrders()
{
   int count = 0;
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber && IsMarketType(OrderType()))
         count++;
   }
   return(count);
}

int CountAllFlowOrders()
{
   int count = 0;
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
         count++;
   }
   return(count);
}

double TotalOpenPnL()
{
   double pnl = 0.0;
   for(int pos = OrdersTotal() - 1; pos >= 0; pos--)
   {
      if(!OrderSelect(pos, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol() || OrderMagicNumber() != MagicNumber) continue;
      if(IsMarketType(OrderType()))
         pnl += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return(pnl);
}

//====================================================================
// CSV
//====================================================================
void InitCSV()
{
   if(!EnableCSV) return;

   g_fileName = StringFormat("%s_%s_M%d.csv", CSVFilePrefix, Symbol(), MagicNumber);
   g_fileHandle = FileOpen(g_fileName, FILE_CSV|FILE_READ|FILE_WRITE|FILE_SHARE_WRITE, ';');
   if(g_fileHandle == INVALID_HANDLE) return;

   if(FileSize(g_fileHandle) == 0)
   {
      FileWrite(g_fileHandle,
                "Time", "Event", "Details", "BaseDirection", "FlowDirection",
                "Pending", "Market", "OpenPnL", "Realized", "EWMAWin", "EWMALoss",
                "PayoffRatio", "AdaptiveLossCut", "Spread");
   }
   FileSeek(g_fileHandle, 0, SEEK_END);
}

//+------------------------------------------------------------------+
void LogPeriodicStatus()
{
   int interval = MathMax(1, StatusLogIntervalSeconds);
   if(g_lastStatusLogTime > 0 && TimeCurrent() - g_lastStatusLogTime < interval)
      return;
   g_lastStatusLogTime = TimeCurrent();

   LogEvent("STATUS",
            StringFormat("liveB=%d/%.1f;liveS=%d/%.1f;pause=%d",
                         g_liveBuyTicks, g_liveBuyPoints,
                         g_liveSellTicks, g_liveSellPoints,
                         (int)MathMax(0, g_pauseUntil-TimeCurrent())));
}

//+------------------------------------------------------------------+
void LogEvent(string eventName, string details)
{
   if(PrintEvents)
      Print("GONIM_CONTINUOUS_FLOW_V3 | ", eventName, " | ", details);

   if(!EnableCSV || g_fileHandle == INVALID_HANDLE)
      return;

   FileWrite(g_fileHandle,
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             eventName,
             details,
             DirectionName(g_baseDirection),
             DirectionName(g_flowDirection),
             CountPendingOrders(),
             CountMarketOrders(),
             DoubleToString(TotalOpenPnL(), 2),
             DoubleToString(g_totalRealized, 2),
             DoubleToString(g_ewmaWin, 2),
             DoubleToString(g_ewmaLoss, 2),
             DoubleToString(CurrentPayoffRatio(), 2),
             DoubleToString(AdaptiveLossCutMoney(), 2),
             DoubleToString(CurrentSpreadPoints(), 1));
}
//+------------------------------------------------------------------+
