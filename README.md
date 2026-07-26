# AWS CodeArtifact Developer Tools

This repository provides an automated setup script (`setup.sh`) to seamlessly configure your local development environment to securely consume private Python packages hosted in AWS CodeArtifact.

## Quick Start (How to Use)

You must run this script from a **Linux** (e.g., Ubuntu/Debian/WSL) or **macOS** environment. 

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Sanvith-playground/Codeartifact-Developer-Tools.git
   cd Codeartifact-Developer-Tools
   ```

2. **Make the script executable:**
   ```bash
   chmod +x setup.sh
   ```

3. **Run the setup script:**
   ```bash
   ./setup.sh
   ```

4. **Install Packages in a Virtual Environment:**
   Once the script succeeds, create a Python virtual environment and install your packages:
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate
   pip install company-web==1.0.5
   ```

## Daily Usage (Refreshing Sessions)

AWS CodeArtifact authorization tokens strictly expire every **12 hours** for security. You do not need to run the full `setup.sh` every morning. 

Instead, simply run `start.sh` at the beginning of your workday to fetch fresh tokens using your existing AWS profile:

```bash
chmod +x start.sh
./start.sh
```

---

## What Does This Script Do?

`setup.sh` automates the entire process of logging into AWS and configuring your system to download packages from AWS CodeArtifact. Behind the scenes, it performs the following tasks:

1. **Dependency Checks:** Verifies that required tools (`aws`, `python3`, `pip3`, `jq`, `curl`) are installed, and provides installation commands if they are missing.
2. **AWS Profile Configuration:** Creates or updates a local AWS CLI profile named `Developer` linked to your AWS IAM Identity Center (SSO).
3. **SSO Authentication:** Automatically opens a browser to authenticate your session via AWS device code login. If an active session already exists, it skips this step to save time.
4. **Permissions Verification:** Confirms your authenticated identity and verifies you have access to the target account and role (`Developer-permission`). It includes auto-discovery to suggest available roles if access is denied.
5. **Pip Configuration:** Securely retrieves an AWS CodeArtifact authorization token and configures your local `pip.conf` (via `aws codeartifact login`) so `pip` knows how to download private packages.
6. **Connectivity Verification:** Performs a dry-run check to confirm `pip` can successfully communicate with the remote AWS repository.

## Use Case

This tool is designed **exclusively for developers** who need to consume (download) internal Python packages (like `company-web`) built by other teams. 

**It is explicitly built to be safe:**
- It **does not** require or use long-lived AWS Access Keys.
- It **does not** configure credentials for publishing packages.
- It **does not** modify any AWS IAM or Identity Center configurations.
- It relies entirely on temporary, short-lived AWS SSO credentials (which expire every 12 hours) to ensure the highest security standards.

## Troubleshooting

- **Role Access Denied:** If the script fails because you don't have the `Developer-permission` role, the script will automatically scan your account and print a list of roles you *do* have. You can override the role by running `export SSO_ROLE_NAME="YourActualRoleName"` before running the script.
- **Externally Managed Environment (PEP 668):** If you try to run `pip install` and get an `externally-managed-environment` error, it means your OS is protecting system packages. Simply create a virtual environment first (`python3 -m venv .venv && source .venv/bin/activate`) and run `pip install` inside of it.
- **Switching Users:** If you need to switch AWS users, run `aws sso logout` first, then run `./setup.sh` again and open the provided URL in an **Incognito/Private** browser window.
