#!/usr/bin/env bash

# ==============================================================================
# AWS CodeArtifact Developer Setup
# ==============================================================================
# This script configures the AWS CLI to authenticate via IAM Identity Center (SSO)
# and retrieves a CodeArtifact token to securely configure pip for the user.
# It is designed to be idempotent and safe for repeated execution.
#
# Note: This script is exclusively for developers consuming packages.
# It does not configure publishing credentials or administrator access.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Configuration Variables
# ------------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-us-east-1}"
SSO_REGION="${SSO_REGION:-us-east-1}"
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-080800845757}"
SSO_ROLE_NAME="${SSO_ROLE_NAME:-Developer-permission}"
PROFILE_NAME="${PROFILE_NAME:-Developer}"
CA_DOMAIN="${CA_DOMAIN:-grag-ai-factory}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-080800845757}"
CA_REPO="${CA_REPO:-python-packages}"
SSO_START_URL="${SSO_START_URL:-https://d-906679b0a1.awsapps.com/start}"

# ------------------------------------------------------------------------------
# ANSI Colors for Output
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global State Variables (Stored only in memory)
TMPFILE=$(mktemp)

# ------------------------------------------------------------------------------
# 15. Cleanup Function
# ------------------------------------------------------------------------------
# Ensures sensitive variables and temp files are removed upon exit
cleanup() {
    rm -f "$TMPFILE"
}

# Better error trap
trap 'log_error "Error on line $LINENO"; cleanup' ERR
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Helper Logging Functions
# ------------------------------------------------------------------------------
log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
fatal()       { log_error "$1"; exit 1; }

# ------------------------------------------------------------------------------
# 1. Banner
# ------------------------------------------------------------------------------
print_banner() {
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${GREEN} AWS CodeArtifact Developer Setup${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo ""
}

# ------------------------------------------------------------------------------
# 2. Check Operating System
# ------------------------------------------------------------------------------
check_os() {
    log_info "Checking operating system..."
    local os_name
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [[ -f /etc/os-release ]]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            os_name=${ID:-unknown}
            if [[ ! "$os_name" =~ ^(ubuntu|debian|amzn|rhel|rocky|centos)$ ]]; then
                fatal "Unsupported Linux distribution: $os_name. Supported: ubuntu, debian, amzn, rhel, rocky."
            fi
        else
            fatal "Cannot determine Linux distribution. /etc/os-release not found."
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        os_name="macos"
    else
        fatal "Unsupported OS type: $OSTYPE. Only Linux and macOS are supported."
    fi
    
    log_success "OS validated ($os_name)."
}

# ------------------------------------------------------------------------------
# 3. Check Internet Connectivity
# ------------------------------------------------------------------------------
check_internet() {
    log_info "Checking internet connectivity..."
    if ! curl -sI --connect-timeout 5 "https://sts.${AWS_REGION}.amazonaws.com" > /dev/null; then
        fatal "Cannot reach AWS endpoints. Please check your internet connection."
    fi
    log_success "Internet connectivity verified."
}

# ------------------------------------------------------------------------------
# 4. Check Required Tools
# ------------------------------------------------------------------------------
check_tools() {
    log_info "Verifying required tools..."
    local required_cmds=(aws python3 pip3 grep sed jq curl)
    local missing_cmds=()

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_error "The following required tools are missing: ${missing_cmds[*]}"
        echo -e "\nPlease install them using your package manager."
        echo -e "Examples:"
        echo -e "  Ubuntu/Debian: sudo apt update && sudo apt install awscli python3 python3-pip jq curl"
        echo -e "  Amazon Linux:  sudo dnf install awscli python3 python3-pip jq curl"
        echo -e "  macOS:         brew install awscli python jq curl"
        fatal "Missing dependencies."
    fi
    log_success "All required tools are installed."
}

# ------------------------------------------------------------------------------
# 5. Verify AWS CLI Version
# ------------------------------------------------------------------------------
verify_aws_cli_version() {
    log_info "Verifying AWS CLI version..."
    local aws_version
    aws_version=$(aws --version 2>&1 | cut -d ' ' -f 1 || true)
    
    if [[ "$aws_version" != aws-cli/2.* ]]; then
        fatal "AWS CLI version 2 is required. Found: $aws_version. Please upgrade."
    fi
    log_success "AWS CLI v2 detected."
}

# ------------------------------------------------------------------------------
# 6. Configure AWS SSO Profile
# ------------------------------------------------------------------------------
configure_sso_profile() {
    log_info "Configuring AWS SSO profile '${PROFILE_NAME}'..."
    
    # Backup existing AWS profile check
    if aws configure list-profiles 2>/dev/null | grep -q "^${PROFILE_NAME}$"; then
        log_warn "Existing ${PROFILE_NAME} profile found. Updating profile..."
    fi
    
    aws configure set sso_start_url "$SSO_START_URL" --profile "$PROFILE_NAME"
    aws configure set sso_region "$SSO_REGION" --profile "$PROFILE_NAME"
    aws configure set sso_account_id "$AWS_ACCOUNT_ID" --profile "$PROFILE_NAME"
    aws configure set sso_role_name "$SSO_ROLE_NAME" --profile "$PROFILE_NAME"
    aws configure set region "$AWS_REGION" --profile "$PROFILE_NAME"
    aws configure set output "json" --profile "$PROFILE_NAME"
    
    log_success "AWS profile '${PROFILE_NAME}' configured successfully."
}

# ------------------------------------------------------------------------------
# 7 & 8. Detect Existing Session and Perform AWS SSO Login
# ------------------------------------------------------------------------------
perform_sso_login() {
    log_info "Checking for existing SSO session..."
    
    local session_valid=false
    
    # Better SSO session detection
    if [[ -d ~/.aws/sso/cache ]]; then
        if aws sts get-caller-identity --profile "$PROFILE_NAME" >/dev/null 2>&1; then
            session_valid=true
        fi
    fi
    
    if [[ "$session_valid" == true ]]; then
        log_success "Existing SSO session found and is valid. Skipping login."
    else
        log_warn "No active session found or session expired."
        log_info "Initiating AWS SSO login via device code..."
        
        echo -e "\n${YELLOW}=== Action Required ===${NC}"
        echo -e "1. Open the URL shown below in your browser."
        echo -e "   ${CYAN}(Tip: Use an Incognito/Private window if you need to switch users or force a password/MFA prompt)${NC}"
        echo -e "2. Enter the device code provided."
        echo -e "3. Complete any MFA required."
        echo -e "4. Return to this terminal once authorized.\n"
        
        local max_retries=3
        local attempt=1
        while [[ $attempt -le $max_retries ]]; do
            if aws sso login --profile "$PROFILE_NAME" --use-device-code; then
                log_success "SSO login completed."
                break
            else
                log_warn "Login attempt $attempt failed."
                attempt=$((attempt + 1))
                if [[ $attempt -le $max_retries ]]; then
                    log_info "Retrying login... (Attempt $attempt of $max_retries)"
                else
                    fatal "Failed to authenticate via AWS SSO after $max_retries attempts."
                fi
            fi
        done
    fi
}

# ------------------------------------------------------------------------------
# 9 & 10. Verify Identity and Print Expiration
# ------------------------------------------------------------------------------
verify_identity() {
    log_info "Verifying AWS identity context..."
    local caller_identity
    
    if ! caller_identity=$(aws sts get-caller-identity --profile "$PROFILE_NAME"); then
        echo -e "\n${RED}=== Role Access Denied ===${NC}"
        echo -e "Your SSO login succeeded, but you do not have permission to assume the configured role."
        echo -e "  Target Account ID: ${AWS_ACCOUNT_ID}"
        echo -e "  Target Role Name:  ${SSO_ROLE_NAME}"
        
        # Automatically discover available roles
        local cache_dir=~/.aws/sso/cache
        if [[ -d "$cache_dir" ]]; then
            local token_file
            token_file=$(grep -l accessToken "$cache_dir"/*.json 2>/dev/null | xargs ls -t 2>/dev/null | head -n 1)
            if [[ -n "$token_file" ]]; then
                local access_token
                access_token=$(jq -r .accessToken "$token_file")
                if [[ -n "$access_token" && "$access_token" != "null" ]]; then
                    echo -e "\n${CYAN}Discovering your available roles in account ${AWS_ACCOUNT_ID}...${NC}"
                    local roles_json
                    if roles_json=$(aws sso list-account-roles --account-id "$AWS_ACCOUNT_ID" --access-token "$access_token" 2>/dev/null); then
                        local available_roles
                        available_roles=$(echo "$roles_json" | jq -r '.roleList[].roleName')
                        if [[ -n "$available_roles" ]]; then
                            echo -e "${GREEN}Good news! We found the following roles assigned to you:${NC}"
                            while IFS= read -r role; do
                                echo -e "  - ${YELLOW}$role${NC}"
                            done <<< "$available_roles"
                            echo -e "\nTo use one of these roles, simply run:"
                            echo -e "  ${YELLOW}export SSO_ROLE_NAME=\"<RoleName>\"${NC}"
                            echo -e "  ${YELLOW}./setup.sh${NC}"
                            echo -e "\n${CYAN}------------------------------------------${NC}"
                        fi
                    fi
                fi
            fi
        fi

        echo -e "\n${YELLOW}Other Troubleshooting Steps:${NC}"
        echo -e "1. If you accidentally logged in as the wrong user, log out locally first:"
        echo -e "     aws sso logout"
        echo -e "   Then run ./setup.sh again and open the login link in an ${CYAN}Incognito/Private${NC} browser window."
        echo -e "2. Verify with your DevOps team that you have been granted access to this account.\n"
        fatal "Could not retrieve caller identity."
    fi
    
    local account_id
    local arn
    local user_id
    
    account_id=$(echo "$caller_identity" | jq -r .Account)
    arn=$(echo "$caller_identity" | jq -r .Arn)
    user_id=$(echo "$caller_identity" | jq -r .UserId)
    
    echo -e "\n${CYAN}Logged in as:${NC}"
    echo -e "  Account ID: ${account_id}"
    echo -e "  ARN:        ${arn}"
    echo -e "  User ID:    ${user_id}\n"
    
    # Try to find the session expiration from SSO cache
    local cache_dir=~/.aws/sso/cache
    if [[ -d "$cache_dir" ]]; then
        local latest_cache
        # Get the most recently modified json file in the cache directory
        latest_cache=$(ls -t "$cache_dir"/*.json 2>/dev/null | head -n 1 || true)
        if [[ -n "$latest_cache" && -f "$latest_cache" ]]; then
            local expires_at
            expires_at=$(jq -r '.expiresAt // empty' "$latest_cache")
            if [[ -n "$expires_at" ]]; then
                echo -e "${GREEN}SSO Session Active${NC}"
                echo -e "Expires: ${YELLOW}${expires_at} UTC${NC}\n"
            fi
        fi
    fi
}

# ------------------------------------------------------------------------------
# 11. Configure pip
# ------------------------------------------------------------------------------
configure_pip() {
    log_info "Configuring pip for CodeArtifact..."
    
    # Use aws codeartifact login for pip configuration
    if aws codeartifact login \
        --tool pip \
        --repository "$CA_REPO" \
        --domain "$CA_DOMAIN" \
        --domain-owner "$CA_DOMAIN_OWNER" \
        --profile "$PROFILE_NAME"; then
        
        log_success "pip configured successfully via 'aws codeartifact login'."
    else
        fatal "Failed to configure pip for CodeArtifact."
    fi
}

# ------------------------------------------------------------------------------
# 12. Verify Repository Access
# ------------------------------------------------------------------------------
verify_repo_access() {
    log_info "Verifying repository access via AWS CLI..."
    
    if ! aws codeartifact list-packages \
        --domain "$CA_DOMAIN" \
        --domain-owner "$CA_DOMAIN_OWNER" \
        --repository "$CA_REPO" \
        --max-results 1 \
        --profile "$PROFILE_NAME" >/dev/null 2>&1; then
        fatal "Failed to access the CodeArtifact repository."
    fi
    
    log_success "Repository Connected Successfully."
}

# ------------------------------------------------------------------------------
# 13. Test Package Installation (Dry Run)
# ------------------------------------------------------------------------------
test_package_install() {
    log_info "Testing package access (dry verification)..."
    
    local test_pkg="employee-management"
    
    if pip3 index versions "$test_pkg" >/dev/null 2>&1; then
         log_success "✔ Repository connection verified (found ${test_pkg})."
    else
         log_warn "Could not verify '${test_pkg}'. Ensure the package exists in the repository."
    fi
}

# ------------------------------------------------------------------------------
# Main Execution Flow
# ------------------------------------------------------------------------------
main() {
    print_banner
    check_os
    check_internet
    check_tools
    verify_aws_cli_version
    configure_sso_profile
    perform_sso_login
    verify_identity
    configure_pip
    verify_repo_access
    test_package_install
    
    echo -e "\n${BLUE}==========================================${NC}"
    echo -e "${GREEN} Setup Complete${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo -e "\nYou can now install packages using:"
    echo -e "  ${YELLOW}pip install <package-name>${NC}"
    echo -e "\nExample:"
    echo -e "  ${YELLOW}pip install employee-management==1.0.0${NC}\n"
    echo -e "${CYAN}Note: CodeArtifact tokens expire every 12 hours. If you receive authentication errors, simply rerun this setup script to refresh the token while reusing your active SSO session.${NC}\n"
}

# Execute main function
main "$@"
