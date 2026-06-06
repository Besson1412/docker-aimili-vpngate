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

# Patch vpngate_manager.py to optimize node checking and logs performance
cat << 'EOF' > /tmp/patch_vpngate.py
from pathlib import Path
import time
import json
import re
import threading
import concurrent.futures
from typing import Any

file_path = Path('/opt/aimilivpn/vpngate_manager.py')
if file_path.exists():
    content = file_path.read_text(encoding='utf-8')

    # 0. Patch is_connecting initial value to False
    if 'is_connecting = True' in content:
        content = content.replace('is_connecting = True', 'is_connecting = False')
        print("Successfully patched is_connecting initial value to False", flush=True)
    else:
        print("Successfully patched is_connecting initial value to False (already patched or not found)", flush=True)

    # 1. Patch lock block to add nodes_updating_lock
    if 'nodes_updating_lock = threading.Lock()' not in content:
        new_content = content.replace('lock = threading.RLock()', '''lock = threading.RLock()
nodes_updating_lock = threading.Lock()''')
        if new_content != content:
            content = new_content
            print("Successfully injected nodes_updating_lock definition", flush=True)
        else:
            print("ERROR: Failed to inject nodes_updating_lock!", flush=True)
    else:
        print("Successfully injected nodes_updating_lock definition (already patched)", flush=True)

    # 2. Inject helpers
    if 'def prepare_config_text' not in content:
        helper_code = '''STATE_FILE = DATA_DIR / "state.json"

def prepare_config_text(config_text: str) -> str:
    try:
        from pathlib import Path
        ca_path = Path("/etc/ssl/certs/ca-certificates.crt")
        if ca_path.exists():
            ca_content = ca_path.read_text(encoding="utf-8")
            if "</ca>" in config_text:
                config_text = config_text.replace("</ca>", f"\\n{ca_content}\\n</ca>")
    except Exception:
        pass
    return config_text

def read_last_log_lines(file_path, max_lines=1000):
    lines = []
    if not file_path.exists():
        return lines
    chunk_size = 8192
    try:
        with open(file_path, "rb") as f:
            f.seek(0, 2)
            pointer = f.tell()
            buffer = bytearray()
            while pointer > 0 and len(lines) <= max_lines:
                read_amt = min(chunk_size, pointer)
                pointer -= read_amt
                f.seek(pointer)
                buffer = f.read(read_amt) + buffer
                while b"\\n" in buffer and len(lines) <= max_lines:
                    nl_idx = buffer.rfind(b"\\n")
                    line_bytes = buffer[nl_idx + 1:]
                    buffer = buffer[:nl_idx]
                    line_str = line_bytes.decode("utf-8", errors="ignore").strip()
                    if line_str:
                        lines.append(line_str)
            if len(lines) <= max_lines and buffer:
                line_str = buffer.decode("utf-8", errors="ignore").strip()
                if line_str:
                    lines.append(line_str)
    except Exception:
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                from collections import deque
                return [l.strip() for l in deque(f, maxlen=max_lines)]
        except Exception:
            pass
    lines.reverse()
    return lines'''
        new_content = content.replace('STATE_FILE = DATA_DIR / "state.json"', helper_code)
        if new_content != content:
            content = new_content
            print("Successfully injected helper functions", flush=True)
        else:
            print("ERROR: Failed to inject helper functions!", flush=True)
    else:
        print("Successfully injected helper functions (already patched)", flush=True)

    # 3. Patch test_worker and connect_node config writing to use prepare_config_text
    content = content.replace('temp_path.write_text(config_text, encoding="utf-8")', 'temp_path.write_text(prepare_config_text(config_text), encoding="utf-8")')
    content = content.replace('config_path.write_text(node.get("config_text") or "", encoding="utf-8")', 'config_path.write_text(prepare_config_text(node.get("config_text") or ""), encoding="utf-8")')

    # 4. Patch get_state() to add is_updating_nodes
    if 'state["is_updating_nodes"]' not in content:
        target_state = 'state["is_connecting"] = is_connecting'
        replacement_state = '''state["is_connecting"] = is_connecting
    state["is_updating_nodes"] = nodes_updating_lock.locked()'''
        new_content = content.replace(target_state, replacement_state)
        if new_content != content:
            content = new_content
            print("Successfully updated get_state() with is_updating_nodes", flush=True)
        else:
            print("ERROR: Failed to update get_state() with is_updating_nodes!", flush=True)
    else:
        print("Successfully updated get_state() with is_updating_nodes (already patched)", flush=True)

    # 5. Patch fetch_candidates() to load custom nodes
    if 'Load custom nodes from vpngate_data/custom/' not in content:
        target_fetch = """    log_to_json("INFO", "Main", f"成功获取官方 API 节点，共 {len(candidates)} 个候选节点")
    return candidates"""
        replacement_fetch = """    log_to_json("INFO", "Main", f"成功获取官方 API 节点，共 {len(candidates)} 个候选节点")
    
    # Load custom nodes from vpngate_data/custom/
    custom_dir = DATA_DIR / "custom"
    if custom_dir.exists():
        try:
            for path in custom_dir.glob("*.ovpn"):
                try:
                    config_text = path.read_text(encoding="utf-8")
                    h, p, pr = vpn_utils.parse_remote(config_text, "")
                    if not h:
                        continue
                    parts = path.stem.split("_")
                    country_short = "TW"
                    country_zh = "台湾"
                    if len(parts) > 1:
                        c_code = parts[0].upper()
                        if c_code == "TW" or c_code == "TAIWAN":
                            country_short = "TW"
                            country_zh = "台湾"
                        elif c_code == "JP" or c_code == "JAPAN":
                            country_short = "JP"
                            country_zh = "日本"
                        elif c_code == "US" or c_code == "USA":
                            country_short = "US"
                            country_zh = "美国"
                        else:
                            country_short = c_code
                            country_zh = vpn_utils.COUNTRY_TRANSLATIONS.get(c_code, c_code)
                    
                    c_id = safe_name(f"Custom_{path.stem}")
                    custom_node = {
                        "id": c_id,
                        "country": country_zh,
                        "country_short": country_short,
                        "host_name": path.stem,
                        "ip": h,
                        "score": 999999,
                        "ping": 1,
                        "speed": 100000000,
                        "sessions": 0,
                        "owner": "Custom Private Node",
                        "asn": "",
                        "as_name": "",
                        "location": "",
                        "ip_type": "residential",
                        "quality": "Stable",
                        "latency_ms": 0,
                        "config_file": str(CONFIG_DIR / f"{c_id}.ovpn"),
                        "config_text": config_text,
                        "proto": pr,
                        "remote_host": h,
                        "remote_port": p,
                        "fetched_at": time.time(),
                        "probe_status": "not_checked",
                        "probe_message": "",
                        "probed_at": 0,
                    }
                    candidates.insert(0, custom_node)
                    print(f"[Custom Node] Loaded custom OpenVPN config: {path.name} ({country_zh})", flush=True)
                except Exception as ce:
                    print(f"[Custom Node Error] Failed to load {path.name}: {ce}", flush=True)
        except Exception as e:
            print(f"[Custom Node Error] Error scanning custom dir: {e}", flush=True)
    return candidates"""
        new_content = content.replace(target_fetch, replacement_fetch)
        if new_content != content:
            content = new_content
            print("Successfully patched fetch_candidates() for custom nodes", flush=True)
        else:
            print("ERROR: Failed to patch fetch_candidates() for custom nodes!", flush=True)
    else:
        print("Successfully patched fetch_candidates() for custom nodes (already patched)", flush=True)

    # 6. Entire Block Replacement: test_multiple_nodes
    start = content.find("def test_multiple_nodes(node_ids: list[str])")
    end = content.find("def auto_switch_node(attempt: int = 0)")
    if start != -1 and end != -1:
        if 'updated_nodes_map = {}' in content[start:end]:
            print("Successfully replaced test_multiple_nodes block (already patched)", flush=True)
        else:
            new_test_fn = """def test_multiple_nodes(node_ids: list[str]) -> list[dict[str, Any]]:
    with lock:
        nodes = read_json(NODES_FILE, [])
        to_test = [n for n in nodes if n.get("id") in node_ids]
        
    def test_worker(args: tuple[int, dict[str, Any]]) -> dict[str, Any]:
        idx, n_info = args
        node_id = n_info["id"]
        config_file = n_info["config_file"]
        config_text = n_info.get("config_text") or ""
        h = str(n_info.get("remote_host") or n_info.get("ip"))
        p = parse_int(n_info.get("remote_port"))
        fallback_ping = parse_int(n_info.get("ping"))
        
        temp_path = Path(config_file)
        try:
            CONFIG_DIR.mkdir(exist_ok=True, parents=True)
            temp_path.write_text(prepare_config_text(config_text), encoding="utf-8")
        except Exception as e:
            return {
                "id": node_id,
                "latency_ms": 0,
                "probe_status": "unavailable",
                "probe_message": f"Failed to write configuration: {e}",
                "probed_at": time.time(),
                "owner": "",
                "asn": "",
                "as_name": "",
                "location": "",
                "ip_type": "",
                "quality": "",
            }
            
        latency = vpn_utils.ping_latency_ms(h, p, fallback_ping)
        tun_idx = get_free_test_index()
        dev_name = f"tun{tun_idx}"
        try:
            ok, message, _ = run_openvpn_until_ready(config_file, keep_alive=False, route_nopull=True, timeout=12, dev=dev_name)
        finally:
            release_test_index(tun_idx)
            try:
                if temp_path.exists():
                    temp_path.unlink()
            except Exception:
                pass
            
        temp_node = {
            "id": node_id,
            "ip": n_info.get("ip") or h,
            "remote_host": h,
            "remote_port": p,
            "latency_ms": latency,
            "probe_status": "available" if ok else "unavailable",
            "probe_message": message,
            "probed_at": time.time(),
            "owner": "",
            "asn": "",
            "as_name": "",
            "location": "",
            "ip_type": "",
            "quality": "",
        }
        return temp_node

    updated_nodes_map = {}
    max_workers = min(30, max(1, len(to_test)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(test_worker, (idx, n)): n["id"] for idx, n in enumerate(to_test)}
        for future in concurrent.futures.as_completed(futures):
            nid = futures[future]
            try:
                res = future.result()
            except Exception as e:
                res = {
                    "id": nid,
                    "probe_status": "unavailable",
                    "probe_message": f"Test exception: {e}",
                    "latency_ms": 0,
                    "probed_at": time.time()
                }
            updated_nodes_map[nid] = res
            
            with lock:
                current_nodes = read_json(NODES_FILE, [])
                for n in current_nodes:
                    if n.get("id") == nid:
                        n.update(res)
                        break
                sorted_nodes = sort_all_nodes(current_nodes)
                write_json(NODES_FILE, sorted_nodes)
                
    successful_nodes = [res for res in updated_nodes_map.values() if res.get("probe_status") == "available"]
    if successful_nodes:
        try:
            vpn_utils.enrich_ip_info(successful_nodes)
            with lock:
                current_nodes = read_json(NODES_FILE, [])
                for n in current_nodes:
                    nid = n.get("id")
                    if nid in updated_nodes_map and updated_nodes_map[nid].get("probe_status") == "available":
                        enriched = next((sn for sn in successful_nodes if sn.get("id") == nid), None)
                        if enriched:
                            n.update(enriched)
                sorted_nodes = sort_all_nodes(current_nodes)
                write_json(NODES_FILE, sorted_nodes)
        except Exception as ee:
            print(f"[test_multiple_nodes] 批量富化 IP 失败: {ee}", flush=True)
        
    return list(updated_nodes_map.values())"""
            content = content[:start] + new_test_fn + "\n\n" + content[end:]
            print("Successfully replaced test_multiple_nodes block", flush=True)
    else:
        print("ERROR: Could not find start or end for test_multiple_nodes block!", flush=True)

    # 7. Entire Block Replacement: auto_switch_node
    start = content.find("def auto_switch_node(attempt: int = 0)")
    end = content.find("def connect_node(node_id: str) -> str:")
    if start != -1 and end != -1:
        if '连续切换失败已达 3 次' in content[start:end]:
            print("Successfully replaced auto_switch_node block (already patched)", flush=True)
        else:
            new_switch_fn = """def auto_switch_node(attempt: int = 0) -> None:
    if attempt >= 3:
        print("[自动切换] 连续切换失败已达 3 次，停止切换以防止主线程死锁，将在后台重新加载节点...", flush=True)
        return
        
    ui_cfg = load_ui_config()
    connection_enabled = ui_cfg.get("connection_enabled", True)
    if not connection_enabled:
        print("[自动切换] 连接已禁用，不进行自动切换。", flush=True)
        return

    routing_mode = ui_cfg.get("routing_mode", "auto")
    target_country = ui_cfg.get("force_country", "")

    if routing_mode == "fixed_ip":
        print("[自动切换] 当前处于固定 IP 模式，不进行自动连接或切换。", flush=True)
        return

    with lock:
        nodes = read_json(NODES_FILE, [])
        candidates = [
            n for n in nodes 
            if n.get("probe_status") == "available" 
            and not n.get("active")
        ]
        
        if routing_mode == "fixed_region" and target_country:
            candidates = [
                n for n in candidates 
                if n.get("country") == target_country 
                or vpn_utils.COUNTRY_TRANSLATIONS.get(n.get("country", ""), n.get("country", "")) == target_country
            ]
        if routing_mode == "favorites":
            fav_ids = set(ui_cfg.get("favorite_node_ids", []))
            fav_candidates = [n for n in candidates if n.get("id") in fav_ids]
            if fav_candidates:
                candidates = fav_candidates
            else:
                fav_fail_fallback = ui_cfg.get("fav_fail_fallback", True)
                if not fav_fail_fallback:
                    candidates = []
            
        routing_ip_type = ui_cfg.get("routing_ip_type", "all")
        if routing_ip_type == "residential":
            candidates = [n for n in candidates if n.get("ip_type") in ("residential", "mobile")]
        elif routing_ip_type == "hosting":
            candidates = [n for n in candidates if n.get("ip_type") == "hosting"]
            
        candidates.sort(key=lambda n: (parse_int(n.get("latency_ms")) or 999999, -parse_int(n.get("score"))))
        
    if candidates:
        next_node = candidates[0]
        msg = f"当前连接已失效或代理连通性检测失败，正在自动切换至最佳备用节点: {next_node['id']}"
        print(f"[自动切换] {msg}", flush=True)
        log_to_json("INFO", "VPN", msg)
        try:
            connect_node(next_node["id"])
        except Exception as e:
            err_msg = f"切换到备用节点 {next_node['id']} 失败: {e}，将尝试下一个..."
            print(f"[自动切换] {err_msg}", flush=True)
            log_to_json("WARNING", "VPN", err_msg)
            auto_switch_node(attempt + 1)
    else:
        msg = "没有可用的备选节点，将自动断开并清理当前连接状态，并在后台周期任务中重新拉取节点..."
        if routing_mode == "fixed_region" and target_country:
            msg = f"没有可用的【{target_country}】备选节点，已断开连接，将在后台周期任务中继续尝试获取新节点..."
        print(f"[自动切换] {msg}", flush=True)
        log_to_json("WARNING", "VPN", msg)
        stop_active_openvpn()
        with lock:
            nodes = read_json(NODES_FILE, [])
            for item in nodes:
                item["active"] = False
            write_json(NODES_FILE, nodes)
        set_state(active_openvpn_node_id="", last_check_message=msg)"""
            content = content[:start] + new_switch_fn + "\n\n" + content[end:]
            print("Successfully replaced auto_switch_node block", flush=True)
    else:
        print("ERROR: Could not find start or end for auto_switch_node block!", flush=True)

    # 8. Entire Block Replacement: maintain_valid_nodes
    start = content.find("def maintain_valid_nodes(force: bool = False)")
    end = content.find("def collector_loop() -> None:")
    if start != -1 and end != -1:
        if 'to_test = to_test[:40]' in content[start:end]:
            print("Successfully replaced maintain_valid_nodes block (already patched)", flush=True)
        else:
            new_maintain_fn = """def maintain_valid_nodes(force: bool = False) -> str:
    global active_openvpn_process, active_openvpn_node_id
    if not nodes_updating_lock.acquire(blocking=False):
        print("[维护线程] 节点更新及检测已在运行中，跳过本次请求", flush=True)
        return "Already updating nodes"
    try:
        ensure_dirs()
        if force:
            with lock:
                stop_active_openvpn()
        elif not active_openvpn_running():
            ui_cfg = load_ui_config()
            routing_mode = ui_cfg.get("routing_mode", "auto")
            connection_enabled = ui_cfg.get("connection_enabled", True)
            if connection_enabled:
                if routing_mode == "fixed_ip":
                    target_id = active_openvpn_node_id or ui_cfg.get("fixed_node_id", "")
                    if target_id:
                        nodes = read_json(NODES_FILE, [])
                        if any(n.get("id") == target_id for n in nodes):
                            print(f"[维护线程] 检测到固定 IP 模式下 OpenVPN 未运行，正在重新拉起同一节点: {target_id}", flush=True)
                            try:
                                connect_node(target_id)
                            except Exception as e:
                                print(f"[维护线程] 重新拉起固定节点 {target_id} 失败: {e}", flush=True)
                else:
                    has_active_id = False
                    with lock:
                        if active_openvpn_node_id:
                            has_active_id = True
                            stop_active_openvpn()
                    if has_active_id:
                        print("[维护线程] 检测到当前 OpenVPN 进程已意外退出，准备自动切换节点", flush=True)
                        auto_switch_node()

        try:
            set_state(last_check_message="正在拉取最新的免费 VPN 节点列表...")
            candidates = fetch_candidates()
        except Exception as exc:
            vpn_utils.check_and_fix_dns()
            diag_msg = str(exc)
            if not any(token in diag_msg for token in ["[ERR_", "错误代码"]):
                err_code, raw_diag = vpn_utils.diagnose_api_failure(API_URL)
                diag_msg = f"[错误代码 {err_code}] 获取节点失败: {exc} | 诊断结果: {raw_diag}"
            set_state(last_fetch_at=time.time(), last_fetch_status="error", last_fetch_message=diag_msg)
            candidates = []

        if not candidates:
            return "没有拉取到新节点"

        with lock:
            active_node = None
            if active_openvpn_node_id:
                current_nodes = read_json(NODES_FILE, [])
                active_node = next((n for n in current_nodes if n.get("id") == active_openvpn_node_id), None)
                
            merged: list[dict[str, Any]] = []
            seen_ids: set[str] = set()
            
            if active_node:
                merged.append(active_node)
                seen_ids.add(active_node["id"])
                
            for cand in candidates:
                if cand["id"] not in seen_ids:
                    merged.append(cand)
                    seen_ids.add(cand["id"])
                    
            if len(merged) > 1000:
                merged = merged[:1000]
                
            for n in merged:
                config_path = Path(n["config_file"])
                if not config_path.exists():
                    try:
                        config_path.write_text(prepare_config_text(n["config_text"]), encoding="utf-8")
                    except Exception:
                        pass
                        
            write_json(NODES_FILE, merged)

        with lock:
            current_nodes = read_json(NODES_FILE, [])
            ui_cfg = load_ui_config()
            routing_mode = ui_cfg.get("routing_mode", "auto")
            target_country = ui_cfg.get("force_country", "")
            fav_ids = set(ui_cfg.get("favorite_node_ids", []))
            
            to_test = [n for n in current_nodes if not n.get("active")]
            
            if routing_mode == "fixed_ip":
                target_id = active_openvpn_node_id or ui_cfg.get("fixed_node_id", "")
                if target_id:
                    to_test = [n for n in to_test if n.get("id") == target_id]
            elif routing_mode == "fixed_region" and target_country:
                target_nodes = []
                for n in to_test:
                    country = n.get("country", "")
                    country_short = n.get("country_short", "")
                    is_custom = n.get("id", "").startswith("Custom_")
                    
                    is_target = (
                        country == target_country 
                        or vpn_utils.COUNTRY_TRANSLATIONS.get(country, country) == target_country
                        or country_short.upper() == target_country.upper()
                    )
                    if is_target or is_custom:
                        target_nodes.append(n)
                to_test = target_nodes
            elif routing_mode == "favorites":
                fav_nodes = []
                other_nodes = []
                for n in to_test:
                    if n.get("id") in fav_ids:
                        fav_nodes.append(n)
                    else:
                        other_nodes.append(n)
                fav_fail_fallback = ui_cfg.get("fav_fail_fallback", True)
                if fav_fail_fallback:
                    to_test = fav_nodes + other_nodes
                else:
                    to_test = fav_nodes
            
            to_test = to_test[:40]
            to_test_ids = [n["id"] for n in to_test]
            
        msg = f"开始对列表中所有候选节点进行周期连通性与延迟测试，待检测节点共 {len(to_test_ids)} 个"
        print(f"[周期检测] {msg}", flush=True)
        log_to_json("INFO", "Main", msg)
        
        set_state(last_check_message="正在并发检测所有节点可用性...")
        test_multiple_nodes(to_test_ids)
        
        with lock:
            merged = read_json(NODES_FILE, [])
            available_nodes = [n["id"] for n in merged if n.get("probe_status") == "available"]
            unavailable_nodes = [n["id"] for n in merged if n.get("probe_status") == "unavailable"]
            active_node = next((n["id"] for n in merged if n.get("active")), "无")
            
            status_report = (
                f"周期节点检测完成。实时同步状态: 获取到候选节点共 {len(merged)} 个。 "
                f"其中【可用节点】{len(available_nodes)} 个: {available_nodes[:15]}...; "
                f"【不可用节点】{len(unavailable_nodes)} 个; "
                f"当前【正在正常运行的活动连接节点】为: {active_node}。"
            )
            print(f"[周期检测] {status_report}", flush=True)
            log_to_json("INFO", "Main", status_report)
            
            if active_node != "无" and not active_openvpn_running():
                warn_msg = f"[诊断警告] 活动节点 {active_node} 被标记为活动状态，但 OpenVPN 进程实际并未正常运行！"
                print(warn_msg, flush=True)
                log_to_json("WARNING", "Main", warn_msg)
            
            if not active_openvpn_running():
                ui_cfg = load_ui_config()
                connection_enabled = ui_cfg.get("connection_enabled", True)
                if connection_enabled:
                    routing_mode = ui_cfg.get("routing_mode", "auto")
                    target_country = ui_cfg.get("force_country", "")
                    
                    if routing_mode != "fixed_ip":
                        available_candidates = [n for n in merged if n.get("probe_status") == "available"]
                        if routing_mode == "fixed_region" and target_country:
                            available_candidates = [
                                n for n in available_candidates 
                                if n.get("country") == target_country 
                                or vpn_utils.COUNTRY_TRANSLATIONS.get(n.get("country", ""), n.get("country", "")) == target_country
                            ]
                        elif routing_mode == "favorites":
                            fav_ids = set(ui_cfg.get("favorite_node_ids", []))
                            fav_candidates = [n for n in available_candidates if n.get("id") in fav_ids]
                            if fav_candidates:
                                available_candidates = fav_candidates
                            else:
                                fav_fail_fallback = ui_cfg.get("fav_fail_fallback", True)
                                if not fav_fail_fallback:
                                    available_candidates = []
                        
                        routing_ip_type = ui_cfg.get("routing_ip_type", "all")
                        if routing_ip_type == "residential":
                            available_candidates = [n for n in available_candidates if n.get("ip_type") in ("residential", "mobile")]
                        elif routing_ip_type == "hosting":
                            available_candidates = [n for n in available_candidates if n.get("ip_type") == "hosting"]
                        
                        if available_candidates:
                            auto_switch_node()

        valid_nodes_count = len([n for n in merged if n.get("probe_status") == "available"])
        message = f"Fetched {len(candidates)} nodes. Tested first {len(to_test_ids)} nodes."
        set_state(
            last_check_at=time.time(),
            last_check_message=message,
            active_openvpn_node_id=active_openvpn_node_id,
            valid_nodes=valid_nodes_count,
        )
        return message
    finally:
        nodes_updating_lock.release()"""
            content = content[:start] + new_maintain_fn + "\n\n" + content[end:]
            print("Successfully replaced maintain_valid_nodes block", flush=True)
    else:
        print("ERROR: Could not find start or end for maintain_valid_nodes block!", flush=True)

    # 9. Patch /api/logs endpoint to use read_last_log_lines
    target_logs = '''        elif effective_path == "/api/logs":
            logs_dir = DATA_DIR / "logs"
            date_str = time.strftime("%Y-%m-%d", time.localtime())
            log_file = logs_dir / f"{date_str}.json"
            entries = []
            if log_file.exists():
                try:
                    with lock:
                        with open(log_file, "r", encoding="utf-8") as f:
                            for line in f:
                                line = line.strip()
                                if line:
                                    try:
                                        entries.append(json.loads(line))
                                    except Exception:
                                        pass'''
    replacement_logs = '''        elif effective_path == "/api/logs":
            logs_dir = DATA_DIR / "logs"
            date_str = time.strftime("%Y-%m-%d", time.localtime())
            log_file = logs_dir / f"{date_str}.json"
            entries = []
            if log_file.exists():
                try:
                    with lock:
                        lines = read_last_log_lines(log_file, 1000)
                    for line in lines:
                        if line:
                            try:
                                entries.append(json.loads(line))
                            except Exception:
                                pass'''
    target_logs_deque = '''        elif effective_path == "/api/logs":
            logs_dir = DATA_DIR / "logs"
            date_str = time.strftime("%Y-%m-%d", time.localtime())
            log_file = logs_dir / f"{date_str}.json"
            entries = []
            if log_file.exists():
                try:
                    from collections import deque
                    with lock:
                        with open(log_file, "r", encoding="utf-8") as f:
                            lines = deque(f, maxlen=1000)
                    for line in lines:
                        line = line.strip()
                        if line:
                            try:
                                entries.append(json.loads(line))
                            except Exception:
                                pass'''

    if 'read_last_log_lines(log_file, 1000)' in content:
        print("Successfully patched /api/logs with read_last_log_lines (already patched)", flush=True)
    elif target_logs in content:
        content = content.replace(target_logs, replacement_logs)
        print("Successfully patched /api/logs with read_last_log_lines", flush=True)
    elif target_logs_deque in content:
        content = content.replace(target_logs_deque, replacement_logs)
        print("Successfully patched deque /api/logs with read_last_log_lines", flush=True)
    else:
        print("ERROR: Failed to patch /api/logs with read_last_log_lines!", flush=True)

    # 10. Patch Javascript to poll when is_updating_nodes is True
    js_target1 = '''  if (state.is_connecting) {
    startConnectionPolling();
  }'''
    js_replacement1 = '''  if (state.is_connecting || state.is_updating_nodes) {
    startConnectionPolling();
  }'''
    
    js_target2 = '''      if (!state.is_connecting) {
        clearInterval(pollInterval);
        pollInterval = null;'''
    js_replacement2 = '''      if (!state.is_connecting && !state.is_updating_nodes) {
        clearInterval(pollInterval);
        pollInterval = null;'''

    if 'state.is_updating_nodes' in content:
        print("Successfully patched Javascript in INDEX_HTML (already patched)", flush=True)
    else:
        new_content = content.replace(js_target1, js_replacement1).replace(js_target2, js_replacement2)
        if new_content != content:
            content = new_content
            print("Successfully patched Javascript in INDEX_HTML", flush=True)
        else:
            print("ERROR: Failed to patch Javascript in INDEX_HTML!", flush=True)

    file_path.write_text(content, encoding='utf-8')
    print("All patches applied to vpngate_manager.py successfully!", flush=True)
EOF
python3 /tmp/patch_vpngate.py
rm -f /tmp/patch_vpngate.py


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
