# Copy to .local/acceptance.ps1; run only through Test-Lab.ps1.
# This is guided HUMAN acceptance, not an automated browser test.
param([Parameter(Mandatory)]$Configuration)
$ErrorActionPreference='Stop'
Write-Host ('Open https://'+$Configuration.AppHost+' in a private browser session.')
$questions=[ordered]@{
 Login='Did a valid test account complete sign-in and reach the application?'
 MfaRequired='Did a fresh account have to enroll OTP, and was missing/incorrect OTP rejected?'
 UnauthorizedRoleDenied='Was an authenticated account WITHOUT the allowed role denied access?'
 SqlApplicationConnection='Did the application connect to SQL using its real account with certificate validation?'
 ApplicationWorkflow='Did a representative read/write/image workflow complete and persist correctly?'
}
$result=@{}
foreach ($key in $questions.Keys) {
 $answer=Read-Host ($questions[$key]+' Type PASS only after testing')
 $result[$key]=($answer -ceq 'PASS')
}
return $result
