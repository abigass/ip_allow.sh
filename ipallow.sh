#!/usr/bin/env bash

# Manage per-port IP whitelists stored under ./ports/<port>/ipv4.txt and ipv6.txt.
# For each port, we create/refresh a dedicated iptables chain that
# accepts listed IPs and drops everything else for that port.

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
  printf '%-8s %s\n' "version:" "${VERSION}"
  printf '%-8s %s\n' "author:" "${AUTHOR}"
  printf '%-8s %s\n' "repo:" "${REPO}"
  echo "An automated script to batch-configure per-port IP whitelists."
  echo "-----------------"
  echo "usage:"
  printf '  %-45s %s\n' "bash ipallow.sh -h|--help" "Show help/version"
  printf '  %-45s %s\n' "sudo bash ipallow.sh add <port> [port2 ...]" "Interactively append entries and apply whitelist"
  printf '  %-45s %s\n' "sudo bash ipallow.sh <port> [port2 ...]" "Apply whitelist for one/more ports"
  printf '  %-45s %s\n' "sudo bash ipallow.sh" "Apply whitelist for all ports under ./ports"
  printf '  %-45s %s\n' "sudo bash ipallow.sh show" "Show counts from current iptables/ip6tables rules"
  printf '  %-45s %s\n' "sudo bash ipallow.sh delete [port ...]" "Delete whitelist rules created by this script"
  echo
  echo "whitelist files:"
  echo "  ./ports/<port>/ipv4.txt   One IPv4/CIDR per line (# for comments)"
  echo "  ./ports/<port>/ipv6.txt   One IPv6/CIDR per line (# for comments)"
  echo
  echo "notes:"
  echo "  - Rules are created in chains IPALLOW_<port> (IPv4) and IPALLOW6_<port> (IPv6)."
  echo "  - Both TCP and UDP are enforced for the port."
  echo "  - Rules added by this script include comment: \"${COMMENT_PREFIX},YYMMDD\"."
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Please run as root (iptables requires root privileges)." >&2
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
    echo "iptables not found; please install it first." >&2
    exit 1
  fi
}

check_deps_v6() {
  if ! command -v ip6tables >/dev/null 2>&1; then
    echo "ip6tables not found; please install it first (required for IPv6 whitelist)." >&2
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

confirm_default_yes() {
  local prompt="$1"
  printf '%s' "$prompt"
  local answer
  IFS= read -r answer || true
  case "$answer" in
    ""|y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    *) return 1 ;;
  esac
}

sanitize_entry() {
  local line="$1"
  line="${line%$'\r'}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && return 1
  [[ "$line" =~ ^# ]] && return 1
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/[[:space:]]*$//')"
  [[ -z "$line" ]] && return 1
  printf '%s' "$line"
}

append_lines_to_file() {
  local file="$1"
  shift
  [[ $# -gt 0 ]] || return 0
  mkdir -p "$(dirname "$file")"
  : >>"$file"
  if [[ -s "$file" ]]; then
    local last_hex
    last_hex="$(tail -c 1 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
    if [[ -n "$last_hex" && "$last_hex" != "0a" ]]; then
      printf '\n' >>"$file"
    fi
  fi
  printf '%s\n' "$@" >>"$file"
}

dedupe_whitelist_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  local -A seen=()
  local line entry
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if entry="$(sanitize_entry "$line")"; then
      if [[ -z "${seen[$entry]:-}" ]]; then
        seen["$entry"]=1
        printf '%s\n' "$line" >>"$tmp"
      fi
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"
  mv "$tmp" "$file"
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
    v4_out="iptables not found"
    v4_rc=127
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    v6_out="$(ip6tables -S 2>&1)"; v6_rc=$?
  else
    v6_out="ip6tables not found"
    v6_rc=127
  fi
  set -e

  if [[ $v4_rc -ne 0 && $v6_rc -ne 0 ]]; then
    echo "Failed to read iptables/ip6tables rules. Please run with sufficient privileges (e.g. sudo) on the host." >&2
    echo "iptables error: $v4_out" >&2
    echo "ip6tables error: $v6_out" >&2
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

  printf '%-8s %-10s %-10s\n' "PORT" "IPv4_CNT" "IPv6_CNT"
  if [[ ${#ports[@]} -eq 0 ]]; then
    echo "No IPALLOW-managed ports found." >&2
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
    echo "Invalid port: $port" >&2
    return 0
  fi
  local file_v4="$PORTS_DIR/$port/ipv4.txt"
  local file_v6="$PORTS_DIR/$port/ipv6.txt"

  if [[ ! -f "$file_v4" && ! -f "$file_v6" ]]; then
    echo "Skipping port $port: neither $file_v4 nor $file_v6 exists" >&2
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
        echo "Port $port: invalid IPv4 entry skipped: $ip" >&2
      fi
    done < <(read_lines "$file_v4")
    iptables -t filter -A "$chain_v4" -m comment --comment "$comment" -j DROP
    ensure_jump iptables tcp "$port" "$chain_v4"
    ensure_jump iptables udp "$port" "$chain_v4"
    echo "Port $port IPv4 whitelist refreshed; chain: $chain_v4 (accepted: $ok4, skipped: $bad4)"
  else
    echo "Port $port: IPv4 file not found: $file_v4" >&2
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
        echo "Port $port: invalid IPv6 entry skipped: $ip" >&2
      fi
    done < <(read_lines "$file_v6")
    ip6tables -t filter -A "$chain_v6" -m comment --comment "$comment" -j DROP
    ensure_jump ip6tables tcp "$port" "$chain_v6"
    ensure_jump ip6tables udp "$port" "$chain_v6"
    echo "Port $port IPv6 whitelist refreshed; chain: $chain_v6 (accepted: $ok6, skipped: $bad6)"
  else
    echo "Port $port: IPv6 file not found: $file_v6" >&2
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

  if [[ ${1:-} == "add" ]]; then
    shift || true
    if [[ $# -lt 1 ]]; then
      echo "Usage: sudo bash ipallow.sh add <port> [port2 ...]" >&2
      exit 1
    fi

    local -a ports=()
    local p
    for p in "$@"; do
      if ! is_valid_port "$p"; then
        echo "Invalid port: $p" >&2
        exit 1
      fi
      ports+=("$p")
    done
    mapfile -t ports < <(printf '%s\n' "${ports[@]}" | sort -n | uniq)

    local ports_csv
    ports_csv="$(IFS=,; echo "${ports[*]}")"
    echo "Add the following IP entries to port ${ports_csv} whitelist:"

    local -a raw_lines=()
    local idx=0
    while true; do
      printf '[%03d]>>>' "$idx"
      local line
      IFS= read -r line || true
      if [[ "$line" == "q" ]]; then
        break
      fi
      raw_lines+=("$line")
      idx=$((idx + 1))

      local saw_quit=0
      while IFS= read -r -t 0.01 line; do
        if [[ "$line" == "q" ]]; then
          saw_quit=1
          break
        fi
        raw_lines+=("$line")
        idx=$((idx + 1))
      done
      if [[ $saw_quit -eq 1 ]]; then
        break
      fi
    done

    local -a entries=()
    local l
    for l in "${raw_lines[@]}"; do
      if l="$(sanitize_entry "$l")"; then
        entries+=("$l")
      fi
    done

    local total="${#entries[@]}"
    if [[ $total -eq 0 ]]; then
      echo "No IP entries provided; nothing to do."
      return 0
    fi

    if ! confirm_default_yes "Save ${total} IP whitelist entries to ${ports_csv}? [Y/n] "; then
      echo "Cancelled."
      return 0
    fi

    require_root
    check_deps

    local -a v4=()
    local -a v6=()
    for l in "${entries[@]}"; do
      if [[ "$l" == *:* ]]; then
        v6+=("$l")
      else
        v4+=("$l")
      fi
    done

    local port
    for port in "${ports[@]}"; do
      if [[ ${#v4[@]} -gt 0 ]]; then
        append_lines_to_file "$PORTS_DIR/$port/ipv4.txt" "${v4[@]}"
      fi
      if [[ ${#v6[@]} -gt 0 ]]; then
        append_lines_to_file "$PORTS_DIR/$port/ipv6.txt" "${v6[@]}"
      fi
    done

    for port in "${ports[@]}"; do
      dedupe_whitelist_file "$PORTS_DIR/$port/ipv4.txt"
      dedupe_whitelist_file "$PORTS_DIR/$port/ipv6.txt"
    done

    for port in "${ports[@]}"; do
      apply_port_rules "$port"
    done
    return 0
  fi

  if [[ ${1:-} == "delete" ]]; then
    shift || true
    require_root
    check_deps

    local -a ports=()
    if [[ $# -eq 0 ]]; then
      if ! confirm "Are you sure you want to clear all port IP whitelists created by this script? [y/N] "; then
        return 0
      fi
      mapfile -t ports < <(list_managed_ports_from_rules)
    else
      local p
      for p in "$@"; do
        if ! is_valid_port "$p"; then
          echo "Invalid port: $p" >&2
          exit 1
        fi
        ports+=("$p")
      done
      mapfile -t ports < <(printf '%s\n' "${ports[@]}" | sort -n | uniq)
      if [[ ${#ports[@]} -eq 1 ]]; then
        if ! confirm "Are you sure you want to clear port ${ports[0]} IP whitelist? [y/N] "; then
          return 0
        fi
      else
        if ! confirm "Are you sure you want to clear IP whitelists for ports (${ports[*]})? [y/N] "; then
          return 0
        fi
      fi
    fi

    if [[ ${#ports[@]} -eq 0 ]]; then
      echo "No IPALLOW-managed ports found."
      return 0
    fi

    local total_ports=0
    local port deleted
    for port in "${ports[@]}"; do
      deleted="$(delete_port_whitelist "$port")"
      echo "Deleted port $port: total $deleted rules"
      total_ports=$((total_ports + 1))
    done
    if [[ $total_ports -gt 1 ]]; then
      echo "Deleted whitelists for $total_ports ports"
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
    echo "Directory not found: $PORTS_DIR" >&2
    exit 1
  fi

  if [[ $# -gt 0 ]]; then
    for port in "$@"; do
      if ! is_valid_port "$port"; then
        echo "Invalid port: $port" >&2
        exit 1
      fi
      apply_port_rules "$port"
    done
  else
    shopt -s nullglob
    local dirs=("$PORTS_DIR"/*)
    shopt -u nullglob
    if [[ ${#dirs[@]} -eq 0 ]]; then
      echo "No port directories found to process." >&2
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
