-- ============================================================
-- TRADING COMPANY REVENUE INVESTIGATION QUERIES
-- Database: Zoho Analytics (ZQL)
-- Tables: Ledger (new panel), Old_Ledger (old panel), Client
-- Key Columns: ClientID, LedgerType, Credit, Debit, CreatedAt
-- Client Link: Client.OldAccountID <-> Client.AccountID
-- ============================================================


-- ============================================================
-- REPORT 1: MIGRATION STATUS PER CLIENT
-- Who has fully migrated, who is dual-active, who is a ghost?
-- ============================================================

SELECT
    c."AccountID"                                           AS NewPanelID,
    c."OldAccountID"                                        AS OldPanelID,

    -- Activity on Old Panel
    COUNT(DISTINCT ol."ClientID")                           AS HasOldActivity,
    MAX(ol."CreatedAt")                                     AS LastOldPanelActivity,
    SUM(IFNULL(ol."Credit", 0))                             AS TotalOldCredit,
    SUM(IFNULL(ol."Debit", 0))                              AS TotalOldDebit,

    -- Activity on New Panel
    COUNT(DISTINCT l."ClientID")                            AS HasNewActivity,
    MAX(l."CreatedAt")                                      AS LastNewPanelActivity,
    SUM(IFNULL(l."Credit", 0))                              AS TotalNewCredit,
    SUM(IFNULL(l."Debit", 0))                              AS TotalNewDebit,

    -- Migration Status Label
    CASE
        WHEN MAX(l."CreatedAt") IS NULL
            THEN 'GHOST - Never Traded on New Panel'
        WHEN MAX(ol."CreatedAt") > DATEADD(DAY, -30, NOW())
         AND MAX(l."CreatedAt")  > DATEADD(DAY, -30, NOW())
            THEN 'DUAL ACTIVE - Trading on Both'
        WHEN MAX(ol."CreatedAt") > DATEADD(DAY, -30, NOW())
         AND MAX(l."CreatedAt")  < DATEADD(DAY, -30, NOW())
            THEN 'STUCK ON OLD PANEL'
        ELSE 'MIGRATED'
    END                                                     AS MigrationStatus

FROM "Client" c
LEFT JOIN "Old_Ledger" ol ON ol."ClientID" = c."OldAccountID"
LEFT JOIN "Ledger"     l  ON l."ClientID"  = c."AccountID"

GROUP BY c."AccountID", c."OldAccountID"
ORDER BY MigrationStatus, TotalOldCredit DESC;


-- ============================================================
-- REPORT 2: DEPOSIT FUNNEL COMPARISON - OLD vs NEW PANEL
-- Monthly deposit count and value per panel
-- ============================================================

SELECT
    Month,
    Panel,
    COUNT(DISTINCT ClientID)    AS UniqueDepositingClients,
    COUNT(*)                    AS TotalDepositCount,
    SUM(Credit)                 AS TotalDepositValue,
    AVG(Credit)                 AS AvgDepositSize

FROM (

    -- New Panel Deposits
    SELECT
        YEAR(l."CreatedAt") * 100 + MONTH(l."CreatedAt")   AS Month,
        'NEW PANEL'                                         AS Panel,
        l."ClientID"                                        AS ClientID,
        l."Credit"                                          AS Credit
    FROM "Ledger" l
    WHERE l."LedgerType" = 'Deposit'
      AND l."Credit" > 0

    UNION ALL

    -- Old Panel Deposits
    SELECT
        YEAR(ol."CreatedAt") * 100 + MONTH(ol."CreatedAt") AS Month,
        'OLD PANEL'                                         AS Panel,
        ol."ClientID"                                       AS ClientID,
        ol."Credit"                                         AS Credit
    FROM "Old_Ledger" ol
    WHERE ol."LedgerType" = 'Deposit'
      AND ol."Credit" > 0

) combined

GROUP BY Month, Panel
ORDER BY Month DESC, Panel;


-- ============================================================
-- REPORT 3: DUAL PANEL ACTIVITY LEAK
-- Clients active on both panels - where is their volume going?
-- ============================================================

SELECT
    c."AccountID"                                           AS NewPanelID,
    c."OldAccountID"                                        AS OldPanelID,

    -- Old Panel Bill (Trade) Volume last 90 days
    SUM(CASE WHEN ol."LedgerType" = 'Bill'
              AND ol."CreatedAt" >= DATEADD(DAY, -90, NOW())
             THEN IFNULL(ol."Credit", 0) + IFNULL(ol."Debit", 0) ELSE 0 END)
                                                            AS OldPanel_TradeVolume_90d,

    -- New Panel Bill (Trade) Volume last 90 days
    SUM(CASE WHEN l."LedgerType" = 'Bill'
              AND l."CreatedAt"  >= DATEADD(DAY, -90, NOW())
             THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END)
                                                            AS NewPanel_TradeVolume_90d,

    -- % of volume still on old panel
    ROUND(
        SUM(CASE WHEN ol."LedgerType" = 'Bill'
                  AND ol."CreatedAt" >= DATEADD(DAY, -90, NOW())
                 THEN IFNULL(ol."Credit", 0) + IFNULL(ol."Debit", 0) ELSE 0 END)
        /
        NULLIF(
            SUM(CASE WHEN ol."LedgerType" = 'Bill'
                      AND ol."CreatedAt" >= DATEADD(DAY, -90, NOW())
                     THEN IFNULL(ol."Credit", 0) + IFNULL(ol."Debit", 0) ELSE 0 END)
            +
            SUM(CASE WHEN l."LedgerType" = 'Bill'
                      AND l."CreatedAt"  >= DATEADD(DAY, -90, NOW())
                     THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END)
        , 0) * 100
    , 2)                                                    AS PctVolumeStillOnOldPanel

FROM "Client" c
JOIN "Old_Ledger" ol ON ol."ClientID" = c."OldAccountID"
JOIN "Ledger"     l  ON l."ClientID"  = c."AccountID"

GROUP BY c."AccountID", c."OldAccountID"
HAVING OldPanel_TradeVolume_90d > 0
   AND NewPanel_TradeVolume_90d > 0

ORDER BY OldPanel_TradeVolume_90d DESC;


-- ============================================================
-- REPORT 4: TRADE (BILL) VOLUME MIGRATION REPORT
-- Did trade volume actually move to the new panel?
-- ============================================================

SELECT
    c."AccountID"                                           AS NewPanelID,
    c."OldAccountID"                                        AS OldPanelID,

    -- Old Panel: avg monthly bill volume (last 6 months before migration push)
    SUM(CASE WHEN ol."LedgerType" = 'Bill'
             THEN IFNULL(ol."Credit", 0) + IFNULL(ol."Debit", 0) ELSE 0 END)
                                                            AS OldPanel_TotalBillVolume,

    -- New Panel: total bill volume since account created
    SUM(CASE WHEN l."LedgerType" = 'Bill'
             THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END)
                                                            AS NewPanel_TotalBillVolume,

    -- Volume drop/gain
    SUM(CASE WHEN l."LedgerType" = 'Bill'
             THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END)
    -
    SUM(CASE WHEN ol."LedgerType" = 'Bill'
             THEN IFNULL(ol."Credit", 0) + IFNULL(ol."Debit", 0) ELSE 0 END)
                                                            AS VolumeDelta,

    CASE
        WHEN SUM(CASE WHEN l."LedgerType" = 'Bill'
                      THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END) = 0
            THEN 'NO TRADES ON NEW PANEL'
        WHEN SUM(CASE WHEN l."LedgerType" = 'Bill'
                      THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END)
             <
             SUM(CASE WHEN ol."LedgerType" = 'Bill'
                      THEN IFNULL(ol."Credit", 0) + IFNULL(ol."Debit", 0) ELSE 0 END) * 0.7
            THEN 'SIGNIFICANT DROP (>30%)'
        WHEN SUM(CASE WHEN l."LedgerType" = 'Bill'
                      THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END)
             <
             SUM(CASE WHEN ol."LedgerType" = 'Bill'
                      THEN IFNULL(ol."Credit", 0) + IFNULL(ol."Debit", 0) ELSE 0 END)
            THEN 'MILD DROP'
        ELSE 'MAINTAINED OR GREW'
    END                                                     AS VolumeStatus

FROM "Client" c
LEFT JOIN "Old_Ledger" ol ON ol."ClientID" = c."OldAccountID"
LEFT JOIN "Ledger"     l  ON l."ClientID"  = c."AccountID"

GROUP BY c."AccountID", c."OldAccountID"
ORDER BY VolumeDelta ASC;


-- ============================================================
-- REPORT 5: DEPOSIT-THEN-WITHDRAW (NO TRADE) DETECTION
-- Clients who funded new panel but never traded — then left
-- ============================================================

SELECT
    l."ClientID"                                            AS NewPanelClientID,
    c."OldAccountID"                                        AS OldPanelClientID,

    SUM(CASE WHEN l."LedgerType" = 'Deposit'  THEN IFNULL(l."Credit", 0) ELSE 0 END)
                                                            AS TotalDeposited,
    SUM(CASE WHEN l."LedgerType" = 'Withdraw' THEN IFNULL(l."Debit", 0)  ELSE 0 END)
                                                            AS TotalWithdrawn,
    SUM(CASE WHEN l."LedgerType" = 'Bill'
             THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END)
                                                            AS TotalTradeVolume,

    MIN(CASE WHEN l."LedgerType" = 'Deposit'  THEN l."CreatedAt" END)
                                                            AS FirstDepositDate,
    MAX(CASE WHEN l."LedgerType" = 'Withdraw' THEN l."CreatedAt" END)
                                                            AS LastWithdrawDate,

    CASE
        WHEN SUM(CASE WHEN l."LedgerType" = 'Bill'
                      THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END) = 0
            THEN 'DEPOSITED BUT NEVER TRADED'
        ELSE 'TRADED'
    END                                                     AS ClientBehavior

FROM "Ledger" l
LEFT JOIN "Client" c ON c."AccountID" = l."ClientID"

GROUP BY l."ClientID", c."OldAccountID"
HAVING TotalDeposited > 0
   AND TotalTradeVolume = 0

ORDER BY TotalDeposited DESC;


-- ============================================================
-- REPORT 6: WITHDRAW CANCELLED ANALYSIS
-- Failed withdrawals — trust signal or back-office failure?
-- ============================================================

SELECT
    l."ClientID"                                            AS NewPanelClientID,
    COUNT(CASE WHEN l."LedgerType" = 'Withdraw Cancelled'  THEN 1 END)
                                                            AS CancelledWithdrawCount,
    SUM(CASE WHEN l."LedgerType" = 'Withdraw Cancelled'    THEN IFNULL(l."Credit", 0) ELSE 0 END)
                                                            AS CancelledWithdrawValue,
    COUNT(CASE WHEN l."LedgerType" = 'Withdraw'            THEN 1 END)
                                                            AS SuccessfulWithdrawCount,
    SUM(CASE WHEN l."LedgerType" = 'Withdraw'              THEN IFNULL(l."Debit", 0) ELSE 0 END)
                                                            AS SuccessfulWithdrawValue,

    -- Did they trade after the cancellation?
    MAX(CASE WHEN l."LedgerType" = 'Bill'                  THEN l."CreatedAt" END)
                                                            AS LastTradeDate,
    MAX(CASE WHEN l."LedgerType" = 'Withdraw Cancelled'    THEN l."CreatedAt" END)
                                                            AS LastCancelDate,

    CASE
        WHEN MAX(CASE WHEN l."LedgerType" = 'Bill' THEN l."CreatedAt" END)
             > MAX(CASE WHEN l."LedgerType" = 'Withdraw Cancelled' THEN l."CreatedAt" END)
            THEN 'RETAINED - Traded After Cancel'
        ELSE 'AT RISK - No Trade After Cancel'
    END                                                     AS RetentionStatus

FROM "Ledger" l
WHERE l."LedgerType" IN ('Withdraw Cancelled', 'Withdraw', 'Bill')
GROUP BY l."ClientID"
HAVING CancelledWithdrawCount > 0
ORDER BY CancelledWithdrawCount DESC;


-- ============================================================
-- REPORT 7: ZERO ACTIVITY ACCOUNTS ON NEW PANEL
-- Registered but completely idle — the silent leakers
-- ============================================================

SELECT
    c."AccountID"                                           AS NewPanelID,
    c."OldAccountID"                                        AS OldPanelID,
    MAX(ol."CreatedAt")                                     AS LastOldPanelActivity,
    MAX(ol."LedgerType")                                    AS LastOldPanelActivityType,
    SUM(IFNULL(ol."Credit", 0))                             AS OldPanel_TotalCredit,
    SUM(IFNULL(ol."Debit", 0))                              AS OldPanel_TotalDebit,

    DATEDIFF(NOW(), MAX(ol."CreatedAt"))                    AS DaysSinceLastActivity

FROM "Client" c
LEFT JOIN "Ledger"     l  ON l."ClientID"  = c."AccountID"
LEFT JOIN "Old_Ledger" ol ON ol."ClientID" = c."OldAccountID"

WHERE l."ClientID" IS NULL   -- No entries at all on new panel

GROUP BY c."AccountID", c."OldAccountID"
ORDER BY OldPanel_TotalCredit DESC;


-- ============================================================
-- REPORT 8: MONTHLY COHORT REVENUE REPORT
-- Revenue per client cohort month-over-month after migration
-- ============================================================

SELECT
    CohortMonth,
    MonthsAfterMigration,
    COUNT(DISTINCT ClientID)                                AS ActiveClients,
    SUM(NetCredit)                                          AS CohortNetRevenue,
    AVG(NetCredit)                                          AS AvgRevenuePerClient

FROM (
    SELECT
        l."ClientID"                                        AS ClientID,
        YEAR(first_activity."FirstDate") * 100
            + MONTH(first_activity."FirstDate")             AS CohortMonth,
        TIMESTAMPDIFF(
            MONTH,
            first_activity."FirstDate",
            l."CreatedAt"
        )                                                   AS MonthsAfterMigration,
        IFNULL(l."Credit", 0) - IFNULL(l."Debit", 0)       AS NetCredit

    FROM "Ledger" l
    JOIN (
        SELECT
            "ClientID",
            MIN("CreatedAt")                                AS FirstDate
        FROM "Ledger"
        GROUP BY "ClientID"
    ) first_activity ON first_activity."ClientID" = l."ClientID"

) cohort_data

GROUP BY CohortMonth, MonthsAfterMigration
ORDER BY CohortMonth, MonthsAfterMigration;


-- ============================================================
-- REPORT 9: NET REVENUE BRIDGE — THE SUMMARY
-- Categorize every client's revenue impact in one table
-- ============================================================

SELECT
    BucketLabel,
    COUNT(DISTINCT NewPanelID)                              AS ClientCount,
    SUM(OldPanelRevenue)                                    AS OldPanelRevenue,
    SUM(NewPanelRevenue)                                    AS NewPanelRevenue,
    SUM(NewPanelRevenue) - SUM(OldPanelRevenue)             AS RevenueDelta

FROM (
    SELECT
        c."AccountID"                                       AS NewPanelID,
        c."OldAccountID"                                    AS OldPanelID,

        SUM(IFNULL(ol."Credit", 0) - IFNULL(ol."Debit", 0))
                                                            AS OldPanelRevenue,
        SUM(IFNULL(l."Credit", 0)  - IFNULL(l."Debit", 0))
                                                            AS NewPanelRevenue,

        CASE
            WHEN SUM(IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0)) = 0
                THEN 'BUCKET 1: Ghost — Never Active on New Panel'

            WHEN MAX(ol."CreatedAt") > DATEADD(DAY, -30, NOW())
             AND MAX(l."CreatedAt")  > DATEADD(DAY, -30, NOW())
                THEN 'BUCKET 2: Dual Active — Volume Split Across Panels'

            WHEN SUM(CASE WHEN l."LedgerType" = 'Bill'
                          THEN IFNULL(l."Credit", 0) + IFNULL(l."Debit", 0) ELSE 0 END) = 0
              AND SUM(CASE WHEN l."LedgerType" = 'Deposit'
                           THEN IFNULL(l."Credit", 0) ELSE 0 END) > 0
                THEN 'BUCKET 3: Deposited But Never Traded'

            WHEN SUM(IFNULL(l."Credit", 0) - IFNULL(l."Debit", 0))
                 < SUM(IFNULL(ol."Credit", 0) - IFNULL(ol."Debit", 0)) * 0.7
                THEN 'BUCKET 4: Migrated But Revenue Dropped >30%'

            ELSE 'BUCKET 5: Healthy Migration — Revenue Maintained'
        END                                                 AS BucketLabel

    FROM "Client" c
    LEFT JOIN "Old_Ledger" ol ON ol."ClientID" = c."OldAccountID"
    LEFT JOIN "Ledger"     l  ON l."ClientID"  = c."AccountID"
    GROUP BY c."AccountID", c."OldAccountID"

) bucketed

GROUP BY BucketLabel
ORDER BY BucketLabel;


-- ============================================================
-- REPORT 10: NBP & MTM RISK MONITOR
-- Are new panel clients over-leveraging or missing MTM data?
-- ============================================================

SELECT
    l."ClientID"                                            AS NewPanelClientID,
    COUNT(CASE WHEN l."LedgerType" = 'Negative Balance Protection' THEN 1 END)
                                                            AS NBP_EventCount,
    SUM(CASE WHEN l."LedgerType" = 'Negative Balance Protection'
             THEN IFNULL(l."Credit", 0) ELSE 0 END)         AS NBP_TotalValue,
    COUNT(CASE WHEN l."LedgerType" = 'MTM Update'          THEN 1 END)
                                                            AS MTM_UpdateCount,
    MIN(CASE WHEN l."LedgerType" = 'MTM Update'            THEN l."CreatedAt" END)
                                                            AS FirstMTMDate,
    MAX(CASE WHEN l."LedgerType" = 'MTM Update'            THEN l."CreatedAt" END)
                                                            AS LastMTMDate,
    DATEDIFF(NOW(), MAX(CASE WHEN l."LedgerType" = 'MTM Update'
                             THEN l."CreatedAt" END))       AS DaysSinceLastMTM,

    CASE
        WHEN COUNT(CASE WHEN l."LedgerType" = 'Negative Balance Protection' THEN 1 END) > 3
            THEN 'HIGH RISK - Frequent NBP'
        WHEN DATEDIFF(NOW(), MAX(CASE WHEN l."LedgerType" = 'MTM Update'
                                      THEN l."CreatedAt" END)) > 7
            THEN 'DATA GAP - MTM Stale > 7 Days'
        ELSE 'NORMAL'
    END                                                     AS RiskFlag

FROM "Ledger" l
GROUP BY l."ClientID"
HAVING NBP_EventCount > 0
    OR DaysSinceLastMTM > 7
ORDER BY NBP_EventCount DESC, DaysSinceLastMTM DESC;
