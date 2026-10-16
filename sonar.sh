#!/usr/bin/env bash
set -Eeuo pipefail

# Install SonarQube Community Build on Ubuntu.
# This script is intended for a fresh installation.

SONAR_VERSION="26.9.0.129388"
SONAR_HOME="/opt/sonarqube"
SONAR_ARCHIVE="sonarqube-${SONAR_VERSION}.zip"
SONAR_URL="https://binaries.sonarsource.com/Distribution/sonarqube/${SONAR_ARCHIVE}"
SONAR_DB="sonarqube"
SONAR_USER="sonar"

# Require root privileges.
if [[ "$EUID" -ne 0 ]]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Prevent accidental replacement of an existing installation.
if [[ -e "$SONAR_HOME" ]]; then
    echo "ERROR: $SONAR_HOME already exists."
    echo "Back up the existing installation before proceeding."
    exit 1
fi

# Request a database password without displaying it.
read -rsp "Enter a strong PostgreSQL password for SonarQube: " SONAR_DB_PASSWORD
echo
read -rsp "Confirm the PostgreSQL password: " SONAR_DB_PASSWORD_CONFIRM
echo

if [[ "$SONAR_DB_PASSWORD" != "$SONAR_DB_PASSWORD_CONFIRM" ]]; then
    echo "ERROR: Passwords do not match."
    exit 1
fi

if [[ -z "$SONAR_DB_PASSWORD" ]]; then
    echo "ERROR: The password cannot be empty."
    exit 1
fi

export SONAR_DB_PASSWORD

# Update Ubuntu packages and install dependencies.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openjdk-21-jdk \
    postgresql \
    postgresql-contrib \
    unzip \
    curl \
    python3

# Verify the Java installation.
java -version

# Configure required Linux kernel parameters.
cat > /etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=524288
fs.file-max=131072
EOF

sysctl --system

# Configure resource limits for the SonarQube account.
cat > /etc/security/limits.d/99-sonarqube.conf <<'EOF'
sonar - nofile 131072
sonar - nproc 8192
EOF

# Start PostgreSQL.
systemctl enable --now postgresql

# Create the dedicated Linux service account FIRST
if ! id "$SONAR_USER" &>/dev/null; then
    groupadd --system "$SONAR_USER"
    useradd --system \
        --gid "$SONAR_USER" \
        --home-dir "$SONAR_HOME" \
        --shell /usr/sbin/nologin \
        "$SONAR_USER"
fi

# Create the dedicated PostgreSQL user and database.
if ! runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname = '$SONAR_USER'" | grep -q 1; then
    runuser -u postgres -- psql \
        -v ON_ERROR_STOP=1 \
        -c "CREATE USER $SONAR_USER WITH ENCRYPTED PASSWORD '$(echo "$SONAR_DB_PASSWORD" | sed "s/'/''/g")';"
else
    echo "PostgreSQL user '$SONAR_USER' already exists; keeping the existing role."
fi


if ! runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$SONAR_DB'" | grep -q 1; then
    runuser -u postgres -- createdb \
        --owner="$SONAR_USER" \
        --encoding=UTF8 \
        "$SONAR_DB"
else
    echo "Database '$SONAR_DB' already exists; keeping the existing database."
fi

# Download and extract the official SonarQube distribution.
cd /tmp
curl -fL --retry 3 "$SONAR_URL" -o "$SONAR_ARCHIVE"
unzip -q "$SONAR_ARCHIVE"

# Install SonarQube.
mv "/tmp/sonarqube-${SONAR_VERSION}" "$SONAR_HOME"

# Set ownership and restore executable permissions.
chown -R sonar:sonar "$SONAR_HOME"
find "$SONAR_HOME/bin" -type f -name '*.sh' -exec chmod 755 {} +

# Explicitly ensure that the Linux startup script is executable.
chmod +x "$SONAR_HOME/bin/linux-x86-64/sonar.sh"

# Configure the PostgreSQL connection while preserving other settings.
SONAR_HOME="$SONAR_HOME" python3 <<'PY'
import os
from pathlib import Path

config = Path(os.environ["SONAR_HOME"]) / "conf" / "sonar.properties"
password = os.environ["SONAR_DB_PASSWORD"]

# Avoid property-file parsing issues with special characters.
if any(c in password for c in "\r\n"):
    raise SystemExit("ERROR: Password must not contain newline characters.")

updates = {
    "sonar.jdbc.username": "sonar",
    "sonar.jdbc.password": password,
    "sonar.jdbc.url": "jdbc:postgresql://localhost:5432/sonarqube",
    "sonar.web.port": "9000",
}

lines = config.read_text().splitlines()
for key, value in updates.items():
    matching = [
        i for i, line in enumerate(lines)
        if line.lstrip().startswith(key + "=")
    ]
    replacement = f"{key}={value}"
    if matching:
        lines[matching[0]] = replacement
        for i in reversed(matching[1:]):
            del lines[i]
    else:
        lines.append(replacement)

config.write_text("\n".join(lines) + "\n")
PY

chown sonar:sonar "$SONAR_HOME/conf/sonar.properties"
chmod 600 "$SONAR_HOME/conf/sonar.properties"

# Create the systemd service.
cat > /etc/systemd/system/sonar.service <<'EOF'
[Unit]
Description=SonarQube Server
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=forking
User=sonar
Group=sonar
WorkingDirectory=/opt/sonarqube

ExecStart=/opt/sonarqube/bin/linux-x86-64/sonar.sh start
ExecStop=/opt/sonarqube/bin/linux-x86-64/sonar.sh stop

Restart=on-failure
RestartSec=10

LimitNOFILE=131072
LimitNPROC=8192

TimeoutStartSec=300
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable SonarQube at boot.
systemctl daemon-reload
systemctl enable sonar

# Start SonarQube.
systemctl start sonar

# Remove the downloaded archive.
rm -f "/tmp/$SONAR_ARCHIVE"

# Display the service status.
systemctl status sonar --no-pager -l || true

echo
echo "Installation commands completed."
echo "Check startup logs with:"
echo "  journalctl -u sonar -n 100 --no-pager"
echo "  tail -n 100 $SONAR_HOME/logs/sonar.log"
echo
echo "Web interface: http://SERVER_IP:9000"
echo "Initial login: admin / admin"
echo "Change the default password at first login."