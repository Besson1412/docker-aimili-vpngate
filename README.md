# docker-aimili-vpngate 🌐

Bilingual: [中文](#中文) | [English](#english)

---

<a name="中文"></a>
## 中文说明

`docker-aimili-vpngate` 是针对开源项目 [baoweise-bot/aimili-vpngate](https://github.com/baoweise-bot/aimili-vpngate)（AimiliVPN）进行容器化封装的项目。

AimiliVPN 是一个借助 `vpngate.net` 开放协议的高性能、零依赖 VPN 代理网关。它能自动抓取节点、自动进行多线程并发测速以筛选延迟最低的节点进行连接，并在当前连接节点失效时**自动漂移（Failover）**至备用节点，从而获取干净的住宅/非数据中心 IP 出站。

本项目的目的是通过 GitHub Actions 自动构建适用于 **`linux/amd64`** 和 **`linux/arm64`** 双架构的 Docker 镜像，以便快速在 container 化网络中进行整合（如作为 V2Ray 的出站代理以解锁流媒体）。

---

### 🚀 快速使用 (Docker Compose)

在您的 `docker-compose.yml` 中新增以下服务：

```yaml
version: '3'

services:
  caddyray_vpngate:
    image: ghcr.io/besson1412/docker-aimili-vpngate:latest
    container_name: caddyray_vpngate
    restart: always
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "127.0.0.1:8787:8787" # 网页管理后台登录端口
    environment:
      # ⚠️ 必须：绑定代理服务到 0.0.0.0，否则其它容器（如 v2ray）将无法连接到它
      - LOCAL_PROXY_HOST=0.0.0.0
      # 可选：锁定特定的国家代码，例如只连接台湾 (TW) 节点以获取台湾住宅 IP
      # - ONLY_COUNTRY=TW
```

---

### ⚠️ 核心踩坑与解决经验 (Docker 整合经验分享)

在将该项目容器化并整合到代理链路中时，请务必注意以下几点：

#### 1. 代理绑定网络隔离 (LOCAL_PROXY_HOST)
*   **问题**：`aimili-vpngate` 的 SOCKS5/HTTP 双效代理（默认端口 `7928`）在默认情况下仅绑定在本地回环地址 `127.0.0.1`。
*   **影响**：如果在 Docker 容器中直接运行，容器网络外部或同一网络下的其它容器（如 `v2ray`）将无法与其建立通信，导致代理失效。
*   **解决方案**：在容器环境变量中设置 `- LOCAL_PROXY_HOST=0.0.0.0`，使服务能监听到容器内的所有网卡接口。

#### 2. TUN 虚拟网卡权限
*   **问题**：OpenVPN 建立隧道时需要创建虚拟网络设备 `/dev/net/tun`。
*   **影响**：如果容器没有获得足够权限，会报错 `Cannot allocate tun` 或 `Cannot open tun/tap dev`。
*   **解决方案**：必须在 `docker-compose` 中声明：
    ```yaml
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ```

#### 3. 宿主机虚拟化架构限制 (LXC / OpenVZ)
*   **问题**：如果您的 VPS 宿主机是 LXC 或 OpenVZ 等非 KVM 架构，默认是没有开启 TUN 权限的。
*   **解决方案**：必须在 VPS 服务商的 SolusVM/Proxmox 面板中找到 **Enable TUN/TAP**（启用 TUN）并开启，然后重启 VPS 宿主机，容器内才能正常建立 OpenVPN 连接。

---

<a name="english"></a>
## English Description

`docker-aimili-vpngate` is a Dockerized container package for the open-source project [baoweise-bot/aimili-vpngate](https://github.com/baoweise-bot/aimili-vpngate) (AimiliVPN).

AimiliVPN is a high-performance, zero-dependency VPN proxy gateway that utilizes `vpngate.net` open protocol. It automatically fetches VPN Gate nodes, benchmarks them via multi-threaded concurrent latency tests, and **automatically drifts (fails over)** to backup nodes when the active node goes down, providing a clean residential / non-datacenter IP for outbound traffic.

This project automates **`linux/amd64`** and **`linux/arm64`** multi-arch Docker image builds via GitHub Actions for seamless container network integration (e.g., as a V2Ray outbound proxy for unlocking geo-blocked streaming services).

---

### 🚀 Quick Start (Docker Compose)

Add the following service to your `docker-compose.yml`:

```yaml
version: '3'

services:
  caddyray_vpngate:
    image: ghcr.io/besson1412/docker-aimili-vpngate:latest
    container_name: caddyray_vpngate
    restart: always
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "127.0.0.1:8787:8787" # Web Admin Portal
    environment:
      # ⚠️ REQUIRED: Bind the proxy host to 0.0.0.0 so other containers can access it
      - LOCAL_PROXY_HOST=0.0.0.0
      # Optional: Filter nodes by country (e.g., only connect to Taiwan nodes)
      # - ONLY_COUNTRY=TW
```

---

### ⚠️ Key Troubleshooting Notes & Gotchas

#### 1. Proxy Binding Isolation (`LOCAL_PROXY_HOST`)
*   **Issue**: By default, `aimili-vpngate` SOCKS5/HTTP proxy (default port `7928`) only binds to the loopback address `127.0.0.1`.
*   **Gotcha**: If run in Docker without override, other containers in the same Docker network cannot connect to the proxy port.
*   **Fix**: Pass the environment variable `- LOCAL_PROXY_HOST=0.0.0.0` to bind to all container interfaces.

#### 2. TUN Device Permissions
*   **Issue**: OpenVPN requires the creation of the `/dev/net/tun` virtual network interface.
*   **Gotcha**: Without explicit capabilities, the container fails with `Cannot allocate tun`.
*   **Fix**: Grant `NET_ADMIN` cap and mount the tun device in `docker-compose.yml`:
    ```yaml
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ```

#### 3. LXC / OpenVZ Host Virtualization Restrictions
*   **Issue**: LXC or OpenVZ containers on lightweight VPS nodes do not have TUN enabled by default at the host level.
*   **Fix**: Enable **TUN/TAP** in your VPS SolusVM/Proxmox server control panel before launching the container.
