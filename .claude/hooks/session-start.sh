#!/bin/bash
set -euo pipefail

# Only run in remote (web) environments
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

echo "Installing PowerShell and PSScriptAnalyzer for linting..."

# Install PowerShell Core if not already present
if ! command -v pwsh &>/dev/null; then
  wget -q https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb \
    -O /tmp/packages-microsoft-prod.deb
  dpkg -i /tmp/packages-microsoft-prod.deb
  apt-get update -q
  apt-get install -y powershell
fi

# Install PSScriptAnalyzer if not already present
pwsh -NonInteractive -NoProfile -Command "
  if (-not (Get-Module PSScriptAnalyzer -ListAvailable)) {
    Install-Module PSScriptAnalyzer -Force -Scope CurrentUser -Repository PSGallery
  }
"

echo "Setup complete."
