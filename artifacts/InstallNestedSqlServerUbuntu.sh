#!/bin/bash
set -euo pipefail
umask 077

mode=${1:?Specify Developer or Evaluation}
case "$mode" in
    Developer|Evaluation) ;;
    *) echo "Unsupported SQL installation mode: $mode" >&2; exit 1 ;;
esac
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this installer as root." >&2
    exit 1
fi
. /etc/os-release
if [ "$ID" != ubuntu ] || [ "$VERSION_ID" != 24.04 ]; then
    echo "This installer requires Ubuntu 24.04." >&2
    exit 1
fi

# Read the shared secret over stdin, never from a process argument or saved script.
IFS= read -r MSSQL_SA_PASSWORD
test -n "$MSSQL_SA_PASSWORD"
export MSSQL_SA_PASSWORD
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
export ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive
trap 'if [ -n "${backup:-}" ]; then rm -f "$backup.download"; fi; unset MSSQL_SA_PASSWORD SQLCMDPASSWORD' EXIT

curl --fail --location --max-time 300 https://packages.microsoft.com/keys/microsoft.asc |
    gpg --batch --yes --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
curl --fail --location --max-time 300 https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list \
    -o /etc/apt/sources.list.d/mssql-server-2025.list
curl --fail --location --max-time 300 https://packages.microsoft.com/config/ubuntu/24.04/prod.list \
    -o /etc/apt/sources.list.d/microsoft-prod.list
timeout --kill-after=30s 30m apt-get -o DPkg::Lock::Timeout=300 update
timeout --kill-after=30s 30m apt-get -o DPkg::Lock::Timeout=300 install -y mssql-server mssql-tools18 unixodbc-dev
if [ ! -f /var/opt/mssql/data/master.mdf ]; then
    MSSQL_PID="$mode"
    if [ "$mode" = Developer ]; then MSSQL_PID=EnterpriseDeveloper; fi
    export MSSQL_PID MSSQL_MEMORY_LIMIT_MB=2048
    timeout --kill-after=30s 15m /opt/mssql/bin/mssql-conf -n setup
fi
/opt/mssql/bin/mssql-conf set memory.memorylimitmb 2048
systemctl enable mssql-server
systemctl restart mssql-server
sqlcmd=/opt/mssql-tools18/bin/sqlcmd
ready=false
for attempt in $(seq 1 60); do
    if "$sqlcmd" -S localhost -U sa -C -b -l 10 -Q 'SELECT 1' >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 10
done
if [ "$ready" != true ]; then
    echo "SQL Server did not become queryable." >&2
    exit 1
fi
edition=$("$sqlcmd" -S localhost -U sa -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128));")
if [ "$mode" = Developer ]; then
    [[ "$edition" == *Developer* ]] || { echo "Existing SQL edition does not match Developer." >&2; exit 1; }
else
    [[ "$edition" == *Evaluation* || "$edition" == "Standard Edition"* || "$edition" == "Enterprise Edition"* ]] ||
        { echo "Existing SQL edition does not match Evaluation or a licensed conversion." >&2; exit 1; }
fi
"$sqlcmd" -S localhost -U sa -C -b -Q "IF CAST(SERVERPROPERTY('ProductMajorVersion') AS int) <> 17 THROW 51000, 'Expected SQL Server 2025', 1;"

install -d -o mssql -g mssql -m 750 /var/opt/mssql/backup
sample_exists=$("$sqlcmd" -S localhost -U sa -C -b -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name=N'AdventureWorksLT2025';")
if [ "$(echo "$sample_exists" | tr -d '[:space:]')" = 0 ]; then
    backup=/var/opt/mssql/backup/AdventureWorksLT2025.bak
    curl --fail --location --retry 3 --max-time 3600 \
        https://github.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksLT2025.bak \
        -o "$backup.download"
    mv "$backup.download" "$backup"
    chown mssql:mssql "$backup"
    chmod 640 "$backup"
    file_list=$("$sqlcmd" -S localhost -U sa -C -b -h -1 -W -s '|' -Q "SET NOCOUNT ON; RESTORE FILELISTONLY FROM DISK=N'$backup';")
    moves=''
    index=0
    while IFS='|' read -r logical_name _ file_type _; do
        test -n "$logical_name" || continue
        case "$file_type" in
            D) suffix=mdf ;;
            L) suffix=ldf ;;
            *) echo "Unsupported AdventureWorks backup file type: $file_type" >&2; exit 1 ;;
        esac
        logical_name=${logical_name//\'/\'\'}
        index=$((index + 1))
        moves="${moves}MOVE N'$logical_name' TO N'/var/opt/mssql/data/AdventureWorksLT2025_${index}.${suffix}', "
    done <<< "$file_list"
    test "$index" -gt 0
    "$sqlcmd" -S localhost -U sa -C -b -t 1800 -Q \
        "RESTORE DATABASE [AdventureWorksLT2025] FROM DISK=N'$backup' WITH ${moves}RECOVERY;"
fi
"$sqlcmd" -S localhost -U sa -C -b -t 1800 <<'SQL'
IF DB_ID(N'ArchiveDB') IS NULL
    CREATE DATABASE [ArchiveDB];
GO
USE [ArchiveDB];
GO
IF OBJECT_ID(N'dbo.Records', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Records (
        Id uniqueidentifier ROWGUIDCOL NOT NULL UNIQUE,
        SerialNumber int UNIQUE,
        Chart varbinary(max) NULL
    );
END;
GO
ALTER DATABASE [ArchiveDB] SET RECOVERY FULL;
ALTER DATABASE [AdventureWorksLT2025] SET RECOVERY FULL;
GO
BEGIN TRANSACTION;
DECLARE @id uniqueidentifier = NEWID();
INSERT dbo.Records (Id, SerialNumber, Chart) VALUES (@id, -2147483648, 0x417263426F78);
IF NOT EXISTS (SELECT 1 FROM dbo.Records WHERE Id=@id AND Chart=0x417263426F78)
    THROW 51000, 'ArchiveDB binary round-trip failed', 1;
ROLLBACK;
SELECT TOP (1) CustomerID FROM AdventureWorksLT2025.SalesLT.Customer;
GO
SQL
echo "SQL Server 2025 ($edition) is ready with AdventureWorksLT2025 and ArchiveDB (non-FILESTREAM)."
