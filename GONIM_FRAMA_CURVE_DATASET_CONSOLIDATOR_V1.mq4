//+------------------------------------------------------------------+
//| GONIM_FRAMA_CURVE_DATASET_CONSOLIDATOR_V1.mq4                  |
//| Fast offline consolidation of the 2021-2022 segmented datasets. |
//| No trading. No time-based guardian logic.                       |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Consolidates the 28 official Curve Guardian collector CSVs and evaluates purely mechanical equity-curve candidates."

input string CollectorBaseName = "GONIM_FRAMA_CURVE_GUARDIAN_DATASET_COLLECTOR_V1A_EURUSD_M5_30303";
input string OutputBasketFile  = "GONIM_FRAMA_BASKETS_CONSOLIDATED_V1.csv";
input string OutputBinFile     = "GONIM_FRAMA_HEALTHY_ENVELOPE_BINS_V1.csv";
input string OutputSweepFile   = "GONIM_FRAMA_CURVE_CANDIDATE_SWEEP_V1.csv";
input string OutputSummaryFile = "GONIM_FRAMA_CURVE_ANALYSIS_SUMMARY_V1.csv";
input datetime CutoffExclusive = D'2023.01.01 00:00';
input double BalanceBinSize    = 250.0;
input int    MinHealthyPerBin  = 20;
input double GlobalGapMinPct   = 5.0;
input double GlobalGapMaxPct   = 99.0;
input double GlobalGapStepPct  = 0.25;
input double MarginMaxPct      = 50.0;
input double MarginStepPct     = 0.25;
input bool   PrintProgress     = true;

int OfficialFileNumbers[28] =
{
   1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,
   20,21,22,23,24,25,26,27,28,29
};

struct BasketRecord
{
   int      segment_no;
   int      source_no;
   int      basket_id;
   string   source_file;
   string   status;
   string   direction;
   string   open_time;
   string   close_time;
   double   balance_open;
   double   equity_min;
   double   depth_usd;
   double   gap_pct;
   int      max_orders;
   double   max_lots;
   double   balance_close;
   double   basket_profit;
   string   final_row_status;
   int      deinit_reason;
};

struct BasketAgg
{
   bool     active;
   int      segment_no;
   int      source_no;
   int      basket_id;
   string   source_file;
   string   direction;
   string   open_time;
   string   close_time;
   double   balance_open;
   double   equity_min;
   double   max_gap_pct;
   int      max_orders;
   double   max_lots;
   double   balance_close;
   string   last_row_status;
   int      deinit_reason;
   int      last_open_orders;
};

BasketRecord Records[];
int BasketOut = INVALID_HANDLE;

void ResetAgg(BasketAgg &a)
{
   a.active=false;
   a.segment_no=0;
   a.source_no=0;
   a.basket_id=0;
   a.source_file="";
   a.direction="";
   a.open_time="";
   a.close_time="";
   a.balance_open=0.0;
   a.equity_min=DBL_MAX;
   a.max_gap_pct=0.0;
   a.max_orders=0;
   a.max_lots=0.0;
   a.balance_close=0.0;
   a.last_row_status="";
   a.deinit_reason=-1;
   a.last_open_orders=0;
}

void StartAgg(BasketAgg &a,int segmentNo,int sourceNo,string sourceFile,string &f[])
{
   ResetAgg(a);
   a.active=true;
   a.segment_no=segmentNo;
   a.source_no=sourceNo;
   a.source_file=sourceFile;
   a.basket_id=(int)StringToInteger(f[30]);
   a.direction=f[31];
   a.open_time=f[0];
   a.close_time=f[1];
   a.balance_open=StringToDouble(f[5]);
   a.equity_min=StringToDouble(f[11]);
   a.max_gap_pct=StringToDouble(f[17]);
   a.max_orders=(int)StringToInteger(f[24]);
   a.max_lots=StringToDouble(f[25]);
   a.balance_close=StringToDouble(f[8]);
   a.last_row_status=f[33];
   a.deinit_reason=(int)StringToInteger(f[34]);
   a.last_open_orders=(int)StringToInteger(f[26])+(int)StringToInteger(f[27]);
}

void UpdateAgg(BasketAgg &a,string &f[])
{
   double eqLow=StringToDouble(f[11]);
   double gap=StringToDouble(f[17]);
   int orders=(int)StringToInteger(f[24]);
   double lots=StringToDouble(f[25]);

   if(eqLow<a.equity_min) a.equity_min=eqLow;
   if(gap>a.max_gap_pct) a.max_gap_pct=gap;
   if(orders>a.max_orders) a.max_orders=orders;
   if(lots>a.max_lots) a.max_lots=lots;

   a.close_time=f[1];
   a.balance_close=StringToDouble(f[8]);
   a.last_row_status=f[33];
   a.deinit_reason=(int)StringToInteger(f[34]);
   a.last_open_orders=(int)StringToInteger(f[26])+(int)StringToInteger(f[27]);
}

void AppendRecord(BasketRecord &r)
{
   int n=ArraySize(Records);
   ArrayResize(Records,n+1);
   Records[n]=r;

   FileWrite(BasketOut,
             r.segment_no,r.source_no,r.source_file,r.basket_id,r.status,
             r.direction,r.open_time,r.close_time,
             DoubleToString(r.balance_open,2),
             DoubleToString(r.equity_min,2),
             DoubleToString(r.depth_usd,2),
             DoubleToString(r.gap_pct,4),
             r.max_orders,DoubleToString(r.max_lots,2),
             DoubleToString(r.balance_close,2),
             DoubleToString(r.basket_profit,2),
             r.final_row_status,r.deinit_reason);
}

void FinalizeAgg(BasketAgg &a,bool terminalAtFileEnd)
{
   if(!a.active) return;

   BasketRecord r;
   r.segment_no=a.segment_no;
   r.source_no=a.source_no;
   r.basket_id=a.basket_id;
   r.source_file=a.source_file;
   r.direction=a.direction;
   r.open_time=a.open_time;
   r.close_time=a.close_time;
   r.balance_open=a.balance_open;
   r.equity_min=a.equity_min;
   r.depth_usd=MathMax(0.0,a.balance_open-a.equity_min);
   r.gap_pct=(a.balance_open>0.0 ? 100.0*r.depth_usd/a.balance_open : 0.0);
   if(a.max_gap_pct>r.gap_pct) r.gap_pct=a.max_gap_pct;
   r.max_orders=a.max_orders;
   r.max_lots=a.max_lots;
   r.balance_close=a.balance_close;
   r.basket_profit=a.balance_close-a.balance_open;
   r.final_row_status=a.last_row_status;
   r.deinit_reason=a.deinit_reason;

   datetime opened=StringToTime(a.open_time);
   if(opened>=CutoffExclusive)
      r.status="EXCLUDED_AFTER_CUTOFF";
   else if(terminalAtFileEnd)
      r.status="TERMINAL";
   else
      r.status="RECOVERED";

   AppendRecord(r);
   ResetAgg(a);
}

bool ReadRow(int h,string &f[])
{
   ArrayResize(f,36);
   if(FileIsEnding(h)) return false;

   f[0]=FileReadString(h);
   if(FileIsEnding(h) && f[0]=="") return false;

   for(int i=1;i<36;i++)
   {
      if(FileIsEnding(h)) f[i]="";
      else                f[i]=FileReadString(h);
   }
   return true;
}

bool ProcessCollectorFile(int segmentNo,int sourceNo)
{
   string fileName=CollectorBaseName+"("+IntegerToString(sourceNo)+").csv";
   int h=FileOpen(fileName,FILE_READ|FILE_CSV|FILE_ANSI,';');
   if(h==INVALID_HANDLE)
   {
      Print("[CONSOLIDATOR] File not found: ",fileName," error=",GetLastError());
      return false;
   }

   string header[];
   ArrayResize(header,36);
   for(int i=0;i<36 && !FileIsEnding(h);i++) header[i]=FileReadString(h);

   BasketAgg a;
   ResetAgg(a);
   string f[];
   int rows=0;

   while(ReadRow(h,f))
   {
      if(f[0]=="" || f[30]=="") continue;
      int basketId=(int)StringToInteger(f[30]);
      if(basketId<=0) continue;

      if(!a.active)
         StartAgg(a,segmentNo,sourceNo,fileName,f);
      else if(basketId!=a.basket_id)
      {
         FinalizeAgg(a,false);
         StartAgg(a,segmentNo,sourceNo,fileName,f);
      }
      else
         UpdateAgg(a,f);

      rows++;
   }

   bool terminal=(a.active && a.last_row_status=="FINAL_PRE_DEINIT" && a.last_open_orders>0);
   FinalizeAgg(a,terminal);
   FileClose(h);

   if(PrintProgress)
      Print("[CONSOLIDATOR] Processed ",fileName," rows=",rows);
   return true;
}

bool IsRecovered(int i) { return(Records[i].status=="RECOVERED"); }
bool IsTerminal(int i)  { return(Records[i].status=="TERMINAL"); }

int CollectRecoveredGaps(int bin,double binSize,double &values[])
{
   ArrayResize(values,0);
   for(int i=0;i<ArraySize(Records);i++)
   {
      if(!IsRecovered(i)) continue;
      int b=(int)MathFloor(Records[i].balance_open/binSize);
      if(b!=bin) continue;
      int n=ArraySize(values);
      ArrayResize(values,n+1);
      values[n]=Records[i].gap_pct;
   }
   return ArraySize(values);
}

int CollectAllRecoveredGaps(double &values[])
{
   ArrayResize(values,0);
   for(int i=0;i<ArraySize(Records);i++)
   {
      if(!IsRecovered(i)) continue;
      int n=ArraySize(values);
      ArrayResize(values,n+1);
      values[n]=Records[i].gap_pct;
   }
   return ArraySize(values);
}

double QuantileSorted(double &a[],double p)
{
   int n=ArraySize(a);
   if(n<=0) return 0.0;
   if(n==1) return a[0];
   if(p<=0.0) return a[0];
   if(p>=1.0) return a[n-1];

   double pos=(n-1)*p;
   int lo=(int)MathFloor(pos);
   int hi=(int)MathCeil(pos);
   if(lo==hi) return a[lo];
   double w=pos-lo;
   return a[lo]*(1.0-w)+a[hi]*w;
}

void BuildEnvelopeBins(double &q95[],double &q99[],int &binCount,double &globalQ95,double &globalQ99)
{
   double maxBalance=0.0;
   for(int i=0;i<ArraySize(Records);i++)
      if(Records[i].status!="EXCLUDED_AFTER_CUTOFF" && Records[i].balance_open>maxBalance)
         maxBalance=Records[i].balance_open;

   binCount=(int)MathCeil(maxBalance/BalanceBinSize)+1;
   ArrayResize(q95,binCount);
   ArrayResize(q99,binCount);

   double all[];
   CollectAllRecoveredGaps(all);
   ArraySort(all,WHOLE_ARRAY,0,MODE_ASCEND);
   globalQ95=QuantileSorted(all,0.95);
   globalQ99=QuantileSorted(all,0.99);

   int out=FileOpen(OutputBinFile,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(out==INVALID_HANDLE)
   {
      Print("[CONSOLIDATOR] Cannot create ",OutputBinFile," error=",GetLastError());
      return;
   }

   FileWrite(out,"Bin","BalanceFrom","BalanceTo","HealthyCount","TerminalCount",
             "Q50GapPct","Q75GapPct","Q90GapPct","Q95GapPct","Q975GapPct","Q99GapPct",
             "MaxHealthyGapPct","MinTerminalGapPct","MaxTerminalGapPct",
             "C3_Q95_EquityAtMid","C4_Q99_EquityAtMid","FallbackUsed");

   for(int b=0;b<binCount;b++)
   {
      double vals[];
      int healthy=CollectRecoveredGaps(b,BalanceBinSize,vals);
      ArraySort(vals,WHOLE_ARRAY,0,MODE_ASCEND);

      double q50=QuantileSorted(vals,0.50);
      double q75=QuantileSorted(vals,0.75);
      double q90=QuantileSorted(vals,0.90);
      double x95=QuantileSorted(vals,0.95);
      double q975=QuantileSorted(vals,0.975);
      double x99=QuantileSorted(vals,0.99);
      double maxHealthy=(healthy>0 ? vals[healthy-1] : 0.0);
      bool fallback=(healthy<MinHealthyPerBin);
      q95[b]=(fallback ? globalQ95 : x95);
      q99[b]=(fallback ? globalQ99 : x99);

      int terminals=0;
      double minTerminal=DBL_MAX;
      double maxTerminal=0.0;
      for(int i=0;i<ArraySize(Records);i++)
      {
         if(!IsTerminal(i)) continue;
         int rb=(int)MathFloor(Records[i].balance_open/BalanceBinSize);
         if(rb!=b) continue;
         terminals++;
         if(Records[i].gap_pct<minTerminal) minTerminal=Records[i].gap_pct;
         if(Records[i].gap_pct>maxTerminal) maxTerminal=Records[i].gap_pct;
      }
      if(terminals==0) minTerminal=0.0;

      double from=b*BalanceBinSize;
      double to=from+BalanceBinSize;
      double mid=(from+to)/2.0;
      double c3=mid*(1.0-q95[b]/100.0);
      double c4=mid*(1.0-q99[b]/100.0);

      FileWrite(out,b,DoubleToString(from,2),DoubleToString(to,2),healthy,terminals,
                DoubleToString(q50,4),DoubleToString(q75,4),DoubleToString(q90,4),
                DoubleToString(x95,4),DoubleToString(q975,4),DoubleToString(x99,4),
                DoubleToString(maxHealthy,4),DoubleToString(minTerminal,4),DoubleToString(maxTerminal,4),
                DoubleToString(c3,2),DoubleToString(c4,2),(fallback ? 1 : 0));
   }
   FileClose(out);
}

double TotalRecoveredProfit()
{
   double total=0.0;
   for(int i=0;i<ArraySize(Records);i++)
      if(IsRecovered(i)) total+=Records[i].basket_profit;
   return total;
}

void EvaluateCandidate(string type,double parameter,double &qBase[],int binCount,int &trueCuts,int &terminalTotal,
                       int &falseCuts,int &recoveredTotal,double &terminalCost,double &falseCost,
                       double &lostHealthyProfit,double &protectedResult)
{
   trueCuts=0;
   terminalTotal=0;
   falseCuts=0;
   recoveredTotal=0;
   terminalCost=0.0;
   falseCost=0.0;
   lostHealthyProfit=0.0;

   for(int i=0;i<ArraySize(Records);i++)
   {
      if(Records[i].status=="EXCLUDED_AFTER_CUTOFF") continue;
      bool terminal=IsTerminal(i);
      bool recovered=IsRecovered(i);
      if(!terminal && !recovered) continue;

      if(terminal) terminalTotal++;
      if(recovered) recoveredTotal++;

      double threshold=parameter;
      if(type!="GLOBAL_GAP")
      {
         int b=(int)MathFloor(Records[i].balance_open/BalanceBinSize);
         if(b<0) b=0;
         if(b>=binCount) b=binCount-1;
         threshold=qBase[b]+parameter;
      }
      if(threshold>99.9) threshold=99.9;
      if(threshold<0.0) threshold=0.0;

      if(Records[i].gap_pct+1e-9>=threshold)
      {
         double cutCost=Records[i].balance_open*threshold/100.0;
         if(terminal)
         {
            trueCuts++;
            terminalCost+=cutCost;
         }
         else
         {
            falseCuts++;
            falseCost+=cutCost;
            lostHealthyProfit+=Records[i].basket_profit;
         }
      }
   }

   protectedResult=TotalRecoveredProfit()-terminalCost-falseCost-lostHealthyProfit;
}

void WriteCandidate(int out,string type,string base,double parameter,double &qBase[],int binCount)
{
   int trueCuts,terminalTotal,falseCuts,recoveredTotal;
   double terminalCost,falseCost,lostProfit,protectedResult;
   EvaluateCandidate(type,parameter,qBase,binCount,trueCuts,terminalTotal,falseCuts,recoveredTotal,
                     terminalCost,falseCost,lostProfit,protectedResult);

   FileWrite(out,type,base,DoubleToString(parameter,4),
             trueCuts,terminalTotal,terminalTotal-trueCuts,falseCuts,recoveredTotal,
             DoubleToString(terminalCost,2),DoubleToString(falseCost,2),
             DoubleToString(lostProfit,2),DoubleToString(TotalRecoveredProfit(),2),
             DoubleToString(protectedResult,2),(trueCuts==terminalTotal ? 1 : 0));
}

void BuildCandidateSweep(double &q95[],double &q99[],int binCount)
{
   int out=FileOpen(OutputSweepFile,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(out==INVALID_HANDLE)
   {
      Print("[CONSOLIDATOR] Cannot create ",OutputSweepFile," error=",GetLastError());
      return;
   }

   FileWrite(out,"CandidateType","BaseCurve","ParameterPct","TrueTerminalCuts","TerminalTotal",
             "MissedTerminals","FalseHealthyCuts","HealthyTotal","TerminalCutCostUSD",
             "FalseCutCostUSD","LostHealthyProfitUSD","TotalHealthyProfitUSD",
             "ProtectedResultUSD","CutsAllTerminals");

   double empty[];
   ArrayResize(empty,1);
   empty[0]=0.0;

   for(double g=GlobalGapMinPct;g<=GlobalGapMaxPct+1e-9;g+=GlobalGapStepPct)
      WriteCandidate(out,"GLOBAL_GAP","NONE",g,empty,1);

   for(double m=0.0;m<=MarginMaxPct+1e-9;m+=MarginStepPct)
   {
      WriteCandidate(out,"ENVELOPE_PLUS_MARGIN","Q95",m,q95,binCount);
      WriteCandidate(out,"ENVELOPE_PLUS_MARGIN","Q99",m,q99,binCount);
   }
   FileClose(out);
}

void BuildSummary(double globalQ95,double globalQ99)
{
   int recovered=0,terminal=0,excluded=0;
   double minTerminal=DBL_MAX,maxTerminal=0.0,maxHealthy=0.0;
   int overlapHealthy=0;

   for(int i=0;i<ArraySize(Records);i++)
   {
      if(IsRecovered(i))
      {
         recovered++;
         if(Records[i].gap_pct>maxHealthy) maxHealthy=Records[i].gap_pct;
      }
      else if(IsTerminal(i))
      {
         terminal++;
         if(Records[i].gap_pct<minTerminal) minTerminal=Records[i].gap_pct;
         if(Records[i].gap_pct>maxTerminal) maxTerminal=Records[i].gap_pct;
      }
      else if(Records[i].status=="EXCLUDED_AFTER_CUTOFF") excluded++;
   }
   if(terminal==0) minTerminal=0.0;

   for(int i=0;i<ArraySize(Records);i++)
      if(IsRecovered(i) && Records[i].gap_pct>=minTerminal) overlapHealthy++;

   int out=FileOpen(OutputSummaryFile,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(out==INVALID_HANDLE)
   {
      Print("[CONSOLIDATOR] Cannot create ",OutputSummaryFile," error=",GetLastError());
      return;
   }

   FileWrite(out,"Metric","Value");
   FileWrite(out,"OfficialFilesExpected",28);
   FileWrite(out,"BasketRecords",ArraySize(Records));
   FileWrite(out,"RecoveredBaskets",recovered);
   FileWrite(out,"TerminalBaskets",terminal);
   FileWrite(out,"ExcludedAfterCutoff",excluded);
   FileWrite(out,"TotalRecoveredProfitUSD",DoubleToString(TotalRecoveredProfit(),2));
   FileWrite(out,"GlobalHealthyQ95GapPct",DoubleToString(globalQ95,4));
   FileWrite(out,"GlobalHealthyQ99GapPct",DoubleToString(globalQ99,4));
   FileWrite(out,"MaximumRecoveredGapPct",DoubleToString(maxHealthy,4));
   FileWrite(out,"MinimumTerminalGapPct",DoubleToString(minTerminal,4));
   FileWrite(out,"MaximumTerminalGapPct",DoubleToString(maxTerminal,4));
   FileWrite(out,"RecoveredBasketsDeeperThanMinimumTerminal",overlapHealthy);
   FileWrite(out,"StaticGapSeparationPossible",(overlapHealthy==0 ? "YES" : "NO"));
   FileClose(out);
}

int OnInit()
{
   ArrayResize(Records,0);
   BasketOut=FileOpen(OutputBasketFile,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(BasketOut==INVALID_HANDLE)
   {
      Print("[CONSOLIDATOR] Cannot create ",OutputBasketFile," error=",GetLastError());
      return(INIT_FAILED);
   }

   FileWrite(BasketOut,"Segment","SourceNumber","SourceFile","BasketID","Status","Direction",
             "OpenTime","CloseTime","BalanceOpen","EquityMinimum","DepthUSD","GapPct",
             "MaxOrders","MaxLots","BalanceClose","BasketProfit","FinalRowStatus","DeinitReason");

   int processed=0;
   for(int i=0;i<ArraySize(OfficialFileNumbers);i++)
      if(ProcessCollectorFile(i+1,OfficialFileNumbers[i])) processed++;

   FileClose(BasketOut);
   BasketOut=INVALID_HANDLE;

   double q95[],q99[];
   int binCount=0;
   double globalQ95=0.0,globalQ99=0.0;
   BuildEnvelopeBins(q95,q99,binCount,globalQ95,globalQ99);
   BuildCandidateSweep(q95,q99,binCount);
   BuildSummary(globalQ95,globalQ99);

   Print("[CONSOLIDATOR] Finished. Files processed=",processed,
         " baskets=",ArraySize(Records),
         " outputs: ",OutputBasketFile,", ",OutputBinFile,", ",OutputSweepFile,", ",OutputSummaryFile);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {}
void OnTick() {}
//+------------------------------------------------------------------+
