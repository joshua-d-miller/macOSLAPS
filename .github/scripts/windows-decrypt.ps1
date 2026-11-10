# Opens the CMS escrow produced on the Mac with the tool Windows admins already have.
# Run from the directory that holds cms/ (identity.pfx, escrow.txt, expected.txt).
$ErrorActionPreference = 'Stop'
Import-PfxCertificate -FilePath cms/identity.pfx -CertStoreLocation Cert:\CurrentUser\My `
  -Password (ConvertTo-SecureString 'ci' -AsPlainText -Force) | Out-Null
$expected = (Get-Content cms/expected.txt -Raw).Trim()
$plain = Unprotect-CmsMessage -Path cms/escrow.txt
if (($plain | ConvertFrom-Json).password -ne $expected) { throw "Decrypted escrow does not match" }
Write-Host "PASS: Unprotect-CmsMessage -Path decrypts the escrow ($($PSVersionTable.PSVersion))"
# MDM inventory fields often flatten line breaks. Report whether those forms still open.
$lines = Get-Content cms/escrow.txt
foreach ($form in @{ name = 'spaces instead of line breaks'; text = ($lines -join ' ') },
                   @{ name = 'no line breaks'; text = ($lines -join '') }) {
  try {
    $p = Unprotect-CmsMessage -Content $form.text
    if (($p | ConvertFrom-Json).password -eq $expected) { Write-Host "PASS: decrypts with $($form.name)" }
    else { Write-Host "::warning::Unprotect-CmsMessage with $($form.name): wrong content" }
  } catch { Write-Host "::warning::Unprotect-CmsMessage does not accept the escrow with $($form.name): $_" }
}
