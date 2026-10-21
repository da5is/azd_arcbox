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
    python3 - "$installer" <<'PY'
import contextlib
import errno
import fcntl
import subprocess
import sys
import time

APT_LOCKS = (
    "/var/lib/dpkg/lock-frontend",
    "/var/lib/dpkg/lock",
    "/var/lib/apt/lists/lock",
    "/var/cache/apt/archives/lock",
)
LOCK_ERROR = "file /var/lib/dpkg/lock-frontend or /var/lib/apt/lists/lock is still busy"


def wait_for_apt(deadline):
    while True:
        busy = None
        with contextlib.ExitStack() as locks:
            for path in APT_LOCKS:
                try:
                    lock = locks.enter_context(open(path, "r+"))
                except FileNotFoundError:
                    continue
                try:
                    # dpkg uses POSIX record locks, not flock or lock-file existence.
                    fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError as error:
                    if error.errno not in (errno.EACCES, errno.EAGAIN):
                        raise
                    busy = path
                    break
        if busy is None:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SystemExit(f"Ubuntu package manager is still busy at {busy} after the 30-minute Arc installation lock-wait limit.")
        print(f"Waiting for Ubuntu package updates to release {busy} ({int(remaining)} seconds left).", flush=True)
        time.sleep(min(10, remaining))


def install_agent(installer):
    deadline = time.monotonic() + 1800
    while True:
        wait_for_apt(deadline)
        lock_failure = False
        with subprocess.Popen(["bash", installer], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
            for line in process.stdout:
                print(line, end="", flush=True)
                if LOCK_ERROR in line:
                    lock_failure = True
            exit_code = process.wait()
        if exit_code == 0:
            return
        if not lock_failure or time.monotonic() >= deadline:
            raise SystemExit(exit_code)
        print("Ubuntu updates acquired an apt lock during Arc installation; retrying within the original deadline.", flush=True)


install_agent(sys.argv[1])
PY
fi

ArcServerResourceName=$(hostname)

# Run connect command
azcmagent connect --access-token "$accessToken" --resource-group "$resourceGroup" --tenant-id "$tenantId" --location "$Azurelocation" --subscription-id "$subscriptionId" --resource-name "${ArcServerResourceName}" --cloud "AzureCloud" --correlation-id "d009f5dd-dba8-4ac7-bac9-b54ef3a6671a"
