#!/bin/ash
# XrayInstall: Alpine/OpenRC VLESS + REALITY + Vision manager.
# shellcheck disable=SC2016 # Single-quoted jq programs use jq variables.
set -eu
umask 077

VERSION=2.0.0
SELF=xray-reality
XRAY_BIN=/usr/local/bin/xray
CONF_DIR=/usr/local/etc/xray
CONF_FILE=$CONF_DIR/config.json
STATE_FILE=/etc/xray-reality.env
OPENRC_CONF=/etc/conf.d/xray
MEMORY_BEGIN='# BEGIN XRAY-REALITY MEMORY'
MEMORY_END='# END XRAY-REALITY MEMORY'
TX_DIR=''
WORK_DIR=''
LOCKED=0

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
need_root() { [ "$(id -u)" -eq 0 ] || die '请用 root 运行'; }
core() { GOMEMLIMIT="${CLI_LIMIT:-40MiB}" GOGC="${CLI_GC:-50}" "$XRAY_BIN" "$@"; }
usage() {
  cat <<'EOF'
XrayInstall 2.0 — Alpine/OpenRC VLESS + REALITY + Vision

安装（已有节点必须加 --force 才允许重建）:
  xray-reality install [端口] [SNI] [选项]
  默认: 443、www.amd.com、自动 IPv4 优先/IPv6 回退、自动内存优化
  --ipv4 | --ipv6         选择公网地址检测和监听地址族
  --address <IP/域名>     自定义客户端连接地址，IPv6 可带或不带方括号
  --listen <IP>          绑定地址，IPv6 默认 ::，IPv4 默认 0.0.0.0
  --sni <域名>           Reality SNI（不含 https:// 或端口）
  --target <主机:端口>    独立回落目标，默认 <SNI>:443；IPv6 用 [地址]:端口
  --public-port <端口>   NAT 对外端口，默认与监听端口相同
  --force                备份后重建节点（会生成新 UUID 和密钥）

管理:
  show | status | check | log | start | stop | restart | update
  change-port <端口> [公网端口]   修改监听端口；NAT 时同时填写公网端口
  set-address <IP/域名> [公网端口] 修改分享地址，不修改监听
  set-listen <IP>                 修改监听，可用 :: 开启 IPv6
  set-sni <域名> [回落目标]        修改 SNI，省略回落目标则为 <SNI>:443
  add-user [备注] | del-user <UUID>
  optimize                       按有效内存重算 Go 参数和连接策略
  memory                         查看容器内存、进程 RSS 和 OOM 记录
  set-memory <限制> <GOGC>        如 40MiB 50（只改 Go 参数）
  reset-memory                   清除脚本管理的 Go 参数，保留连接策略
  set-policy <空闲秒数> <缓存KB> [握手秒数]
  uninstall --yes                卸载核心和配置，保留备份及管理脚本

例: xray-reality install 443 --ipv6 --sni www.amd.com
例: xray-reality install 83 www.amd.com --address example.com --public-port 20443
EOF
}

valid_port() {
  case "$1" in ''|0*|*[!0-9]*) return 1;; esac
  [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}
valid_uint() {
  case "$1" in ''|0*|*[!0-9]*) return 1;; esac
  [ "${#1}" -le 6 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}
valid_ipv4() {
  printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++) if($i!~/^[0-9]+$/ || length($i)>3 || $i+0>255) exit 1}'
}
valid_ipv6() {
  # Accept native IPv6 literals (no zone IDs or IPv4-mapped notation).
  printf '%s\n' "$1" | awk '
    /[^0-9a-fA-F:]/ {exit 1}
    {s=$0; if(index(s,":")==0) exit 1
     t=s; n=gsub(/::/,"X",t); if(n>1 || index(s,":::")>0) exit 1
     if(n==0 && (s ~ /^:/ || s ~ /:$/)) exit 1
     count=split(s,a,":"); groups=0
     for(i=1;i<=count;i++) if(a[i]!="") {if(length(a[i])>4) exit 1; groups++}
     if(n==1) {if(groups>=8) exit 1} else if(groups!=8) exit 1
    }'
}
valid_domain() {
  [ "${#1}" -le 253 ] || return 1
  printf '%s\n' "$1" | awk -F. 'NF<2{exit 1} {for(i=1;i<=NF;i++) if(length($i)<1 || length($i)>63 || $i!~/^[a-zA-Z0-9-]+$/ || $i~/^-/ || $i~/-$/) exit 1}'
}
normalize_address() { printf '%s' "$1" | sed 's/^\[//;s/\]$//'; }
valid_address() { valid_ipv4 "$1" || valid_ipv6 "$1" || valid_domain "$1"; }
valid_target() {
  case "$1" in
    \[*\]:*)
      _host=${1%]:*}; _host=${_host#\[}; _tp=${1##*:}
      valid_ipv6 "$_host" && valid_port "$_tp";;
    *:*)
      _host=${1%:*}; _tp=${1##*:}
      { valid_ipv4 "$_host" || valid_domain "$_host"; } && valid_port "$_tp";;
    *) return 1;;
  esac
}

effective_memory_mb() {
  # A container's /proc/meminfo can describe the host. Use the smallest limit.
  set -- /proc/meminfo
  for _mem_file in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    [ ! -r "$_mem_file" ] || set -- "$@" "$_mem_file"
  done
  awk '
    FNR==1 {file=FILENAME}
    file ~ /meminfo$/ && /^MemTotal:/ {mb=int($2/1024); if(mb>0 && (m==0||mb<m)) m=mb}
    file !~ /meminfo$/ && $1~/^[0-9]+$/ {mb=int($1/1048576); if(mb>0 && (m==0||mb<m)) m=mb}
    END {print (m>0?m:128)}
  ' "$@"
}
auto_profile() {
  MEM_MB=$(effective_memory_mb)
  case "$MEM_MB" in ''|*[!0-9]*) MEM_MB=128;; esac
  if [ "$MEM_MB" -le 128 ]; then
    LIMIT_MB=$((MEM_MB * 5 / 16)); GC=50; IDLE=120; BUFFER=64
  elif [ "$MEM_MB" -le 256 ]; then
    LIMIT_MB=$((MEM_MB / 2)); GC=75; IDLE=180; BUFFER=128
  elif [ "$MEM_MB" -le 512 ]; then
    LIMIT_MB=$((MEM_MB * 65 / 100)); GC=100; IDLE=180; BUFFER=256
  else
    LIMIT_MB=$((MEM_MB * 80 / 100)); GC=100; IDLE=300; BUFFER=512
  fi
  [ "$LIMIT_MB" -ge 16 ] || LIMIT_MB=16
  LIMIT="${LIMIT_MB}MiB"
  # Avoid a 4-second handshake deadline on slow mobile networks.
  HANDSHAKE=15
}
strip_memory_block() {
  if [ -f "$1" ]; then
    awk -v begin="$MEMORY_BEGIN" -v end="$MEMORY_END" \
      '$0==begin {skip=1;next} $0==end {skip=0;next} !skip {print}' "$1" >"$2"
  else : >"$2"; fi
}
write_memory() {
  mkdir -p /etc/conf.d
  _mem_tmp=$(mktemp /etc/conf.d/.xray.XXXXXX)
  strip_memory_block "$OPENRC_CONF" "$_mem_tmp"
  cat >>"$_mem_tmp" <<EOF
$MEMORY_BEGIN
# Loaded by OpenRC before launching the core. GOMEMLIMIT is a soft Go limit.
export GOMEMLIMIT='$LIMIT'
export GOGC='$GC'
$MEMORY_END
EOF
  chmod 600 "$_mem_tmp"
  mv "$_mem_tmp" "$OPENRC_CONF"
}
install_deps() {
  [ -f /etc/alpine-release ] || die '目前支持 Alpine Linux + OpenRC'
  need_cmd rc-service
  apk add --no-cache curl ca-certificates openssl jq unzip >/dev/null
}
install_core() {
  # Keep downloads on disk rather than /tmp (often tmpfs in tiny containers).
  WORK_DIR=$(mktemp -d /root/.xray-download.XXXXXX)
  curl -fL --retry 3 --connect-timeout 15 --max-time 120 \
    -o "$WORK_DIR/install.sh" \
    https://raw.githubusercontent.com/XTLS/Xray-install/main/alpinelinux/install-release.sh
  TMPDIR="$WORK_DIR" GOMEMLIMIT="$LIMIT" GOGC="$GC" ash "$WORK_DIR/install.sh"
  rm -rf "$WORK_DIR"
  WORK_DIR=''
}

load_state() {
  [ -r "$STATE_FILE" ] && [ -r "$CONF_FILE" ] || die "请先运行 $SELF install"
  # Values are written only after validation; state is root-owned, mode 600.
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  PUBLIC_PORT=${PUBLIC_PORT:-$PORT}
  LISTEN=$(jq -r '.inbounds[0].listen // "0.0.0.0"' "$CONF_FILE")
}
write_state() {
  _state_tmp=$(mktemp /etc/.xray-state.XXXXXX)
  cat >"$_state_tmp" <<EOF
SERVER_IP='$SERVER_IP'
PORT='$PORT'
PUBLIC_PORT='$PUBLIC_PORT'
LISTEN='$LISTEN'
SERVER_NAME='$SERVER_NAME'
TARGET='$TARGET'
PUBLIC_KEY='$PUBLIC_KEY'
SHORT_ID='$SHORT_ID'
EOF
  chmod 600 "$_state_tmp"
  mv "$_state_tmp" "$STATE_FILE"
}
make_uri() {
  _uri_host=$SERVER_IP
  case "$_uri_host" in *:*) _uri_host="[$_uri_host]";; esac
  _uri_name=$(printf '%s' "$2" | jq -sRr @uri)
  printf 'vless://%s@%s:%s?encryption=none&type=tcp&security=reality&pbk=%s&fp=chrome&sni=%s&sid=%s&spx=%%2F&flow=xtls-rprx-vision#%s\n' \
    "$1" "$_uri_host" "$PUBLIC_PORT" "$PUBLIC_KEY" "$SERVER_NAME" "$SHORT_ID" "$_uri_name"
}
show_all() {
  load_state
  printf '服务器: %s\n监听: %s:%s\n公网端口: %s\nSNI: %s\n回落目标: %s\n公钥: %s\nShortID: %s\n\n' \
    "$SERVER_IP" "$LISTEN" "$PORT" "$PUBLIC_PORT" "$SERVER_NAME" "$TARGET" "$PUBLIC_KEY" "$SHORT_ID"
  jq -r '.inbounds[0].settings.clients[] | [.id, (.email // "user")] | @tsv' "$CONF_FILE" |
  while IFS="$(printf '\t')" read -r _uuid _email; do
    printf '用户: %s\n' "$_email"
    make_uri "$_uuid" "$_email"
  done
}

begin_tx() {
  mkdir -p /root/xray-reality-backups "$CONF_DIR" /etc/conf.d
  chmod 700 /root/xray-reality-backups
  TX_DIR=$(mktemp -d "/root/xray-reality-backups/$(date +%Y%m%d-%H%M%S).XXXXXX")
  # Copy the entire confdir because the official service merges all JSON files.
  cp -a "$CONF_DIR" "$TX_DIR/config"
  [ ! -f "$STATE_FILE" ] || cp -p "$STATE_FILE" "$TX_DIR/state"
  [ ! -f "$OPENRC_CONF" ] || cp -p "$OPENRC_CONF" "$TX_DIR/openrc"
  [ ! -f /etc/init.d/xray ] || cp -p /etc/init.d/xray "$TX_DIR/service"
  if [ "${1:-config}" = core ]; then
    : >"$TX_DIR/manage-core"
    [ ! -x "$XRAY_BIN" ] || cp -p "$XRAY_BIN" "$TX_DIR/xray"
  fi
  if rc-service xray status >/dev/null 2>&1; then : >"$TX_DIR/was-running"; fi
}
rollback() {
  [ -n "$TX_DIR" ] || return 0
  _restore=$TX_DIR
  TX_DIR=''
  rc-service xray stop >/dev/null 2>&1 || true
  for _file in "$CONF_DIR"/*.json; do
    [ ! -f "$_file" ] || rm -f "$_file"
  done
  cp -a "$_restore/config/." "$CONF_DIR/"
  if [ -f "$_restore/state" ]; then cp -p "$_restore/state" "$STATE_FILE"; else rm -f "$STATE_FILE"; fi
  if [ -f "$_restore/openrc" ]; then cp -p "$_restore/openrc" "$OPENRC_CONF"; else rm -f "$OPENRC_CONF"; fi
  if [ -f "$_restore/service" ]; then cp -p "$_restore/service" /etc/init.d/xray; else rm -f /etc/init.d/xray; fi
  if [ -f "$_restore/manage-core" ]; then
    if [ -f "$_restore/xray" ]; then cp -p "$_restore/xray" "$XRAY_BIN"; else rm -f "$XRAY_BIN"; fi
  fi
  if [ -f "$_restore/was-running" ]; then rc-service xray start >/dev/null 2>&1 || true; fi
  printf '已回滚，备份: %s\n' "$_restore" >&2
}
cleanup() {
  _exit_code=$?
  trap - EXIT
  [ -z "$TX_DIR" ] || rollback
  if [ -n "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
  if [ "$LOCKED" = 1 ]; then rmdir /run/xray-reality.lock; fi
  exit "$_exit_code"
}
xray_listener_pid() {
  _pid_port=$(jq -r '.inbounds[0].port' "$CONF_FILE" 2>/dev/null || true)
  netstat -lntp 2>/dev/null | awk -v port="$_pid_port" \
    '$4 ~ (":" port "$") && $7 ~ /\/xray$/ {split($7,a,"/");print a[1];exit}'
}
service_ready() {
  rc-service xray status >/dev/null 2>&1 || return 1
  _expect_port=$(jq -r '.inbounds[0].port' "$CONF_FILE")
  netstat -lntp 2>/dev/null | awk -v port="$_expect_port" \
    '$4 ~ (":" port "$") && $7 ~ /\/xray$/ {ok=1} END {exit !ok}'
}
finish_tx() {
  core run -test -confdir "$CONF_DIR" >/dev/null
  rc-service xray restart >/dev/null 2>&1 || rc-service xray start >/dev/null 2>&1 || die 'Xray 启动失败'
  _tries=0
  until service_ready; do
    _tries=$((_tries + 1)); [ "$_tries" -lt 5 ] || die '服务未监听预期端口'
    sleep 1
  done
  if [ "${VERIFY_MEMORY:-0}" = 1 ]; then
    _pid=$(xray_listener_pid)
    tr '\0' '\n' <"/proc/$_pid/environ" | grep -Fx "GOMEMLIMIT=$LIMIT" >/dev/null || die 'GOMEMLIMIT 未生效'
    tr '\0' '\n' <"/proc/$_pid/environ" | grep -Fx "GOGC=$GC" >/dev/null || die 'GOGC 未生效'
  fi
  printf '操作完成，备份: %s\n' "$TX_DIR"
  TX_DIR=''
}
edit_config() {
  _edit_tmp=$(mktemp "$CONF_DIR/.candidate.XXXXXX")
  jq "$@" "$CONF_FILE" >"$_edit_tmp"
  core run -test -format json -config "$_edit_tmp" >/dev/null || {
    rm -f "$_edit_tmp"; die '候选配置校验失败';
  }
  chown root:nobody "$_edit_tmp"; chmod 640 "$_edit_tmp"
  mv "$_edit_tmp" "$CONF_FILE"
}
apply_policy() {
  edit_config --argjson idle "$IDLE" --argjson buffer "$BUFFER" --argjson hs "$HANDSHAKE" '
    .policy.levels["0"] = {handshake:$hs,connIdle:$idle,uplinkOnly:1,downlinkOnly:1,
      statsUserUplink:false,statsUserDownlink:false,statsUserOnline:false,bufferSize:$buffer} |
    .policy.system = {statsInboundUplink:false,statsInboundDownlink:false,
      statsOutboundUplink:false,statsOutboundDownlink:false}'
}

detect_address() {
  _family=$1
  for _url in https://api64.ipify.org https://ifconfig.co/ip; do
    _detected=$(curl "-$_family" -fsS --connect-timeout 5 --max-time 10 "$_url" 2>/dev/null || true)
    if [ "$_family" = 6 ]; then
      if valid_ipv6 "$_detected"; then printf '%s' "$_detected"; return 0; fi
    elif valid_ipv4 "$_detected"; then printf '%s' "$_detected"; return 0; fi
  done
  return 1
}
do_install() {
  need_root
  PORT=443; PUBLIC_PORT=''; SERVER_NAME=www.amd.com; TARGET=''; SERVER_IP=''; LISTEN=''; FAMILY=auto; FORCE=0
  if [ $# -gt 0 ]; then case "$1" in --*) ;; *) PORT=$1; shift;; esac; fi
  if [ $# -gt 0 ]; then case "$1" in --*) ;; *) SERVER_NAME=$1; shift;; esac; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --ipv4) FAMILY=4; shift;;
      --ipv6) FAMILY=6; shift;;
      --force) FORCE=1; shift;;
      --address|--listen|--sni|--target|--public-port)
        [ $# -ge 2 ] || die "$1 缺少参数"
        case "$1" in
          --address) SERVER_IP=$(normalize_address "$2");;
          --listen) LISTEN=$(normalize_address "$2");;
          --sni) SERVER_NAME=$2;;
          --target) TARGET=$2;;
          --public-port) PUBLIC_PORT=$2;;
        esac; shift 2;;
      *) die "未知参数: $1";;
    esac
  done
  valid_port "$PORT" || die '监听端口必须为 1-65535'
  PUBLIC_PORT=${PUBLIC_PORT:-$PORT}
  valid_port "$PUBLIC_PORT" || die '公网端口必须为 1-65535'
  valid_domain "$SERVER_NAME" || die 'SNI 必须是有效的 ASCII 域名'
  TARGET=${TARGET:-$SERVER_NAME:443}
  valid_target "$TARGET" || die '回落目标格式错误'
  [ -z "$SERVER_IP" ] || valid_address "$SERVER_IP" || die '连接地址格式错误'
  [ -z "$LISTEN" ] || { valid_ipv4 "$LISTEN" || valid_ipv6 "$LISTEN"; } || die '监听必须是 IP 地址'
  if [ -f "$STATE_FILE" ] || [ -f "$CONF_FILE" ]; then
    [ "$FORCE" = 1 ] || die '已有配置；请用管理命令修改，重建需加 --force'
  fi
  install_deps
  auto_profile
  # Also constrain short-lived xray uuid/x25519/config-test processes.
  CLI_LIMIT=$LIMIT; CLI_GC=$GC
  if [ -z "$SERVER_IP" ]; then
    case "$FAMILY" in
      4|6) SERVER_IP=$(detect_address "$FAMILY") || die '公网地址检测失败，请用 --address 指定';;
      auto) SERVER_IP=$(detect_address 4 || detect_address 6) || die '公网地址检测失败，请用 --address 指定';;
    esac
  fi
  if [ "$FAMILY" = auto ]; then
    if valid_ipv6 "$SERVER_IP"; then FAMILY=6; else FAMILY=4; fi
  fi
  if [ -z "$LISTEN" ]; then
    if [ "$FAMILY" = 6 ]; then LISTEN='::'; else LISTEN=0.0.0.0; fi
  fi
  if valid_ipv6 "$SERVER_IP" && ! valid_ipv6 "$LISTEN"; then die 'IPv6 节点需要 IPv6 监听地址，例如 --listen ::'; fi
  begin_tx core
  # umask 077 also affects newly created parent directories. The official
  # service runs as nobody, so it needs traversal permission through etc/.
  chmod 755 /usr/local/etc
  chown root:nobody "$CONF_DIR"
  chmod 750 "$CONF_DIR"
  write_memory
  if [ ! -x "$XRAY_BIN" ] || [ ! -f /etc/init.d/xray ]; then install_core; fi
  _uuid=$(core uuid)
  _keys=$(core x25519)
  _private_key=$(printf '%s\n' "$_keys" | sed -n 's/^PrivateKey: *//p')
  PUBLIC_KEY=$(printf '%s\n' "$_keys" | sed -n -e 's/^Password (PublicKey): *//p' -e 's/^PublicKey: *//p' -e 's/^Password: *//p' | head -1)
  [ -n "$_private_key" ] && [ -n "$PUBLIC_KEY" ] || die '生成密钥失败'
  SHORT_ID=$(openssl rand -hex 8)
  mkdir -p /var/log/xray
  touch /var/log/xray/error.log
  chown nobody:nobody /var/log/xray/error.log
  chmod 600 /var/log/xray/error.log
  # Original JSON files are in TX_DIR; prevent confdir merging old inbounds.
  for _file in "$CONF_DIR"/*.json; do [ ! -f "$_file" ] || rm -f "$_file"; done
  jq -n --arg uuid "$_uuid" --arg key "$_private_key" --arg sid "$SHORT_ID" \
    --arg sni "$SERVER_NAME" --arg target "$TARGET" --arg listen "$LISTEN" --argjson port "$PORT" '
    {log:{access:"none",error:"/var/log/xray/error.log",loglevel:"warning"},
     inbounds:[{listen:$listen,port:$port,protocol:"vless",tag:"reality",
       settings:{clients:[{id:$uuid,email:"default",level:0,flow:"xtls-rprx-vision"}],decryption:"none"},
       sniffing:{enabled:false},streamSettings:{network:"tcp",security:"reality",
         realitySettings:{show:false,xver:0,target:$target,serverNames:[$sni],privateKey:$key,shortIds:[$sid]}}}],
     outbounds:[{protocol:"freedom",tag:"direct"}]}' >"$CONF_FILE"
  chown root:nobody "$CONF_FILE"; chmod 640 "$CONF_FILE"
  apply_policy
  write_state
  VERIFY_MEMORY=1
  finish_tx
  rc-update add xray default >/dev/null 2>&1
  # Persist the manager for subsequent commands, including when invoked via ash.
  if [ -f "$0" ] && [ "$(readlink -f "$0")" != /usr/local/bin/xray-reality ]; then
    cp "$0" /usr/local/bin/xray-reality
    chmod 700 /usr/local/bin/xray-reality
  fi
  printf '有效内存 %sMiB；GOMEMLIMIT=%s GOGC=%s；connIdle=%ss bufferSize=%sKB\n' "$MEM_MB" "$LIMIT" "$GC" "$IDLE" "$BUFFER"
  echo '请确保服务商安全组/NAT 转发允许该 TCP 端口。IPv6 连接需要手机网络具备 IPv6。'
  show_all
}

change_port() {
  need_root; load_state
  _new=${1:-}; valid_port "$_new" || die '请输入 1-65535 的监听端口'
  _public=${2:-$_new}; valid_port "$_public" || die '公网端口错误'
  if [ "$PUBLIC_PORT" != "$PORT" ] && [ $# -lt 2 ]; then die '已有 NAT 映射，请同时提供公网端口'; fi
  begin_tx
  edit_config --argjson port "$_new" '.inbounds[0].port=$port'
  PORT=$_new; PUBLIC_PORT=$_public; write_state
  finish_tx; show_all
}
set_address() {
  need_root; load_state
  _addr=$(normalize_address "${1:-}")
  valid_address "$_addr" || die '连接地址必须是 IPv4、IPv6 或域名'
  _public=${2:-$PUBLIC_PORT}; valid_port "$_public" || die '公网端口错误'
  if valid_ipv6 "$_addr" && ! valid_ipv6 "$LISTEN"; then die '请先运行 set-listen :: 启用 IPv6 监听'; fi
  SERVER_IP=$_addr; PUBLIC_PORT=$_public; write_state; show_all
}
set_listen() {
  need_root; load_state
  _listen=$(normalize_address "${1:-}")
  valid_ipv4 "$_listen" || valid_ipv6 "$_listen" || die '监听必须是 IP 地址'
  if valid_ipv6 "$SERVER_IP" && ! valid_ipv6 "$_listen"; then die '当前分享地址是 IPv6，请先修改 set-address'; fi
  begin_tx
  edit_config --arg listen "$_listen" '.inbounds[0].listen=$listen'
  LISTEN=$_listen; write_state; finish_tx
}
set_sni() {
  need_root; load_state
  _sni=${1:-}; valid_domain "$_sni" || die '请输入有效 SNI 域名'
  _target=${2:-$_sni:443}; valid_target "$_target" || die '回落目标格式错误'
  begin_tx
  edit_config --arg sni "$_sni" --arg target "$_target" \
    '.inbounds[0].streamSettings.realitySettings |= (.serverNames=[$sni] | .target=$target | del(.dest))'
  SERVER_NAME=$_sni; TARGET=$_target; write_state; finish_tx; show_all
}
add_user() {
  need_root; load_state
  _email=${1:-user-$(date +%s)}
  printf '%s' "$_email" | grep -q '[[:cntrl:]]' && die '备注不能包含换行或控制字符'
  _uuid=$(core uuid)
  begin_tx
  edit_config --arg id "$_uuid" --arg email "$_email" \
    '.inbounds[0].settings.clients += [{id:$id,email:$email,level:0,flow:"xtls-rprx-vision"}]'
  finish_tx; make_uri "$_uuid" "$_email"
}
del_user() {
  need_root; load_state
  _uuid=${1:-}; [ -n "$_uuid" ] || die '请输入 UUID'
  jq -e --arg id "$_uuid" '.inbounds[0].settings.clients | any(.id==$id)' "$CONF_FILE" >/dev/null || die '未找到用户'
  [ "$(jq '.inbounds[0].settings.clients|length' "$CONF_FILE")" -gt 1 ] || die '不能删除最后一个用户'
  begin_tx
  edit_config --arg id "$_uuid" '.inbounds[0].settings.clients |= map(select(.id!=$id))'
  finish_tx
}
optimize() {
  need_root; load_state; auto_profile; begin_tx
  write_memory; apply_policy
  edit_config '.log.access="none" | .log.loglevel="warning"'
  VERIFY_MEMORY=1; finish_tx
  printf '有效内存=%sMiB GOMEMLIMIT=%s GOGC=%s connIdle=%ss bufferSize=%sKB\n' "$MEM_MB" "$LIMIT" "$GC" "$IDLE" "$BUFFER"
}
set_memory() {
  need_root; load_state
  LIMIT=${1:-}; GC=${2:-}
  printf '%s\n' "$LIMIT" | grep -Eq '^[1-9][0-9]*(KiB|MiB|GiB)$' || die '限制格式例如 40MiB'
  valid_uint "$GC" 1 500 || die 'GOGC 必须为 1-500'
  begin_tx; write_memory; VERIFY_MEMORY=1; finish_tx
}
reset_memory() {
  need_root; load_state; begin_tx
  _mem_tmp=$(mktemp /etc/conf.d/.xray.XXXXXX)
  strip_memory_block "$OPENRC_CONF" "$_mem_tmp"
  chmod 600 "$_mem_tmp"; mv "$_mem_tmp" "$OPENRC_CONF"
  finish_tx
}
set_policy() {
  need_root; load_state
  IDLE=${1:-}; BUFFER=${2:-}; HANDSHAKE=${3:-15}
  valid_uint "$IDLE" 30 86400 || die '空闲时间必须为 30-86400 秒'
  valid_uint "$BUFFER" 4 4096 || die '缓冲必须为 4-4096 KB'
  valid_uint "$HANDSHAKE" 4 120 || die '握手时间必须为 4-120 秒'
  begin_tx; apply_policy; finish_tx
}
update_core() {
  need_root; load_state; install_deps; auto_profile; begin_tx core
  # Installer may restart the service; its existing persistent settings survive.
  install_core; finish_tx
  core version | head -1
}
memory_status() {
  printf '有效内存上限: %sMiB\n' "$(effective_memory_mb)"
  _pid=$(xray_listener_pid || true)
  if [ -n "$_pid" ]; then
    awk '/^VmRSS:|^VmPeak:/{print}' "/proc/$_pid/status"
    tr '\0' '\n' <"/proc/$_pid/environ" | grep -E '^(GOMEMLIMIT|GOGC)=' || true
  fi
  for _f in memory.max memory.high memory.current memory.peak memory.swap.max memory.events; do
    if [ -r "/sys/fs/cgroup/$_f" ]; then printf '%s:\n' "$_f"; cat "/sys/fs/cgroup/$_f"; fi
  done
  if [ -r "$CONF_FILE" ]; then jq '.policy' "$CONF_FILE"; fi
}
status() {
  core version | head -1
  rc-service xray status || true
  service_ready || die '服务未监听配置端口，请检查 log 和 memory'
  netstat -lntp 2>/dev/null | grep '/xray' || true
  memory_status
}
uninstall_all() {
  need_root
  [ "${1:-}" = --yes ] || die "确认卸载请用: $SELF uninstall --yes"
  begin_tx core
  _save=$TX_DIR; TX_DIR=''
  rc-service xray stop >/dev/null 2>&1 || true
  rc-update del xray default >/dev/null 2>&1 || true
  rm -f /etc/init.d/xray "$XRAY_BIN" "$STATE_FILE"
  _mem_tmp=$(mktemp /etc/conf.d/.xray.XXXXXX)
  strip_memory_block "$OPENRC_CONF" "$_mem_tmp"
  mv "$_mem_tmp" "$OPENRC_CONF"
  for _file in "$CONF_DIR"/*.json; do [ ! -f "$_file" ] || rm -f "$_file"; done
  printf '已删除核心、服务和 JSON 配置；可从 %s 恢复。管理脚本和日志已保留。\n' "$_save"
}

main() {
  case "${1:-}" in
    install|update|change-port|set-address|set-listen|set-sni|add-user|del-user|optimize|set-memory|reset-memory|set-policy|uninstall|start|stop|restart)
      need_root
      mkdir /run/xray-reality.lock 2>/dev/null || die '另一个管理命令正在运行；若上次被强制终止，请检查后删除 /run/xray-reality.lock'
      LOCKED=1;;
  esac
  # Bound short-lived CLI/config-test processes too; service settings are persistent.
  auto_profile
  CLI_LIMIT=$LIMIT; CLI_GC=$GC
  case "${1:-}" in
    install) shift; do_install "$@";;
    show) show_all;;
    status) status;;
    check) core run -test -confdir "$CONF_DIR";;
    memory) memory_status;;
    log) tail -n 100 /var/log/xray/error.log;;
    start|stop|restart) need_root; rc-service xray "$1";;
    update) update_core;;
    change-port) shift; change_port "$@";;
    set-address) shift; set_address "$@";;
    set-listen) shift; set_listen "$@";;
    set-sni) shift; set_sni "$@";;
    add-user) shift; add_user "$@";;
    del-user) shift; del_user "$@";;
    optimize) optimize;;
    set-memory) shift; set_memory "$@";;
    reset-memory) reset_memory;;
    set-policy) shift; set_policy "$@";;
    uninstall) shift; uninstall_all "$@";;
    --version) printf '%s\n' "$VERSION";;
    ''|-h|--help|help) usage;;
    *) usage; exit 1;;
  esac
}

# Source only in unit tests; no system mutation while importing functions.
if [ "${XRAY_REALITY_SOURCE_ONLY:-0}" != 1 ]; then
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  main "$@"
fi

