#!/bin/bash
set -e

# Path to the auth config
DATA_DIR=${VPNGATE_DATA_DIR:-"/opt/aimilivpn/vpngate_data"}
mkdir -p "$DATA_DIR"
AUTH_FILE="$DATA_DIR/ui_auth.json"

# Default values if not specified
ROUTING_MODE=${ROUTING_MODE:-"auto"}
FORCE_COUNTRY=${FORCE_COUNTRY:-""}
ROUTING_IP_TYPE=${ROUTING_IP_TYPE:-"all"}

# If ui_auth.json doesn't exist, create it with env values
if [ ! -f "$AUTH_FILE" ]; then
  echo "Initializing $AUTH_FILE with environment variables..."
  cat <<EOF > "$AUTH_FILE"
{
  "routing_mode": "${ROUTING_MODE}",
  "force_country": "${FORCE_COUNTRY}",
  "routing_ip_type": "${ROUTING_IP_TYPE}",
  "connection_enabled": true
}
EOF
else
  # If it exists, update it using python
  echo "Updating existing $AUTH_FILE with environment variables..."
  python3 -c "
import json, os
from pathlib import Path
p = Path('$AUTH_FILE')
try:
    data = json.loads(p.read_text(encoding='utf-8'))
except Exception:
    data = {}
data['routing_mode'] = os.environ.get('ROUTING_MODE', data.get('routing_mode', 'auto'))
data['force_country'] = os.environ.get('FORCE_COUNTRY', data.get('force_country', ''))
data['routing_ip_type'] = os.environ.get('ROUTING_IP_TYPE', data.get('routing_ip_type', 'all'))
p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')
"
fi

# Execute the main command
exec "$@"
