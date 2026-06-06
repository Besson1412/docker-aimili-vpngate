#!/bin/bash
set -e

# Path to the auth config
DATA_DIR=${VPNGATE_DATA_DIR:-"/opt/aimilivpn/vpngate_data"}
mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/custom"
AUTH_FILE="$DATA_DIR/ui_auth.json"

# Patch vpngate_manager.py to support custom OpenVPN configuration files
python3 -c "
from pathlib import Path
file_path = Path('/opt/aimilivpn/vpngate_manager.py')
if file_path.exists():
    content = file_path.read_text(encoding='utf-8')
    if 'Load custom nodes from vpngate_data/custom/' not in content:
        target = '    log_to_json(\"INFO\", \"Main\", f\"成功获取官方 API 节点，共 {len(candidates)} 个候选节点\")\\n    return candidates'
        replacement = '''    log_to_json(\"INFO\", \"Main\", f\"成功获取官方 API 节点，共 {len(candidates)} 个候选节点\")
    
    # Load custom nodes from vpngate_data/custom/
    custom_dir = DATA_DIR / \"custom\"
    if custom_dir.exists():
        try:
            for path in custom_dir.glob(\"*.ovpn\"):
                try:
                    config_text = path.read_text(encoding=\"utf-8\")
                    h, p, pr = vpn_utils.parse_remote(config_text, \"\")
                    if not h:
                        continue
                    parts = path.stem.split(\"_\")
                    country_short = \"TW\"
                    country_zh = \"台湾\"
                    if len(parts) > 1:
                        c_code = parts[0].upper()
                        if c_code == \"TW\" or c_code == \"TAIWAN\":
                            country_short = \"TW\"
                            country_zh = \"台湾\"
                        elif c_code == \"JP\" or c_code == \"JAPAN\":
                            country_short = \"JP\"
                            country_zh = \"日本\"
                        elif c_code == \"US\" or c_code == \"USA\":
                            country_short = \"US\"
                            country_zh = \"美国\"
                        else:
                            country_short = c_code
                            country_zh = vpn_utils.COUNTRY_TRANSLATIONS.get(c_code, c_code)
                    
                    c_id = safe_name(f\"Custom_{path.stem}\")
                    custom_node = {
                        \"id\": c_id,
                        \"country\": country_zh,
                        \"country_short\": country_short,
                        \"host_name\": path.stem,
                        \"ip\": h,
                        \"score\": 999999,
                        \"ping\": 1,
                        \"speed\": 100000000,
                        \"sessions\": 0,
                        \"owner\": \"Custom Private Node\",
                        \"asn\": \"\",
                        \"as_name\": \"\",
                        \"location\": \"\",
                        \"ip_type\": \"residential\",
                        \"quality\": \"Stable\",
                        \"latency_ms\": 0,
                        \"config_file\": str(CONFIG_DIR / f\"{c_id}.ovpn\"),
                        \"config_text\": config_text,
                        \"proto\": pr,
                        \"remote_host\": h,
                        \"remote_port\": p,
                        \"fetched_at\": time.time(),
                        \"probe_status\": \"not_checked\",
                        \"probe_message\": \"\",
                        \"probed_at\": 0,
                    }
                    candidates.insert(0, custom_node)
                    print(f\"[Custom Node] Loaded custom OpenVPN config: {path.name} ({country_zh})\", flush=True)
                except Exception as ce:
                    print(f\"[Custom Node Error] Failed to load {path.name}: {ce}\", flush=True)
        except Exception as e:
            print(f\"[Custom Node Error] Error scanning custom dir: {e}\", flush=True)
    return candidates'''
        if target in content:
            content = content.replace(target, replacement)
            file_path.write_text(content, encoding='utf-8')
            print('Successfully patched vpngate_manager.py for custom nodes!', flush=True)
        else:
            print('Failed to find patch target in vpngate_manager.py!', flush=True)
"

# Create file if it doesn't exist
if [ ! -f "$AUTH_FILE" ]; then
  echo "Creating empty $AUTH_FILE..."
  echo "{}" > "$AUTH_FILE"
fi

# Update credentials and settings via python
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

if os.environ.get('UI_USERNAME'):
    data['username'] = os.environ['UI_USERNAME']
if os.environ.get('UI_PASSWORD'):
    data['password'] = os.environ['UI_PASSWORD']
if os.environ.get('UI_SECRET_PATH'):
    data['secret_path'] = os.environ['UI_SECRET_PATH']

p.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding='utf-8')
print('Successfully configured ui_auth.json from environment variables!', flush=True)
"

# Execute the main command
exec "$@"
