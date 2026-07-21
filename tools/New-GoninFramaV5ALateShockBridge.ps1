[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$OutputPath = "GONIN_FRAMA_V5A_LATE_SHOCK_BRIDGE.mq4"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Replace-ExactlyOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Old,
        [Parameter(Mandatory = $true)][string]$New,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $first = $Text.IndexOf($Old, [System.StringComparison]::Ordinal)
    if ($first -lt 0) {
        throw "Anchor not found: $Label"
    }

    $second = $Text.IndexOf($Old, $first + $Old.Length, [System.StringComparison]::Ordinal)
    if ($second -ge 0) {
        throw "Anchor is not unique: $Label"
    }

    return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Text.IndexOf($Needle, [System.StringComparison]::Ordinal) -lt 0) {
        throw "Required V5 trunk marker not found: $Label"
    }
}

$source = (Resolve-Path -LiteralPath $SourcePath).Path
$bytes = [System.IO.File]::ReadAllBytes($source)

# Strict UTF-8 first. Fall back to Windows-1252 only when the source is not valid UTF-8.
$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
try {
    $text = $utf8Strict.GetString($bytes)
}
catch {
    $text = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)
}

# Normalize internally. The generated MQ4 is written as CRLF UTF-8 without BOM.
$text = $text.Replace("`r`n", "`n").Replace("`r", "`n")

Assert-Contains $text '#property version   "5.05"' "approved version 5.05"
Assert-Contains $text 'input string MC_FilePrefix                      = "GONIN_FRAMA_V5_LATCHED_TRIGGER_TURBO_V5";' "approved V5 CSV prefix"
Assert-Contains $text 'input int    RPT_MagicNumber                     = 60606;' "real Turbo Magic 60606"
Assert-Contains $text '// V5 LATCHED TRIGGER:' "V5 Latched Trigger"

$text = Replace-ExactlyOnce $text @'
//| GONIN_FRAMA_HEDGE_RECOVERY_MULTICYCLE_V5_LATCHED_TRIGGER_TURBO_V5.mq4       |
//| V5 universal cycle gate + conservative real progressive Turbo.              |
//| V5 latches every qualified basket trigger until closure or recovery cycle.  |
'@ @'
//| GONIN_FRAMA_V5A_LATE_SHOCK_BRIDGE.mq4                                       |
//| Approved V5 trunk + surgical late-shock admission bridge.                    |
//| Normal V5 behavior is preserved; only late 15-18 order shocks are bridged.   |
'@ "file header"

$text = Replace-ExactlyOnce $text '#property version   "5.05"' '#property version   "5.07"' "version"
$text = Replace-ExactlyOnce $text @'
#property description "V5 Latched Trigger Turbo V5 preserves a qualified basket candidate through temporary recovery, requires the live loss trigger again before hedge authorization, and keeps the conservative real progressive Turbo."
'@ @'
#property description "V5A Late Shock Bridge preserves the approved V5 behavior and admits only 15-18 order baskets that reach the late-shock loss threshold, blocking further additions while keeping natural closure available."
'@ "description"

$text = Replace-ExactlyOnce $text @'
input bool   SAR_RejectMatureMaxOrderBaskets      = true;

//====================================================================
'@ @'
input bool   SAR_RejectMatureMaxOrderBaskets      = true;

// V5A LATE SHOCK BRIDGE — surgical admission only after the normal V5 window.
// It does not alter healthy early candidates, Worker 50503, Turbo 60606 or settlement.
input bool   SAR_LateShockBridgeEnable            = true;
input int    SAR_LateShockMinOrders               = 15;
input int    SAR_LateShockMaxOrders               = 18;
input double SAR_LateShockMinLossMoney            = 75.00;
input bool   SAR_LateShockRequirePauseQualification = true;
input bool   SAR_LateShockBlockAdditions          = true;

//====================================================================
'@ "late-shock inputs"

$text = Replace-ExactlyOnce $text @'
input string MC_FilePrefix                      = "GONIN_FRAMA_V5_LATCHED_TRIGGER_TURBO_V5";
'@ @'
input string MC_FilePrefix                      = "GONIN_FRAMA_V5A_LATE_SHOCK_BRIDGE";
'@ "CSV prefix"

$text = Replace-ExactlyOnce $text @'
bool     SAR_PauseQualifiedAtCandidate      = false;
int      SAR_CandidateBasketID             = 0;
'@ @'
bool     SAR_PauseQualifiedAtCandidate      = false;
bool     SAR_LateShockCandidate             = false;
int      SAR_CandidateBasketID             = 0;
'@ "late-shock state"

$text = Replace-ExactlyOnce $text @'
    SAR_CandidateActive = false;
    if(clearAuthorization) SAR_HedgeAuthorized = false;
    SAR_PauseQualifiedAtCandidate = false;
    SAR_CandidateBasketID = 0;
'@ @'
    SAR_CandidateActive = false;
    if(clearAuthorization) SAR_HedgeAuthorized = false;
    SAR_PauseQualifiedAtCandidate = false;
    SAR_LateShockCandidate = false;
    SAR_CandidateBasketID = 0;
'@ "candidate reset"

$text = Replace-ExactlyOnce $text @'
void SAR_StartCandidate(int direction, int orders, double lots, double floating)
{
    SAR_CandidateActive = true;
    SAR_HedgeAuthorized = false;
    // The candidate can only be born after the selective-pause gate is
    // active or armed. Preserve that qualification while the same basket
    // continues adding orders and wait only for its final structural stall.
    SAR_PauseQualifiedAtCandidate =
       (!SAR_RequireRealSelectivePause || SP_Active || SP_Armed);
    SAR_CandidateBasketID = RTO_BasketID;
    SAR_CandidateDirection = direction;
    SAR_OrdersAtCandidate = orders;
    SAR_LastObservedOrders = orders;
    SAR_LotsAtCandidate = lots;
    SAR_FloatingAtCandidate = floating;
    SAR_WorstFloating = floating;
    SAR_CandidateTime = TimeCurrent();
    SAR_LastOrderGrowthTime = TimeCurrent();
    SAR_AuthorizationTime = 0;
    SAR_LastSnapshotBar = 0;
    SAR_Write("ACCIDENT_CANDIDATE_STARTED",
              "LOSS_WARNING_PLUS_REAL_PAUSE_EARLY_STALL_OBSERVATION");
    MC_Write("ACCIDENT_CANDIDATE_STARTED",
             "LOSS_WARNING_ONLY_WAITING_STRUCTURAL_CONFIRMATION");
}
'@ @'
void SAR_StartCandidate(int direction, int orders, double lots, double floating,
                        bool lateShock)
{
    SAR_CandidateActive = true;
    SAR_HedgeAuthorized = false;
    SAR_LateShockCandidate = lateShock;

    // Preserve the qualification that admitted this exact basket class.
    if(lateShock)
       SAR_PauseQualifiedAtCandidate =
          (!SAR_LateShockRequirePauseQualification || SP_Active || SP_Armed);
    else
       SAR_PauseQualifiedAtCandidate =
          (!SAR_RequireRealSelectivePause || SP_Active || SP_Armed);

    SAR_CandidateBasketID = RTO_BasketID;
    SAR_CandidateDirection = direction;
    SAR_OrdersAtCandidate = orders;
    SAR_LastObservedOrders = orders;
    SAR_LotsAtCandidate = lots;
    SAR_FloatingAtCandidate = floating;
    SAR_WorstFloating = floating;
    SAR_CandidateTime = TimeCurrent();
    SAR_LastOrderGrowthTime = TimeCurrent();
    SAR_AuthorizationTime = 0;
    SAR_LastSnapshotBar = 0;

    if(lateShock)
    {
       SAR_Write("LATE_SHOCK_CANDIDATE_STARTED",
                 "V5A_15_18_ORDER_BRIDGE_LOSS_AND_PAUSE_QUALIFIED");
       MC_Write("LATE_SHOCK_CANDIDATE_STARTED",
                "BLOCKING_ONLY_FURTHER_BASE_ADDITIONS_WAITING_STALL");
    }
    else
    {
       SAR_Write("ACCIDENT_CANDIDATE_STARTED",
                 "LOSS_WARNING_PLUS_REAL_PAUSE_EARLY_STALL_OBSERVATION");
       MC_Write("ACCIDENT_CANDIDATE_STARTED",
                "LOSS_WARNING_ONLY_WAITING_STRUCTURAL_CONFIRMATION");
    }
}
'@ "candidate start function"

$text = Replace-ExactlyOnce $text @'
    SAR_CandidateActive = false;
    SAR_HedgeAuthorized = false;
    SAR_PauseQualifiedAtCandidate = false;
    SAR_LastResetReason = "HEDGE_OPENED";
}

//+------------------------------------------------------------------+
void SAR_OnTick()
'@ @'
    SAR_CandidateActive = false;
    SAR_HedgeAuthorized = false;
    SAR_PauseQualifiedAtCandidate = false;
    SAR_LateShockCandidate = false;
    SAR_LastResetReason = "HEDGE_OPENED";
}

//+------------------------------------------------------------------+
bool SAR_BlockBaseAdditionNow(int orderType)
{
    if(!SAR_Enable || !SAR_LateShockBridgeEnable ||
       !SAR_LateShockBlockAdditions) return(false);
    if(!SAR_CandidateActive || !SAR_LateShockCandidate) return(false);
    if(orderType != SAR_CandidateDirection) return(false);
    if(SAR_CandidateBasketID != RTO_BasketID) return(false);
    return(CountOrders(orderType) > 0);
}

//+------------------------------------------------------------------+
void SAR_OnTick()
'@ "hedge consumption and addition-block helper"

$text = Replace-ExactlyOnce $text @'
       bool pauseOK = (!SAR_RequireRealSelectivePause ||
                       SAR_PauseQualifiedAtCandidate ||
                       SP_Active || SP_Armed);
'@ @'
       bool pauseOK = (SAR_LateShockCandidate
          ? (!SAR_LateShockRequirePauseQualification ||
             SAR_PauseQualifiedAtCandidate || SP_Active || SP_Armed)
          : (!SAR_RequireRealSelectivePause ||
             SAR_PauseQualifiedAtCandidate || SP_Active || SP_Armed));
'@ "class-specific pause qualification"

$text = Replace-ExactlyOnce $text @'
       bool earlyStall = (SAR_OrdersAtCandidate <= MathMax(1, SAR_MaxOrdersForEarlyStall));
       bool matureRejected = false;
'@ @'
       bool earlyStall = (SAR_OrdersAtCandidate <= MathMax(1, SAR_MaxOrdersForEarlyStall));
       bool admissionClassOK = (earlyStall || SAR_LateShockCandidate);
       bool matureRejected = false;
'@ "admission class"

$text = Replace-ExactlyOnce $text @'
       if(!SAR_HedgeAuthorized && pauseOK && earlyStall && !matureRejected &&
'@ @'
       if(!SAR_HedgeAuthorized && pauseOK && admissionClassOK && !matureRejected &&
'@ "authorization class gate"

$text = Replace-ExactlyOnce $text @'
       if(warningHit && pauseCandidateOK && earlyStall && !matureRejected)
          SAR_StartCandidate(direction, orders, lots, floating);
'@ @'
       if(warningHit && pauseCandidateOK && earlyStall && !matureRejected)
       {
          SAR_StartCandidate(direction, orders, lots, floating, false);
       }
       else
       {
          int lateMinOrders = MathMax(SAR_MaxOrdersForEarlyStall + 1,
                                      SAR_LateShockMinOrders);
          int lateMaxOrders = MathMax(lateMinOrders, SAR_LateShockMaxOrders);
          bool lateShockOrders = (orders >= lateMinOrders && orders <= lateMaxOrders);
          bool lateShockLoss =
             (floating <= -MathAbs(SAR_LateShockMinLossMoney));
          bool lateShockPauseOK =
             (!SAR_LateShockRequirePauseQualification || SP_Active || SP_Armed);

          if(SAR_LateShockBridgeEnable && lateShockOrders && lateShockLoss &&
             lateShockPauseOK && !matureRejected)
          {
             SAR_StartCandidate(direction, orders, lots, floating, true);
          }
       }
'@ "late-shock admission"

$text = Replace-ExactlyOnce $text @'
void OpenOneOrderForCurrentBar(int orderType, bool force=false)
{
    if(PHF_BlockFreshBasketNow())
       return;

    datetime barTime = iTime(Symbol(), PERIOD_M5, 0);
'@ @'
void OpenOneOrderForCurrentBar(int orderType, bool force=false)
{
    if(PHF_BlockFreshBasketNow())
       return;

    // V5A acts only on the already admitted late-shock basket. Natural basket
    // closure is outside this function and remains fully available.
    if(SAR_BlockBaseAdditionNow(orderType))
    {
       if(PrintDebug)
          Print("V5A Late Shock Bridge: additional base order blocked. Type=",
                orderType, " Orders=", CountOrders(orderType),
                " Floating=", DoubleToString(BasketProfit(orderType), 2));
       return;
    }

    datetime barTime = iTime(Symbol(), PERIOD_M5, 0);
'@ "base addition block"

# Final structural checks.
Assert-Contains $text 'input string MC_FilePrefix                      = "GONIN_FRAMA_V5A_LATE_SHOCK_BRIDGE";' "V5A CSV prefix"
Assert-Contains $text 'bool     SAR_LateShockCandidate             = false;' "V5A state"
Assert-Contains $text 'bool SAR_BlockBaseAdditionNow(int orderType)' "V5A addition block"
Assert-Contains $text 'SAR_StartCandidate(direction, orders, lots, floating, true);' "V5A admission"
Assert-Contains $text 'input int    RPT_MagicNumber                     = 60606;' "Turbo unchanged"

$openBraces = ([regex]::Matches($text, '\{')).Count
$closeBraces = ([regex]::Matches($text, '\}')).Count
if ($openBraces -ne $closeBraces) {
    throw "Brace mismatch after patch: open=$openBraces close=$closeBraces"
}

$outputFullPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($outputFullPath)
if ($outputDirectory -and -not [System.IO.Directory]::Exists($outputDirectory)) {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$text = $text.Replace("`n", "`r`n")
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($outputFullPath, $text, $utf8NoBom)

$hash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash
Write-Host "V5A generated successfully."
Write-Host "Source : $source"
Write-Host "Output : $outputFullPath"
Write-Host "SHA256 : $hash"
Write-Host "Next test: EURUSD M5, every tick, spread 2, April 2021."
