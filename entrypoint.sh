#!/bin/bash
set -e

# Path to the auth config
DATA_DIR=${VPNGATE_DATA_DIR:-"/opt/aimilivpn/vpngate_data"}
mkdir -p "$DATA_DIR"
mkdir -p "$DATA_DIR/custom"

# Download Let's Encrypt Gen-Y and intermediate certificates for OpenVPN validation
echo "Downloading Let's Encrypt intermediate certificates..."
mkdir -p /opt/aimilivpn/certs
cd /opt/aimilivpn/certs
for url in https://letsencrypt.org/certs/2024/r10.pem \
           https://letsencrypt.org/certs/2024/r11.pem \
           https://letsencrypt.org/certs/2024/r12.pem \
           https://letsencrypt.org/certs/2024/r13.pem \
           https://letsencrypt.org/certs/2024/r14.pem \
           https://letsencrypt.org/certs/gen-y/root-ye.pem \
           https://letsencrypt.org/certs/gen-y/root-ye-by-x2.pem \
           https://letsencrypt.org/certs/gen-y/root-yr.pem \
           https://letsencrypt.org/certs/gen-y/root-yr-by-x1.pem \
           https://letsencrypt.org/certs/gen-y/int-ye1.pem \
           https://letsencrypt.org/certs/gen-y/int-ye2.pem \
           https://letsencrypt.org/certs/gen-y/int-yr1.pem \
           https://letsencrypt.org/certs/gen-y/int-yr2.pem; do
  curl -s -S -O "$url" || true
done
cat *.pem >> /etc/ssl/certs/ca-certificates.crt || true
cd /opt/aimilivpn

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
            print('Successfully patched vpngate_manager.py for custom nodes!', flush=True)
        else:
            print('Failed to find patch target in vpngate_manager.py!', flush=True)

        # Fix infinite background thread loop in auto_switch_node
        target_loop = '''        def bg_fetch_and_switch():
            try:
                maintain_valid_nodes(force=False)
                auto_switch_node()
            except Exception as e:
                print(f\"[自动切换后台补齐] 获取并测试节点失败: {e}\", flush=True)
        
        threading.Thread(target=bg_fetch_and_switch, daemon=True).start()'''
        if target_loop in content:
            content = content.replace(target_loop, '        pass')
            print('Successfully patched vpngate_manager.py to fix infinite thread loop!', flush=True)
        else:
            print('Failed to find infinite thread loop patch target in vpngate_manager.py!', flush=True)

        # Inject prepare_config_text helper function
        target_state = 'STATE_FILE = DATA_DIR / \"state.json\"'
        replacement_state = '''STATE_FILE = DATA_DIR / \"state.json\"

def prepare_config_text(config_text: str) -> str:
    try:
        from pathlib import Path
        ca_path = Path(\"/etc/ssl/certs/ca-certificates.crt\")
        if ca_path.exists():
            ca_content = ca_path.read_text(encoding=\"utf-8\")
            if \"</ca>\" in config_text:
                config_text = config_text.replace(\"</ca>\", f\"\\\\n{ca_content}\\\\n</ca>\")
    except Exception:
        pass
    return config_text'''
        if target_state in content and 'def prepare_config_text' not in content:
            content = content.replace(target_state, replacement_state)
            print('Successfully injected prepare_config_text helper!', flush=True)

        # Patch test_worker and test_node_by_id to use prepare_config_text
        target_write = 'temp_path.write_text(config_text, encoding=\"utf-8\")'
        replacement_write = 'temp_path.write_text(prepare_config_text(config_text), encoding=\"utf-8\")'
        if target_write in content:
            content = content.replace(target_write, replacement_write)
            print('Successfully patched config writing to use prepare_config_text!', flush=True)

        # Patch connect_node to use prepare_config_text
        target_connect = 'config_path.write_text(node.get(\"config_text\") or \"\", encoding=\"utf-8\")'
        replacement_connect = 'config_path.write_text(prepare_config_text(node.get(\"config_text\") or \"\"), encoding=\"utf-8\")'
        if target_connect in content:
            content = content.replace(target_connect, replacement_connect)
            print('Successfully patched connect_node to use prepare_config_text!', flush=True)

        # Optimize /api/logs to use deque and release lock quickly
        target_logs = '''        elif effective_path == \"/api/logs\":
            logs_dir = DATA_DIR / \"logs\"
            date_str = time.strftime(\"%Y-%m-%d\", time.localtime())
            log_file = logs_dir / f\"{date_str}.json\"
            entries = []
            if log_file.exists():
                try:
                    with lock:
                        with open(log_file, \"r\", encoding=\"utf-8\") as f:
                            for line in f:
                                line = line.strip()
                                if line:
                                    try:
                                        entries.append(json.loads(line))
                                    except Exception:
                                        pass'''
        replacement_logs = '''        elif effective_path == \"/api/logs\":
            logs_dir = DATA_DIR / \"logs\"
            date_str = time.strftime(\"%Y-%m-%d\", time.localtime())
            log_file = logs_dir / f\"{date_str}.json\"
            entries = []
            if log_file.exists():
                try:
                    from collections import deque
                    with lock:
                        with open(log_file, \"r\", encoding=\"utf-8\") as f:
                            lines = deque(f, maxlen=1000)
                    for line in lines:
                        line = line.strip()
                        if line:
                            try:
                                entries.append(json.loads(line))
                            except Exception:
                                pass'''
        if target_logs in content:
            content = content.replace(target_logs, replacement_logs)
            print('Successfully optimized /api/logs with deque!', flush=True)

        file_path.write_text(content, encoding='utf-8')
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
