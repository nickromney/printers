#!/usr/bin/env bash
#
# Shared helpers for finding a CUPS queue and the printer behind it.
# Sourced by printer-common.sh and prove-print.sh; defines functions only.

TEMP_FILES=()

register_temp_file() {
  TEMP_FILES+=("$1")
}

cleanup_temp_files() {
  local temp_file

  if [ "${TEMP_FILES[0]+set}" != "set" ]; then
    return 0
  fi

  for temp_file in "${TEMP_FILES[@]}"; do
    rm -f "$temp_file"
  done
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

url_decode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

# Run a command for at most SECONDS, then print whatever it wrote.
run_for_seconds() {
  local seconds="$1"
  shift

  local tmp
  local pid
  local waited=0

  tmp="$(mktemp)"
  register_temp_file "$tmp"
  "$@" >"$tmp" 2>&1 &
  pid="$!"

  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$seconds" ]; do
    sleep 1
    waited=$((waited + 1))
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  cat "$tmp"
  rm -f "$tmp"
}

extract_ipptool_value() {
  local raw="$1"
  local key="$2"

  printf '%s\n' "$raw" \
    | grep -E "^[[:space:]]*$key \\(" \
    | head -n 1 \
    | sed 's/^[^=]*= //'
}

ipp_query() {
  local host="$1"
  local test_name="$2"

  ipptool -tv "ipp://$host/ipp/print" "/usr/share/cups/ipptool/$test_name.test" 2>&1 || true
}

# The system default queue, else the first queue lpstat lists.
detect_default_queue() {
  local queue

  queue="$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p' | head -n 1)"
  if [ -z "$queue" ]; then
    queue="$(lpstat -p 2>/dev/null | awk '/^printer / { print $2; exit }')"
  fi
  printf '%s' "$queue"
}

device_uri_for_queue() {
  local overview="$1"
  local queue="$2"

  printf '%s\n' "$overview" | awk -v q="$queue" '$1 == "device" && $3 == (q ":") { sub(/^device for [^:]+: /, ""); print; exit }'
}

bonjour_service_name() {
  local device_uri="$1"
  local name

  case "$device_uri" in
    dnssd://*) ;;
    *) return 0 ;;
  esac

  name="${device_uri#dnssd://}"
  name="${name%%._ipp._tcp.local.*}"
  url_decode "$name"
}

# Prints the dns-sd lookup transcript; the host is the last "reached at" line.
dnssd_lookup_service() {
  local timeout="$1"
  local service="$2"

  run_for_seconds "$timeout" dns-sd -L "$service" _ipp._tcp local.
}

host_from_dnssd_lookup() {
  local host

  host="$(printf '%s\n' "$1" | sed -n 's/.* can be reached at \([^:]*\):.*/\1/p' | tail -n 1)"
  printf '%s' "${host%.}"
}

host_from_ipp_uri() {
  printf '%s\n' "$1" | sed -En 's#^ipps?://([^/:?]*).*#\1#p' | head -n 1
}

first_ipv4() {
  printf '%s\n' "$1" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1
}

is_ipv4() {
  printf '%s' "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}
