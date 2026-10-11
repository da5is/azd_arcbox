#!/bin/sh
set -eu

if command -v azcmagent >/dev/null 2>&1; then
    agent_info=$(azcmagent show --json)
    connection_state=$(printf '%s' "$agent_info" | python3 -c '
import json, sys
agent = json.load(sys.stdin)
if agent.get("status", "").lower() == "connected":
    if agent.get("subscriptionId", "").lower() != sys.argv[1].lower() or agent.get("resourceGroup", "").lower() != sys.argv[2].lower():
        sys.exit("Existing Azure Arc connection belongs to a different subscription or resource group.")
    print("connected")
' "$subscriptionId" "$resourceGroup")
    if [ "$connection_state" = connected ]; then
        echo "Azure Arc agent already connected to the requested resource group."
        exit 0
    fi
fi

# Block Azure IMDS
sudo ufw --force enable
sudo ufw deny out from any to 169.254.169.254
sudo ufw default allow incoming

# Download the installation package
if ! command -v azcmagent >/dev/null 2>&1; then
    installer="$HOME/install_linux_azcmagent.sh"
    trap 'rm -f "$installer.partial"' EXIT
    wget --timeout=60 --tries=3 https://aka.ms/azcmagent -O "$installer.partial"
    mv "$installer.partial" "$installer"
    bash "$installer"
fi

ArcServerResourceName=$(hostname |sed -e "s/\b\(.\)/\u\1/g")

# Run connect command
azcmagent connect --access-token "$accessToken" --resource-group "$resourceGroup" --tenant-id "$tenantId" --location "$Azurelocation" --subscription-id "$subscriptionId" --resource-name "${ArcServerResourceName}" --cloud "AzureCloud" --correlation-id "d009f5dd-dba8-4ac7-bac9-b54ef3a6671a"
