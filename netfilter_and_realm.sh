#!/bin/bash
# ============================================================
# 双栈端口转发管理脚本 (支持增删改查)
# IPv4: nftables | IPv6: realm
# ============================================================

REALM_VER="2.7.0"
DB_FILE="/etc/.forwarding_db"
INIT_FLAG="/etc/.nft_realm_initialized"

# ==================== 1. 环境与变量检测 ====================
WAN_IF=$(ip -4 route show default | awk '{print $5; exit}')
if [ -z "$WAN_IF" ]; then echo "❌ 无法检测默认网卡"; exit 1; fi

LOCAL4=$(ip -4 addr show "$WAN_IF" | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
LOCAL6=$(ip -6 addr show "$WAN_IF" scope global | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)

HAS_IPV6=true
if [ -z "$LOCAL6" ]; then HAS_IPV6=false; fi

# 确保数据库文件存在
touch "$DB_FILE"

# ==================== 2. 核心功能：根据数据库重构配置 ====================
rebuild_configs() {
  echo "⏳ 正在同步配置并应用规则..."

  # 准备临时文件以拼接 nftables 规则
  TMP_IN="/tmp/nft_in.tmp"
  TMP_FWD="/tmp/nft_fwd.tmp"
  TMP_PRE="/tmp/nft_pre.tmp"
  TMP_POST="/tmp/nft_post.tmp"
  > "$TMP_IN"; > "$TMP_FWD"; > "$TMP_PRE"; > "$TMP_POST"

  # 重置 realm 配置
  echo '[log]' > /etc/realm/config.toml
  echo 'level = "warn"' >> /etc/realm/config.toml

  # 读取数据库并生成规则
  while IFS='|' read -r F_PORT B_IP B_PORT; do
    if [ -z "$F_PORT" ]; then continue; fi

    # 组装 nftables (IPv4)
    echo "    iifname \"$WAN_IF\" tcp dport $F_PORT accept" >> "$TMP_IN"
    echo "    iifname \"$WAN_IF\" udp dport $F_PORT accept" >> "$TMP_IN"
    echo "    ip daddr $B_IP tcp dport $B_PORT accept" >> "$TMP_FWD"
    echo "    ip daddr $B_IP udp dport $B_PORT accept" >> "$TMP_FWD"
    echo "    iifname \"$WAN_IF\" tcp dport $F_PORT dnat to $B_IP:$B_PORT" >> "$TMP_PRE"
    echo "    iifname \"$WAN_IF\" udp dport $F_PORT dnat to $B_IP:$B_PORT" >> "$TMP_PRE"
    echo "    ip daddr $B_IP tcp dport $B_PORT ip saddr != $LOCAL4 masquerade" >> "$TMP_POST"
    echo "    ip daddr $B_IP udp dport $B_PORT ip saddr != $LOCAL4 masquerade" >> "$TMP_POST"

    # 组装 realm (IPv6)
    if $HAS_IPV6; then
      cat << EOF >> /etc/realm/config.toml

[[endpoints]]
listen = "[$LOCAL6]:$F_PORT"
remote = "$B_IP:$B_PORT"
[endpoints.transport]
no_tcp = false
use_udp = true
EOF
    fi
  done < "$DB_FILE"

  # 生成最终的 nftables.conf
  cat << EOF > /etc/nftables.conf
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state { established, related } accept
    iif "lo" accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    tcp dport 22 accept
$(cat "$TMP_IN")
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state { established, related } accept
$(cat "$TMP_FWD")
  }
  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain prerouting {
    type nat hook prerouting priority -100; policy accept;
$(cat "$TMP_PRE")
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
$(cat "$TMP_POST")
  }
}
EOF

  # 清理临时文件
  rm -f "$TMP_IN" "$TMP_FWD" "$TMP_PRE" "$TMP_POST"

  # 重载服务
  sudo nft -f /etc/nftables.conf
  if $HAS_IPV6; then sudo systemctl restart realm; fi
  echo "✅ 规则已成功应用！"
  echo "----------------------------------------"
}

# ==================== 3. 首次初始化环境 ====================
init_env() {
  if [ ! -f "$INIT_FLAG" ]; then
    echo "🚀 首次运行，初始化环境..."
	if ! command -v nft &>/dev/null; then
      echo "  正在自动安装 nftables..."
      if command -v apt-get &>/dev/null; then
        sudo apt-get update -y && sudo apt-get install -y nftables
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y nftables
      elif command -v yum &>/dev/null; then
        sudo yum install -y nftables
      else
        echo "❌ 无法自动安装 nftables，请手动安装后重试。"
        exit 1
      fi
    fi
    sudo tee /etc/sysctl.d/99-relay.conf >/dev/null <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sudo sysctl --system >/dev/null
    if systemctl is-active --quiet ufw 2>/dev/null; then sudo systemctl disable --now ufw; fi
    sudo systemctl enable nftables
    
    if $HAS_IPV6; then
      if ! command -v realm &>/dev/null; then
        ARCH=$(uname -m)
        if [ "$ARCH" = "x86_64" ]; then REALM_ARCH="x86_64-unknown-linux-gnu"
        elif [ "$ARCH" = "aarch64" ]; then REALM_ARCH="aarch64-unknown-linux-gnu"
        else echo "❌ 不支持的架构"; exit 1; fi
        cd /tmp
        curl -fsSL "https://github.com/zhboner/realm/releases/download/v${REALM_VER}/realm-${REALM_ARCH}.tar.gz" -o realm.tar.gz
        tar xzf realm.tar.gz
        sudo mv realm /usr/local/bin/realm
        sudo chmod +x /usr/local/bin/realm
        rm -f realm.tar.gz
      fi
      sudo mkdir -p /etc/realm
      sudo tee /etc/systemd/system/realm.service >/dev/null <<EOF
[Unit]
Description=Realm IPv6 port forwarding
After=network-online.target nftables.service
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
      sudo systemctl daemon-reload
      sudo systemctl enable --now realm
    fi
    sudo touch "$INIT_FLAG"
    rebuild_configs
  fi
}

# ==================== 4. 菜单操作函数 ====================
add_rule() {
  echo ""
  read -rp "监听端口 (如 8080): " FWD_PORT
  if [ -z "$FWD_PORT" ]; then echo "❌ 端口不能为空"; return; fi
  
  # 检查端口是否已存在
  if grep -q "^${FWD_PORT}|" "$DB_FILE"; then
    echo "❌ 监听端口 $FWD_PORT 已存在，请先删除旧规则！"
    return
  fi

  read -rp "远端 IP 地址: " BACKEND
  if [ -z "$BACKEND" ]; then echo "❌ 地址不能为空"; return; fi
  
  read -rp "远端端口 [默认 $FWD_PORT]: " BACKEND_PORT
  BACKEND_PORT=${BACKEND_PORT:-$FWD_PORT}

  echo "${FWD_PORT}|${BACKEND}|${BACKEND_PORT}" >> "$DB_FILE"
  echo "✅ 已记录规则: $FWD_PORT -> $BACKEND:$BACKEND_PORT"
  rebuild_configs
}

view_rules() {
  echo ""
  echo "================ 当前转发规则 ================"
  if [ ! -s "$DB_FILE" ]; then
    echo "  (暂无任何规则)"
  else
    printf "%-5s | %-12s | %-20s\n" "序号" "监听端口" "远端目标 (IP:端口)"
    echo "----------------------------------------------"
    cat -n "$DB_FILE" | while read -r num line; do
      F_PORT=$(echo "$line" | cut -d'|' -f1)
      B_IP=$(echo "$line" | cut -d'|' -f2)
      B_PORT=$(echo "$line" | cut -d'|' -f3)
      printf "%-5s | %-12s | %-20s\n" "[$num]" "$F_PORT" "$B_IP:$B_PORT"
    done
  fi
  echo "=============================================="
  echo ""
}

del_rule() {
  view_rules
  if [ ! -s "$DB_FILE" ]; then return; fi
  
  read -rp "请输入要删除的【序号】 (按回车取消): " DEL_NUM
  if [ -z "$DEL_NUM" ]; then return; fi
  
  # 验证输入是否为数字
  if ! [[ "$DEL_NUM" =~ ^[0-9]+$ ]]; then echo "❌ 输入无效"; return; fi
  
  TOTAL=$(wc -l < "$DB_FILE")
  if [ "$DEL_NUM" -lt 1 ] || [ "$DEL_NUM" -gt "$TOTAL" ]; then
    echo "❌ 找不到对应的序号"
    return
  fi

  # 使用 sed 删除对应行
  sed -i "${DEL_NUM}d" "$DB_FILE"
  echo "✅ 规则已删除"
  rebuild_configs
}

# ==================== 主程序循环 ====================
init_env

while true; do
  echo ""
  echo "=========================================="
  echo "       双栈端口转发管理面板 v3"
  echo "=========================================="
  echo "  1. ➕ 添加转发规则"
  echo "  2. 🗑️ 删除转发规则"
  echo "  3. 📋 查看当前规则"
  echo "  0. 🚪 退出脚本"
  echo "=========================================="
  read -rp "请输入选项 [0-3]: " CHOICE
  echo "----------------------------------------"
  case "$CHOICE" in
    1) add_rule ;;
    2) del_rule ;;
    3) view_rules ;;
    0) echo "👋 感谢使用，再见！"; exit 0 ;;
    *) echo "❌ 无效的输入，请重新选择" ;;
  esac
done