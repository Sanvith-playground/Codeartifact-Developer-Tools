#!/bin/bash
set -euo pipefail

# Configuration
PROFILE_NAME="${PROFILE_NAME:-Developer}"
CA_DOMAIN="${CA_DOMAIN:-grag-ai-factory}"
CA_DOMAIN_OWNER="${CA_DOMAIN_OWNER:-080800845757}"
CA_REPO="${CA_REPO:-python-packages}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN} AWS CodeArtifact Daily Refresher${NC}"
echo -e "${BLUE}==========================================${NC}"

# Helper function to check if SSO session is still valid
check_sso_session() {
    local cache_dir=~/.aws/sso/cache
    local current_time
    current_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if [[ -d "$cache_dir" ]]; then
        for file in "$cache_dir"/*.json; do
            if [[ -f "$file" ]]; then
                if grep -q "expiresAt" "$file" 2>/dev/null; then
                    local expires_at
                    expires_at=$(jq -r .expiresAt "$file" 2>/dev/null)
                    if [[ "$expires_at" > "$current_time" ]]; then
                        return 0
                    fi
                fi
            fi
        done
    fi
    return 1
}

# 1. Refresh AWS SSO Login
echo -e "\n${YELLOW}[INFO] Checking AWS SSO session for profile '${PROFILE_NAME}'...${NC}"
if check_sso_session; then
    echo -e "${GREEN}[SUCCESS] Existing SSO session is still active. Skipping browser login.${NC}"
else
    echo -e "${YELLOW}[INFO] SSO session expired. Initiating login...${NC}"
    if aws sso login --profile "$PROFILE_NAME" --use-device-code; then
        echo -e "${GREEN}[SUCCESS] AWS SSO session is active.${NC}"
    else
        echo -e "${RED}[ERROR] Failed to login to AWS SSO.${NC}"
        exit 1
    fi
fi

# 2. Fetch new CodeArtifact Token
echo -e "\n${YELLOW}[INFO] Fetching new CodeArtifact token for pip...${NC}"
if aws codeartifact login \
    --tool pip \
    --repository "$CA_REPO" \
    --domain "$CA_DOMAIN" \
    --domain-owner "$CA_DOMAIN_OWNER" \
    --profile "$PROFILE_NAME"; then
    
    echo -e "${GREEN}[SUCCESS] pip is successfully configured with a fresh token!${NC}"
else
    echo -e "${RED}[ERROR] Failed to fetch CodeArtifact token.${NC}"
    exit 1
fi

echo -e "\n${BLUE}==========================================${NC}"
echo -e "${GREEN} You are ready to develop!${NC}"
echo -e "${BLUE}==========================================${NC}"
echo -e "Remember to activate your virtual environment before installing packages:"
echo -e "  source .venv/bin/activate"
echo -e "  pip install <package-name>\n"
