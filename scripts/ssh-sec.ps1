# ssh-sec.ps1: A wrapper script to transparently authenticate with Vault,
# sign your SSH key, and connect to a target host using the signed certificate.
#
# Usage:
#   .\ssh-sec.ps1 [user@]hostname [ssh_options]
#

param (
    [Parameter(Position=0, Mandatory=$true)]
    [string]$Target,
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$SshOptions
)

# 1. Parse target user and host
$TargetUser = $env:USERNAME
$TargetHost = $Target

if ($Target -like "*@*") {
    $parts = $Target -split '@', 2
    $TargetUser = $parts[0]
    $TargetHost = $parts[1]
}

# 2. Locate client SSH key pair
$SshDir = Join-Path $env:USERPROFILE ".ssh"
$PubKeyPath = ""
$PrivKeyPath = ""

if (Test-Path (Join-Path $SshDir "id_ed25519.pub")) {
    $PubKeyPath = Join-Path $SshDir "id_ed25519.pub"
    $PrivKeyPath = Join-Path $SshDir "id_ed25519"
} elseif (Test-Path (Join-Path $SshDir "id_rsa.pub")) {
    $PubKeyPath = Join-Path $SshDir "id_rsa.pub"
    $PrivKeyPath = Join-Path $SshDir "id_rsa"
} else {
    Write-Error "Error: No SSH public key found in $SshDir."
    Write-Host "Please generate one first using: ssh-keygen -t ed25519" -ForegroundColor Yellow
    exit 1
}

$CertPath = "${PrivKeyPath}-cert.pub"

# 3. Configure Vault address and CA certificate
if (-not $env:VAULT_ADDR) {
    $env:VAULT_ADDR = "https://vault.lan"
}

# Try to find the CA certificate
if (-not $env:VAULT_CACERT) {
    $localCa = Join-Path $SshDir "lan_root_ca.crt"
    if (Test-Path $localCa) {
        $env:VAULT_CACERT = $localCa
    } elseif (Test-Path "secrets/lan_root_ca.crt") {
        $env:VAULT_CACERT = (Resolve-Path "secrets/lan_root_ca.crt").Path
    } elseif (Test-Path "lan_root_ca.crt") {
        $env:VAULT_CACERT = (Resolve-Path "lan_root_ca.crt").Path
    }
}

# Ensure vault CLI is installed
if (-not (Get-Command "vault" -ErrorAction SilentlyContinue)) {
    Write-Error "Error: 'vault' CLI command not found. Please install Vault CLI and add it to your PATH."
    exit 1
}

# 4. Ensure user is authenticated with Vault
& vault token lookup > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Vault token missing or expired. Authenticating..." -ForegroundColor Cyan
    & vault login -method=userpass
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Error: Vault authentication failed."
        exit 1
    }
}

# 5. Sign the SSH public key for the target user (principal)
Write-Host "Requesting SSH certificate from Vault for user '$TargetUser'..." -ForegroundColor Cyan

# Read public key content
$PubKeyContent = Get-Content -Raw $PubKeyPath
# Vault CLI expects public_key=@path or key content. We pass the path to vault write
$RelativePubKeyPath = $PubKeyPath

# Call vault write to sign key
$SignedKey = & vault write -format=json ssh-client-signer/sign/client-role public_key="@$RelativePubKeyPath" valid_principals="$TargetUser" 2>$null | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or -not $SignedKey -or -not $SignedKey.data -or -not $SignedKey.data.signed_key) {
    Write-Error "Error: Vault failed to sign the SSH key."
    exit 1
}

# Save the signed certificate
$SignedKey.data.signed_key | Out-File -FilePath $CertPath -Encoding ascii -NoNewline
Write-Host "Certificate successfully generated and saved to: $CertPath" -ForegroundColor Green

# 6. Execute the real ssh command, forwarding all arguments
Write-Host "Connecting to $TargetHost..." -ForegroundColor Cyan

$SshArgs = @("-i", $PrivKeyPath, "-i", $CertPath)
if ($Target -like "*@*") {
    $SshArgs += $Target
} else {
    $SshArgs += "${TargetUser}@${TargetHost}"
}

if ($SshOptions) {
    $SshArgs += $SshOptions
}

& ssh $SshArgs
