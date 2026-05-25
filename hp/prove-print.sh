#!/usr/bin/env bash
# prove-print.sh — send a colour test page to prove both ink paths work
#
# Sends one line in black ink and one line in colour (blue) ink.
# Use this to answer "has my colour cartridge run out?" or "is my printer
# actually working?" after running diagnostics or repair.

set -u
set -o pipefail

QUEUE=""
HOST=""
TIMEOUT_SECONDS=4
HELP_REQUESTED=0
PARSE_ERROR=""

usage() {
  cat <<'EOF'
Usage:
  ./prove-print.sh [options]

Description:
  Send a colour test page to your printer.
  The page prints one line in black ink and one line in colour (blue) ink.
  Use this to confirm both ink cartridges are working.

Options:
  --queue NAME       CUPS queue name. Detected automatically if not given.
  --host HOST        Printer hostname or IP address. Detected automatically.
  --timeout SECONDS  Timeout for printer discovery. Default: 4
  -h, --help         Show this help text.

Examples:
  ./prove-print.sh
  ./prove-print.sh --host 192.168.1.42
  ./prove-print.sh --queue HP_DeskJet_4155e
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

url_decode() {
  local data="${1//+/ }"
  printf '%b' "${data//%/\\x}"
}

run_for_seconds() {
  local seconds="$1"
  shift
  local tmp pid waited=0
  tmp="$(mktemp)"
  "$@" >"$tmp" 2>&1 &
  pid="$!"
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$seconds" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  else
    wait "$pid" 2>/dev/null || true
  fi
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

# Parse arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --queue)
      [ "$#" -ge 2 ] || { PARSE_ERROR="--queue requires a value"; shift; continue; }
      QUEUE="$2"; shift 2 ;;
    --host)
      [ "$#" -ge 2 ] || { PARSE_ERROR="--host requires a value"; shift; continue; }
      HOST="$2"; shift 2 ;;
    --timeout)
      [ "$#" -ge 2 ] || { PARSE_ERROR="--timeout requires a value"; shift; continue; }
      TIMEOUT_SECONDS="$2"; shift 2 ;;
    -h|--help)
      HELP_REQUESTED=1; shift ;;
    *)
      PARSE_ERROR="Unknown option: $1"; shift ;;
  esac
done

if [ "$HELP_REQUESTED" -eq 1 ]; then
  usage
  exit 0
fi

if [ -n "$PARSE_ERROR" ]; then
  printf 'ERROR: %s\n' "$PARSE_ERROR" >&2
  exit 2
fi

have lpstat || die "lpstat is required"
have lp     || die "lp is required"

# Auto-detect queue
if [ -z "$QUEUE" ]; then
  QUEUE="$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p' | head -n 1)"
fi
if [ -z "$QUEUE" ]; then
  QUEUE="$(lpstat -p 2>/dev/null | awk '/^printer / { print $2; exit }')"
fi
[ -n "$QUEUE" ] || die "No CUPS printer queue found. Use --queue or connect a printer."

# Resolve host via dns-sd if not given
if [ -z "$HOST" ]; then
  CUPS_OVERVIEW="$(lpstat -p -d -v 2>/dev/null || true)"
  DEVICE_URI="$(printf '%s\n' "$CUPS_OVERVIEW" | awk -v q="$QUEUE" '$1 == "device" && $3 == (q ":") { sub(/^device for [^:]+: /, ""); print; exit }')"
  SERVICE_NAME=""
  if printf '%s' "${DEVICE_URI:-}" | grep -q '^dnssd://'; then
    SERVICE_NAME="${DEVICE_URI#dnssd://}"
    SERVICE_NAME="${SERVICE_NAME%%._ipp._tcp.local.*}"
    SERVICE_NAME="$(url_decode "$SERVICE_NAME")"
  fi
  if [ -n "$SERVICE_NAME" ] && have dns-sd; then
    DNS_SD_LOOKUP="$(run_for_seconds "$TIMEOUT_SECONDS" dns-sd -L "$SERVICE_NAME" _ipp._tcp local.)"
    HOST="$(printf '%s\n' "$DNS_SD_LOOKUP" | sed -n 's/.* can be reached at \([^:]*\):.*/\1/p' | tail -n 1)"
    HOST="${HOST%.}"
  fi
  if [ -z "$HOST" ] && printf '%s' "${DEVICE_URI:-}" | grep -Eq '^ipps?://'; then
    HOST="$(printf '%s\n' "${DEVICE_URI:-}" | sed -n 's|^ipps\?://\([^/:?]*\).*|\1|p' | head -n 1)"
  fi
fi

# Resolve IPv4 if needed
RESOLVED_IP=""
if [ -n "$HOST" ] && have dns-sd; then
  DNS_SD_RESOLVE="$(run_for_seconds "$TIMEOUT_SECONDS" dns-sd -G v4v6 "$HOST")"
  RESOLVED_IP="$(printf '%s\n' "$DNS_SD_RESOLVE" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)"
fi
if [ -z "$RESOLVED_IP" ] && printf '%s' "${HOST:-}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  RESOLVED_IP="$HOST"
fi
ENDPOINT_HOST="${RESOLVED_IP:-$HOST}"

# Read ink levels before sending
MARKER_NAMES=""
MARKER_LEVELS=""
if [ -n "$ENDPOINT_HOST" ] && have ipptool; then
  IPP_RAW="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-printer-attributes.test 2>&1 || true)"
  MARKER_NAMES="$(extract_ipptool_value "$IPP_RAW" "marker-names")"
  MARKER_LEVELS="$(extract_ipptool_value "$IPP_RAW" "marker-levels")"
fi

printf '\n== Colour Test Print ==\n'
printf 'Queue: %s\n' "$QUEUE"
if [ -n "$MARKER_NAMES" ] && [ -n "$MARKER_LEVELS" ]; then
  printf 'Ink levels before printing:\n'
  # Pair names and levels (comma-separated) for display
  IFS=',' read -ra names <<< "$MARKER_NAMES"
  IFS=',' read -ra levels <<< "$MARKER_LEVELS"
  for i in "${!names[@]}"; do
    name="$(printf '%s' "${names[$i]:-}" | sed 's/^ *//; s/ *$//')"
    level="$(printf '%s' "${levels[$i]:-}" | sed 's/^ *//; s/ *$//')"
    if [ -n "$name" ]; then
      if printf '%s' "$name" | grep -qi 'black\|K\b'; then
        printf '  black ink: %s%%\n' "$level"
      else
        printf '  colour ink: %s%%\n' "$level"
      fi
    fi
  done
else
  printf 'Ink levels: (could not read from printer)\n'
fi

# Generate PostScript test page
PS_FILE="$(mktemp /tmp/prove-print-XXXXXX.ps)"
trap 'rm -f "$PS_FILE"' EXIT INT TERM

cat > "$PS_FILE" <<'PSEOF'
%!PS-Adobe-3.0
%%Title: Colour Ink Test Page
%%Creator: prove-print.sh
%%Pages: 1
%%EndComments

%%Page: 1 1

% ---- Page header ----
0 0 0 setrgbcolor
/Helvetica-Bold findfont 14 scalefont setfont
144 730 moveto
(Colour Ink Test Page) show

0 0 0 setrgbcolor
/Helvetica findfont 11 scalefont setfont
144 710 moveto
(If both lines below are visible and clearly coloured, your printer is working.) show

% ---- Black ink line ----
0 0 0 setrgbcolor
/Helvetica-Bold findfont 18 scalefont setfont
144 640 moveto
(This line prints in black ink.) show

% ---- Colour (blue) ink line ----
0.08 0.45 0.85 setrgbcolor
/Helvetica-Bold findfont 18 scalefont setfont
144 590 moveto
(This line prints in colour ink.) show

% ---- Explanation ----
0 0 0 setrgbcolor
/Helvetica findfont 10 scalefont setfont
144 540 moveto
(If the black line printed but the blue line did not: your colour cartridge needs replacing.) show
144 526 moveto
(If neither line printed: check the printer is turned on and has paper.) show

showpage
%%EOF
PSEOF

# Send to printer
printf '\nSending test page to %s...\n' "$QUEUE"
lp -d "$QUEUE" "$PS_FILE" 2>&1 || die "Failed to send test page to printer"

printf '\nThe test page has been sent.\n'
printf 'Please check the printer:\n'
printf '  - One line should be printed in BLACK ink\n'
printf '  - One line should be printed in COLOUR (blue) ink\n'
printf '\n'
printf 'If the blue line did not print, your colour cartridge may need replacing.\n'
printf 'If nothing printed, run: ./hp/repair.sh --execute\n'
