FROM alpine:latest

# 安装系统依赖（支持 Python3 及 OpenVPN 网络栈）
RUN apk add --no-cache python3 openvpn bash curl iproute2 iptables git ca-certificates

# 克隆 aimili-vpngate 开源项目源码到容器目录
RUN git clone https://github.com/baoweise-bot/aimili-vpngate.git /opt/aimilivpn

WORKDIR /opt/aimilivpn

# 复制入口脚本并赋予执行权限
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 暴露 7928 (代理服务端口) 和 8787 (Web管理页面端口)
EXPOSE 7928 8787

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["python3", "vpngate_manager.py"]
