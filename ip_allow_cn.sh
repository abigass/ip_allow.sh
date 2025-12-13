#!/usr/bin/env bash

# 管理按端口的 IP 白名单，配置文件位于 ./ports/<port>/ipv4.txt 和 ./ports/<port>/ipv6.txt
# 对每个端口创建/刷新专用链：允许名单内来源访问该端口，最后一条规则为 DROP（默认拒绝）

set -euo pipefail

PORTS_DIR="${PORTS_DIR:-./ports}"
COMMENT_PREFIX="create by ipallow"
VERSION="1.0"
AUTHOR="lingye"
REPO="github.com/abigass/ip_allow.sh"

print_banner() {
  cat <<'EOF'
██╗██████╗      █████╗ ██╗     ██╗      ██████╗ ██╗    ██╗
██║██╔══██╗    ██╔══██╗██║     ██║     ██╔═══██╗██║    ██║
██║██████╔╝    ███████║██║     ██║     ██║   ██║██║ █╗ ██║
██║██╔═══╝     ██╔══██║██║     ██║     ██║   ██║██║███╗██║
██║██║         ██║  ██║███████╗███████╗╚██████╔╝╚███╔███╔╝
╚═╝╚═╝         ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝  ╚══╝╚══╝

EOF
  printf '%-6s %s\n' "版本：" "${VERSION}"
  printf '%-6s %s\n' "作者：" "${AUTHOR}"
  printf '%-6s %s\n' "仓库：" "${REPO}"
  echo "一个自动批量化设置端口 ip 白名单的脚本。"
  echo "-----------------"
  echo "用法："
  printf '  %-45s %s\n' "bash ipallow_cn.sh -h|--help" "显示帮助/版本信息"
  printf '  %-45s %s\n' "sudo bash ipallow_cn.sh <port> [port2 ...]" "仅应用指定端口白名单"
  printf '  %-45s %s\n' "sudo bash ipallow_cn.sh" "应用 ./ports 下全部端口白名单"
  printf '  %-45s %s\n' "sudo bash ipallow_cn.sh show" "从当前 iptables/ip6tables 规则展示统计"
  printf '  %-45s %s\n' "sudo bash ipallow_cn.sh delete [port ...]" "删除本脚本添加的端口白名单"
  echo
  echo "白名单文件："
  echo "  ./ports/<port>/ipv4.txt   每行一个 IPv4/CIDR（# 开头为注释）"
  echo "  ./ports/<port>/ipv6.txt   每行一个 IPv6/CIDR（# 开头为注释）"
  echo
  echo "说明："
  echo "  - 规则链为 IPALLOW_<port>（IPv4）和 IPALLOW6_<port>（IPv6）。"
  echo "  - 同时对 TCP 和 UDP 生效。"
  echo "  - 本脚本添加的规则注释为：\"${COMMENT_PREFIX},YYMMDD\"。"
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "请以 root 权限运行（iptables 需要 root）。" >&2
    exit 1
  fi
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  (( 1 <= 10#$1 && 10#$1 <= 65535 )) || return 1
  return 0
}

check_deps() {
  if ! command -v iptables >/dev/null 2>&1; then
    echo "未找到 iptables，请先安装。" >&2
    exit 1
  fi
}

check_deps_v6() {
  if ! command -v ip6tables >/dev/null 2>&1; then
    echo "未找到 ip6tables，请先安装（处理 IPv6 白名单需要）。" >&2
    exit 1
  fi
}

read_lines() {
  local file="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    echo "$line"
  done <"$file"
}

ensure_chain() {
  local cmd="$1" chain="$2"
  if ! $cmd -t filter -nL "$chain" >/dev/null 2>&1; then
    $cmd -t filter -N "$chain"
  else
    $cmd -t filter -F "$chain"
  fi
}

ensure_jump() {
  local cmd="$1" proto="$2" port="$3" chain="$4"
  if ! $cmd -t filter -C INPUT -p "$proto" --dport "$port" -j "$chain" >/dev/null 2>&1; then
    $cmd -t filter -I INPUT 1 -p "$proto" --dport "$port" -j "$chain"
  fi
}

confirm() {
  local prompt="$1"
  printf '%s' "$prompt"
  local answer
  IFS= read -r answer || true
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

delete_chain_and_jumps_v4() {
  local port="$1"
  local chain="IPALLOW_${port}"
  local deleted=0

  local proto
  for proto in tcp udp; do
    while iptables -t filter -C INPUT -p "$proto" --dport "$port" -j "$chain" >/dev/null 2>&1; do
      iptables -t filter -D INPUT -p "$proto" --dport "$port" -j "$chain"
      deleted=$((deleted + 1))
    done
  done

  set +e
  local chain_rules
  chain_rules="$(iptables -S "$chain" 2>/dev/null | grep -c '^-A ')" || chain_rules=0
  set -e
  if [[ ${chain_rules:-0} -gt 0 ]]; then
    deleted=$((deleted + chain_rules))
  fi

  if iptables -t filter -nL "$chain" >/dev/null 2>&1; then
    iptables -t filter -F "$chain" >/dev/null 2>&1 || true
    iptables -t filter -X "$chain" >/dev/null 2>&1 || true
  fi

  echo "$deleted"
}

delete_chain_and_jumps_v6() {
  local port="$1"
  command -v ip6tables >/dev/null 2>&1 || { echo 0; return; }
  local chain="IPALLOW6_${port}"
  local deleted=0

  local proto
  for proto in tcp udp; do
    while ip6tables -t filter -C INPUT -p "$proto" --dport "$port" -j "$chain" >/dev/null 2>&1; do
      ip6tables -t filter -D INPUT -p "$proto" --dport "$port" -j "$chain"
      deleted=$((deleted + 1))
    done
  done

  set +e
  local chain_rules
  chain_rules="$(ip6tables -S "$chain" 2>/dev/null | grep -c '^-A ')" || chain_rules=0
  set -e
  if [[ ${chain_rules:-0} -gt 0 ]]; then
    deleted=$((deleted + chain_rules))
  fi

  if ip6tables -t filter -nL "$chain" >/dev/null 2>&1; then
    ip6tables -t filter -F "$chain" >/dev/null 2>&1 || true
    ip6tables -t filter -X "$chain" >/dev/null 2>&1 || true
  fi

  echo "$deleted"
}

delete_port_whitelist() {
  local port="$1"
  local deleted_v4 deleted_v6
  deleted_v4="$(delete_chain_and_jumps_v4 "$port")"
  deleted_v6="$(delete_chain_and_jumps_v6 "$port")"
  echo $((deleted_v4 + deleted_v6))
}

list_managed_ports_from_rules() {
  local -A ports=()
  local line

  set +e
  local v4_out v6_out
  v4_out="$(iptables -S 2>/dev/null)" || v4_out=""
  v6_out=""
  if command -v ip6tables >/dev/null 2>&1; then
    v6_out="$(ip6tables -S 2>/dev/null)" || v6_out=""
  fi
  set -e

  while IFS= read -r line; do
    if [[ "$line" =~ ^-N[[:space:]]+IPALLOW_([0-9]+)$ ]]; then
      ports["${BASH_REMATCH[1]}"]=1
    elif [[ "$line" =~ ^-A[[:space:]]+INPUT[[:space:]].*-j[[:space:]]+IPALLOW_([0-9]+)$ ]]; then
      ports["${BASH_REMATCH[1]}"]=1
    fi
  done <<<"$v4_out"

  while IFS= read -r line; do
    if [[ "$line" =~ ^-N[[:space:]]+IPALLOW6_([0-9]+)$ ]]; then
      ports["${BASH_REMATCH[1]}"]=1
    elif [[ "$line" =~ ^-A[[:space:]]+INPUT[[:space:]].*-j[[:space:]]+IPALLOW6_([0-9]+)$ ]]; then
      ports["${BASH_REMATCH[1]}"]=1
    fi
  done <<<"$v6_out"

  printf '%s\n' "${!ports[@]}" | grep -E '^[0-9]+$' | sort -n
}

show_summary() {
  require_root

  local -A ports=()
  local -A v4_counts=()
  local -A v6_counts=()
  local -A v4_src=()
  local -A v6_src=()
  local v4_out v6_out v4_rc v6_rc
  local marker="${COMMENT_PREFIX},"

  set +e
  if command -v iptables >/dev/null 2>&1; then
    v4_out="$(iptables -S 2>&1)"; v4_rc=$?
  else
    v4_out="iptables 未找到"
    v4_rc=127
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    v6_out="$(ip6tables -S 2>&1)"; v6_rc=$?
  else
    v6_out="ip6tables 未找到"
    v6_rc=127
  fi
  set -e

  if [[ $v4_rc -ne 0 && $v6_rc -ne 0 ]]; then
    echo "读取 iptables/ip6tables 失败，请在宿主机上使用足够权限运行（例如 sudo）。" >&2
    echo "iptables 错误：$v4_out" >&2
    echo "ip6tables 错误：$v6_out" >&2
    exit 1
  fi

  if [[ $v4_rc -eq 0 ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^-N[[:space:]]+IPALLOW_([0-9]+)$ ]]; then
        ports["${BASH_REMATCH[1]}"]=1
        continue
      fi
      if [[ "$line" =~ ^-A[[:space:]]+IPALLOW_([0-9]+)[[:space:]] ]] && [[ "$line" == *"-j ACCEPT"* ]] && [[ "$line" == *"--comment"*"$marker"* ]]; then
        local port="${BASH_REMATCH[1]}"
        ports["$port"]=1
        if [[ "$line" =~ [[:space:]]-s[[:space:]]([^[:space:]]+) ]]; then
          v4_src["$port|${BASH_REMATCH[1]}"]=1
        fi
      fi
    done <<<"$v4_out"
  fi

  if [[ $v6_rc -eq 0 ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^-N[[:space:]]+IPALLOW6_([0-9]+)$ ]]; then
        ports["${BASH_REMATCH[1]}"]=1
        continue
      fi
      if [[ "$line" =~ ^-A[[:space:]]+IPALLOW6_([0-9]+)[[:space:]] ]] && [[ "$line" == *"-j ACCEPT"* ]] && [[ "$line" == *"--comment"*"$marker"* ]]; then
        local port="${BASH_REMATCH[1]}"
        ports["$port"]=1
        if [[ "$line" =~ [[:space:]]-s[[:space:]]([^[:space:]]+) ]]; then
          v6_src["$port|${BASH_REMATCH[1]}"]=1
        fi
      fi
    done <<<"$v6_out"
  fi

  local k
  for k in "${!v4_src[@]}"; do
    v4_counts["${k%%|*}"]=$(( ${v4_counts["${k%%|*}"]:-0} + 1 ))
  done
  for k in "${!v6_src[@]}"; do
    v6_counts["${k%%|*}"]=$(( ${v6_counts["${k%%|*}"]:-0} + 1 ))
  done

  printf '%-8s %-10s %-10s\n' "端口" "IPv4数量" "IPv6数量"
  if [[ ${#ports[@]} -eq 0 ]]; then
    echo "未找到本脚本管理的端口（未发现 IPALLOW_* 规则链）。" >&2
    return 0
  fi

  local port
  while IFS= read -r port; do
    [[ -n "$port" ]] || continue
    printf '%-8s %-10s %-10s\n' "$port" "${v4_counts[$port]:-0}" "${v6_counts[$port]:-0}"
  done < <(printf '%s\n' "${!ports[@]}" | sort -n)
}

apply_port_rules() {
  local port="$1"
  if ! is_valid_port "$port"; then
    echo "无效端口：$port" >&2
    return 0
  fi
  local file_v4="$PORTS_DIR/$port/ipv4.txt"
  local file_v6="$PORTS_DIR/$port/ipv6.txt"

  if [[ ! -f "$file_v4" && ! -f "$file_v6" ]]; then
    echo "跳过端口 $port：未找到 $file_v4 或 $file_v6" >&2
    return
  fi

  local comment="${COMMENT_PREFIX},$(date '+%y%m%d')"

  if [[ -f "$file_v4" ]]; then
    local chain_v4="IPALLOW_${port}"
    ensure_chain iptables "$chain_v4"
    local ok4=0 bad4=0
    while IFS= read -r ip; do
      if iptables -t filter -A "$chain_v4" -s "$ip" -m comment --comment "$comment" -j ACCEPT; then
        ok4=$((ok4 + 1))
      else
        bad4=$((bad4 + 1))
        echo "端口 $port：无效 IPv4 条目已跳过：$ip" >&2
      fi
    done < <(read_lines "$file_v4")
    iptables -t filter -A "$chain_v4" -m comment --comment "$comment" -j DROP
    ensure_jump iptables tcp "$port" "$chain_v4"
    ensure_jump iptables udp "$port" "$chain_v4"
    echo "端口 $port IPv4 白名单已刷新，规则链：$chain_v4（已添加：$ok4，已跳过：$bad4）"
  else
    echo "端口 $port 未找到 IPv4 名单文件：$file_v4" >&2
  fi

  if [[ -f "$file_v6" ]]; then
    check_deps_v6
    local chain_v6="IPALLOW6_${port}"
    ensure_chain ip6tables "$chain_v6"
    local ok6=0 bad6=0
    while IFS= read -r ip; do
      if ip6tables -t filter -A "$chain_v6" -s "$ip" -m comment --comment "$comment" -j ACCEPT; then
        ok6=$((ok6 + 1))
      else
        bad6=$((bad6 + 1))
        echo "端口 $port：无效 IPv6 条目已跳过：$ip" >&2
      fi
    done < <(read_lines "$file_v6")
    ip6tables -t filter -A "$chain_v6" -m comment --comment "$comment" -j DROP
    ensure_jump ip6tables tcp "$port" "$chain_v6"
    ensure_jump ip6tables udp "$port" "$chain_v6"
    echo "端口 $port IPv6 白名单已刷新，规则链：$chain_v6（已添加：$ok6，已跳过：$bad6）"
  else
    echo "端口 $port 未找到 IPv6 名单文件：$file_v6" >&2
  fi
}

main() {
  case "${1:-}" in
    h|help|/h|/help|-h|-help|--h|--help|v|version|/v|/version|-v|-version|--v|--version)
      set +e
      set +o pipefail
      print_banner 2>/dev/null
      return 0
      ;;
  esac

  if [[ ${1:-} == "show" ]]; then
    show_summary
    return 0
  fi

  if [[ ${1:-} == "delete" ]]; then
    shift || true
    require_root
    check_deps

    local -a ports=()
    if [[ $# -eq 0 ]]; then
      if ! confirm "是否确认清除所有本脚本添加的端口ip白名单？[y/N] "; then
        return 0
      fi
      mapfile -t ports < <(list_managed_ports_from_rules)
    else
      local p
      for p in "$@"; do
        if ! is_valid_port "$p"; then
          echo "无效端口：$p" >&2
          exit 1
        fi
        ports+=("$p")
      done
      mapfile -t ports < <(printf '%s\n' "${ports[@]}" | sort -n | uniq)
      if [[ ${#ports[@]} -eq 1 ]]; then
        if ! confirm "是否确认清除${ports[0]}端口ip白名单？[y/N] "; then
          return 0
        fi
      else
        if ! confirm "是否确认清除端口（${ports[*]}）ip白名单？[y/N] "; then
          return 0
        fi
      fi
    fi

    if [[ ${#ports[@]} -eq 0 ]]; then
      echo "未找到本脚本管理的端口白名单。"
      return 0
    fi

    local total_ports=0
    local port deleted
    for port in "${ports[@]}"; do
      deleted="$(delete_port_whitelist "$port")"
      echo "已删除${port}端口：共${deleted}条"
      total_ports=$((total_ports + 1))
    done
    if [[ $total_ports -gt 1 ]]; then
      echo "共删除${total_ports}个端口的白名单"
    fi
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    if [[ ! -d "$PORTS_DIR" ]]; then
      print_banner
      return 0
    fi
    shopt -s nullglob
    local dirs=("$PORTS_DIR"/*)
    shopt -u nullglob
    if [[ ${#dirs[@]} -eq 0 ]]; then
      print_banner
      return 0
    fi
  fi

  require_root
  check_deps

  if [[ ! -d "$PORTS_DIR" ]]; then
    echo "未找到目录：$PORTS_DIR" >&2
    exit 1
  fi

  if [[ $# -gt 0 ]]; then
    for port in "$@"; do
      if ! is_valid_port "$port"; then
        echo "无效端口：$port" >&2
        exit 1
      fi
      apply_port_rules "$port"
    done
  else
    shopt -s nullglob
    local dirs=("$PORTS_DIR"/*)
    shopt -u nullglob
    if [[ ${#dirs[@]} -eq 0 ]]; then
      echo "没有需要处理的端口目录。" >&2
      exit 1
    fi
    for dir in "${dirs[@]}"; do
      port="$(basename "$dir")"
      if ! is_valid_port "$port"; then
        continue
      fi
      apply_port_rules "$port"
    done
  fi
}

main "$@"
