@{
    # Local copy only: .local/config/budget.psd1
    Enabled = $false
    MonthlyAmount = 0 # Choose your warning budget, not a spending limit.
    ExpectedCurrency = 'EUR'
    CurrencyReviewed = $false # Confirm subscription-scope currency in Cost Management.
    EmailReceivers = @()
    ActualPercent = @(50, 80, 100)
    ForecastPercent = @(100)
    StartDate = 'REPLACE-first-day-of-current-month'
    EndDate = 'REPLACE-expiration-date'
}
