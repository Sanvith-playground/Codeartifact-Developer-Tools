<#
.SYNOPSIS
AWS CodeArtifact Developer Setup
.DESCRIPTION
This script configures the AWS CLI to authenticate via IAM Identity Center (SSO)
and retrieves a CodeArtifact token to securely configure pip for the user.
It is designed to be idempotent and safe for repeated execution.

Note: This script is exclusively for developers consuming packages.
It does not configure publishing credentials or administrator access.
#>

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------------------------
# Configuration Variables
# ------------------------------------------------------------------------------
$AWS_REGION = if ([bool]$env:AWS_REGION) { $env:AWS_REGION } else { "us-east-1" }
$SSO_REGION = if ([bool]$env:SSO_REGION) { $env:SSO_REGION } else { "us-east-1" }
$AWS_ACCOUNT_ID = if ([bool]$env:AWS_ACCOUNT_ID) { $env:AWS_ACCOUNT_ID } else { "080800845757" }
$SSO_ROLE_NAME = if ([bool]$env:SSO_ROLE_NAME) { $env:SSO_ROLE_NAME } else { "Developer-permission" }
$PROFILE_NAME = if ([bool]$env:PROFILE_NAME) { $env:PROFILE_NAME } else { "Developer" }
$CA_DOMAIN = if ([bool]$env:CA_DOMAIN) { $env:CA_DOMAIN } else { "grag-ai-factory" }
$CA_DOMAIN_OWNER = if ([bool]$env:CA_DOMAIN_OWNER) { $env:CA_DOMAIN_OWNER } else { "080800845757" }
$CA_REPO = if ([bool]$env:CA_REPO) { $env:CA_REPO } else { "python-packages" }
$SSO_START_URL = if ([bool]$env:SSO_START_URL) { $env:SSO_START_URL } else { "https://d-906679b0a1.awsapps.com/start" }

# ------------------------------------------------------------------------------
# Helper Logging Functions
# ------------------------------------------------------------------------------
function Write-LogInfo { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-LogSuccess { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-LogWarn { param([string]$Message) Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
function Write-LogError { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }
function Fatal { param([string]$Message) Write-LogError $Message; exit 1 }

# ------------------------------------------------------------------------------
# 1. Banner
# ------------------------------------------------------------------------------
function Print-Banner {
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host " AWS CodeArtifact Developer Setup" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host ""
}

# ------------------------------------------------------------------------------
# 2. Check Operating System
# ------------------------------------------------------------------------------
function Check-OS {
    Write-LogInfo "Checking operating system..."
    # If running in PowerShell Core
    if ($null -ne $IsWindows -and -not $IsWindows) {
        Fatal "This script is designed for Windows."
    }
    Write-LogSuccess "OS validated (Windows)."
}

# ------------------------------------------------------------------------------
# 3. Check Internet Connectivity
# ------------------------------------------------------------------------------
function Check-Internet {
    Write-LogInfo "Checking internet connectivity..."
    try {
        $response = Invoke-WebRequest -Uri "https://sts.$AWS_REGION.amazonaws.com" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-LogSuccess "Internet connectivity verified."
    } catch {
        Fatal "Cannot reach AWS endpoints. Please check your internet connection."
    }
}

# ------------------------------------------------------------------------------
# 4. Check Required Tools
# ------------------------------------------------------------------------------
function Check-Tools {
    Write-LogInfo "Verifying required tools..."
    $required_cmds = @("aws", "python", "pip")
    $missing_cmds = @()

    foreach ($cmd in $required_cmds) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            $missing_cmds += $cmd
        }
    }

    if ($missing_cmds.Count -gt 0) {
        Write-LogError "The following required tools are missing: $($missing_cmds -join ', ')"
        Write-Host ""
        Write-Host "Please install them and ensure they are in your PATH."
        Write-Host "Examples:"
        Write-Host "  AWS CLI: https://aws.amazon.com/cli/"
        Write-Host "  Python:  https://www.python.org/downloads/windows/"
        Fatal "Missing dependencies."
    }
    Write-LogSuccess "All required tools are installed."
}

# ------------------------------------------------------------------------------
# 5. Verify AWS CLI Version
# ------------------------------------------------------------------------------
function Verify-AwsCliVersion {
    Write-LogInfo "Verifying AWS CLI version..."
    try {
        $aws_version_output = aws --version 2>&1
        $aws_version = ($aws_version_output -split ' ')[0]
        
        if ($aws_version -notmatch "^aws-cli/2\.") {
            Fatal "AWS CLI version 2 is required. Found: $aws_version. Please upgrade."
        }
        Write-LogSuccess "AWS CLI v2 detected."
    } catch {
        Fatal "Failed to verify AWS CLI version."
    }
}

# ------------------------------------------------------------------------------
# 6. Configure AWS SSO Profile
# ------------------------------------------------------------------------------
function Configure-SsoProfile {
    Write-LogInfo "Configuring AWS SSO profile '${PROFILE_NAME}'..."
    
    # Backup existing AWS profile check
    $profiles = aws configure list-profiles 2>$null
    if ($profiles -contains $PROFILE_NAME) {
        Write-LogWarn "Existing ${PROFILE_NAME} profile found. Updating profile..."
    }
    
    aws configure set sso_start_url "$SSO_START_URL" --profile "$PROFILE_NAME"
    aws configure set sso_region "$SSO_REGION" --profile "$PROFILE_NAME"
    aws configure set sso_account_id "$AWS_ACCOUNT_ID" --profile "$PROFILE_NAME"
    aws configure set sso_role_name "$SSO_ROLE_NAME" --profile "$PROFILE_NAME"
    aws configure set region "$AWS_REGION" --profile "$PROFILE_NAME"
    aws configure set output "json" --profile "$PROFILE_NAME"
    
    Write-LogSuccess "AWS profile '${PROFILE_NAME}' configured successfully."
}

# ------------------------------------------------------------------------------
# 7 & 8. Detect Existing Session and Perform AWS SSO Login
# ------------------------------------------------------------------------------
function Perform-SsoLogin {
    Write-LogInfo "Checking for existing SSO session..."
    
    $session_valid = $false
    
    $sso_cache_dir = Join-Path (Join-Path $HOME ".aws") "sso\cache"
    if (Test-Path $sso_cache_dir) {
        try {
            aws sts get-caller-identity --profile "$PROFILE_NAME" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $session_valid = $true
            }
        } catch {
            $session_valid = $false
        }
    }
    
    if ($session_valid) {
        Write-LogSuccess "Existing SSO session found and is valid. Skipping login."
    } else {
        Write-LogWarn "No active session found or session expired."
        Write-LogInfo "Initiating AWS SSO login..."
        
        Write-Host "`n=== Action Required ===" -ForegroundColor Yellow
        Write-Host "1. A browser window will open automatically."
        Write-Host "2. Review and confirm the authorization request."
        Write-Host "3. Complete any MFA required."
        Write-Host "4. Return to this terminal once authorized.`n"
        
        $max_retries = 3
        $attempt = 1
        while ($attempt -le $max_retries) {
            aws sso login --profile "$PROFILE_NAME"
            if ($LASTEXITCODE -eq 0) {
                Write-LogSuccess "SSO login completed."
                break
            } else {
                Write-LogWarn "Login attempt $attempt failed."
                $attempt++
                if ($attempt -le $max_retries) {
                    Write-LogInfo "Retrying login... (Attempt $attempt of $max_retries)"
                } else {
                    Fatal "Failed to authenticate via AWS SSO after $max_retries attempts."
                }
            }
        }
    }
}

# ------------------------------------------------------------------------------
# 9 & 10. Verify Identity and Print Expiration
# ------------------------------------------------------------------------------
function Verify-Identity {
    Write-LogInfo "Verifying AWS identity context..."
    
    $caller_identity_json = aws sts get-caller-identity --profile "$PROFILE_NAME" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($caller_identity_json)) {
        Write-Host "`n=== Role Access Denied ===" -ForegroundColor Red
        Write-Host "Your SSO login succeeded, but you do not have permission to assume the configured role."
        Write-Host "  Target Account ID: ${AWS_ACCOUNT_ID}"
        Write-Host "  Target Role Name:  ${SSO_ROLE_NAME}"
        
        # Automatically discover available roles
        $sso_cache_dir = Join-Path (Join-Path $HOME ".aws") "sso\cache"
        if (Test-Path $sso_cache_dir) {
            $token_files = Get-ChildItem -Path $sso_cache_dir -Filter "*.json" | Sort-Object LastWriteTime -Descending
            $token_file = $token_files | Where-Object { (Get-Content $_.FullName -Raw) -match '"accessToken"' } | Select-Object -First 1
            if ($token_file) {
                $token_data = Get-Content $token_file.FullName -Raw | ConvertFrom-Json
                $access_token = $token_data.accessToken
                if ($access_token -and $access_token -ne "null") {
                    Write-Host "`nDiscovering your available roles in account ${AWS_ACCOUNT_ID}..." -ForegroundColor Cyan
                    $roles_json = aws sso list-account-roles --account-id "$AWS_ACCOUNT_ID" --access-token "$access_token" 2>$null
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($roles_json)) {
                        $roles_data = $roles_json | ConvertFrom-Json
                        $available_roles = $roles_data.roleList.roleName
                        if ($available_roles) {
                            Write-Host "Good news! We found the following roles assigned to you:" -ForegroundColor Green
                            foreach ($role in $available_roles) {
                                Write-Host "  - $role" -ForegroundColor Yellow
                            }
                            Write-Host "`nTo use one of these roles, simply run:"
                            Write-Host "  `$env:SSO_ROLE_NAME=`"<RoleName>`"" -ForegroundColor Yellow
                            Write-Host "  .\setup.ps1" -ForegroundColor Yellow
                            Write-Host "`n------------------------------------------" -ForegroundColor Cyan
                        }
                    }
                }
            }
        }

        Write-Host "`nOther Troubleshooting Steps:" -ForegroundColor Yellow
        Write-Host "1. If you accidentally logged in as the wrong user, log out locally first:"
        Write-Host "     aws sso logout"
        Write-Host "   Then run .\setup.ps1 again and open the login link in an Incognito/Private browser window."
        Write-Host "2. Verify with your DevOps team that you have been granted access to this account.`n"
        Fatal "Could not retrieve caller identity."
    }
    
    $caller_identity = $caller_identity_json | ConvertFrom-Json
    $account_id = $caller_identity.Account
    $arn = $caller_identity.Arn
    $user_id = $caller_identity.UserId
    
    Write-Host "`nLogged in as:" -ForegroundColor Cyan
    Write-Host "  Account ID: ${account_id}"
    Write-Host "  ARN:        ${arn}"
    Write-Host "  User ID:    ${user_id}`n"
    
    # Try to find the session expiration from SSO cache
    $sso_cache_dir = Join-Path (Join-Path $HOME ".aws") "sso\cache"
    if (Test-Path $sso_cache_dir) {
        $latest_cache = Get-ChildItem -Path $sso_cache_dir -Filter "*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest_cache) {
            $cache_data = Get-Content $latest_cache.FullName -Raw | ConvertFrom-Json
            if ($cache_data.expiresAt) {
                $expires_at = $cache_data.expiresAt
                Write-Host "SSO Session Active" -ForegroundColor Green
                Write-Host "Expires: " -NoNewline
                Write-Host "${expires_at} UTC`n" -ForegroundColor Yellow
            }
        }
    }
}

# ------------------------------------------------------------------------------
# 11. Configure pip
# ------------------------------------------------------------------------------
function Configure-Pip {
    Write-LogInfo "Configuring pip for CodeArtifact..."
    
    aws codeartifact login --tool pip --repository "$CA_REPO" --domain "$CA_DOMAIN" --domain-owner "$CA_DOMAIN_OWNER" --profile "$PROFILE_NAME" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-LogSuccess "pip configured successfully via 'aws codeartifact login'."
    } else {
        Fatal "Failed to configure pip for CodeArtifact."
    }
}

# ------------------------------------------------------------------------------
# 12. Verify Repository Access
# ------------------------------------------------------------------------------
function Verify-RepoAccess {
    Write-LogInfo "Verifying repository access via AWS CLI..."
    
    aws codeartifact list-packages --domain "$CA_DOMAIN" --domain-owner "$CA_DOMAIN_OWNER" --repository "$CA_REPO" --max-results 1 --profile "$PROFILE_NAME" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fatal "Failed to access the CodeArtifact repository."
    }
    
    Write-LogSuccess "Repository Connected Successfully."
}

# ------------------------------------------------------------------------------
# 13. Test Package Installation (Dry Run)
# ------------------------------------------------------------------------------
function Test-PackageInstall {
    Write-LogInfo "Testing package access (dry verification)..."
    
    $test_pkg = "company-web"
    
    & pip index versions "$test_pkg" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
         Write-LogSuccess "[OK] Repository connection verified (found ${test_pkg})."
    } else {
         Write-LogWarn "Could not verify '${test_pkg}'. Ensure the package exists in the repository."
    }
}

# ------------------------------------------------------------------------------
# Main Execution Flow
# ------------------------------------------------------------------------------
function Main {
    Print-Banner
    Check-OS
    Check-Internet
    Check-Tools
    Verify-AwsCliVersion
    Configure-SsoProfile
    Perform-SsoLogin
    Verify-Identity
    Configure-Pip
    Verify-RepoAccess
    Test-PackageInstall
    
    Write-Host "`n==========================================" -ForegroundColor Blue
    Write-Host " Setup Complete" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Blue
    Write-Host "`nTip: Consider using a virtual environment:" -ForegroundColor Cyan
    Write-Host "  python -m venv .venv; .\venv\Scripts\Activate.ps1`n"
    
    Write-Host "You can now install packages using:"
    Write-Host "  pip install <package-name>" -ForegroundColor Yellow
    Write-Host "`nExample:"
    Write-Host "  pip install company-web==1.0.5`n" -ForegroundColor Yellow
    Write-Host "Note: CodeArtifact tokens expire every 12 hours. If you receive authentication errors, simply rerun this setup script to refresh the token while reusing your active SSO session.`n" -ForegroundColor Cyan
}

try {
    Main
} catch {
    Write-LogError "Error occurred: $_"
    exit 1
}
