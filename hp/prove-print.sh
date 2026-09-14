#!/usr/bin/env bash
# prove-print.sh — send a colour test page to prove both ink paths work
#
# Sends one line in black ink and one line in colour (blue) ink.
# Use this to answer "has my colour cartridge run out?" or "is my printer
# actually working?" after running diagnostics or repair.

set -u
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/lib/printer-discovery.sh
. "$script_dir/lib/printer-discovery.sh"

QUEUE=""
HOST=""
TIMEOUT_SECONDS=4

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

parse_args() {
  local parse_error=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --queue|--host|--timeout)
        if [ "$#" -lt 2 ]; then
          parse_error="$1 requires a value"
          shift
          continue
        fi
        set_option "$1" "$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        parse_error="Unknown option: $1"
        shift
        ;;
    esac
  done

  [ -z "$parse_error" ] || usage_error "$parse_error"
}

set_option() {
  case "$1" in
    --queue) QUEUE="$2" ;;
    --host) HOST="$2" ;;
    --timeout) TIMEOUT_SECONDS="$2" ;;
  esac
}

discover_host() {
  local device_uri service_name

  device_uri="$(device_uri_for_queue "$(lpstat -p -d -v 2>/dev/null || true)" "$QUEUE")"
  service_name="$(bonjour_service_name "$device_uri")"
  if [ -n "$service_name" ] && have dns-sd; then
    HOST="$(host_from_dnssd_lookup "$(dnssd_lookup_service "$TIMEOUT_SECONDS" "$service_name")")"
  fi
  if [ -z "$HOST" ]; then
    HOST="$(host_from_ipp_uri "$device_uri")"
  fi
}

resolve_endpoint() {
  local resolved_ip=""

  if [ -n "$HOST" ] && have dns-sd; then
    resolved_ip="$(first_ipv4 "$(run_for_seconds "$TIMEOUT_SECONDS" dns-sd -G v4v6 "$HOST")")"
  fi
  if [ -z "$resolved_ip" ] && is_ipv4 "$HOST"; then
    resolved_ip="$HOST"
  fi
  printf '%s' "${resolved_ip:-$HOST}"
}

trim() {
  printf '%s' "$1" | sed 's/^ *//; s/ *$//'
}

# "black ink", "Black Cartridge" or HP's bare "K" label; not the k in "tri-color ink".
ink_label() {
  if printf '%s' "$1" | grep -Eqi '(^|[^[:alpha:]])black([^[:alpha:]]|$)|^k$'; then
    printf 'black ink'
  else
    printf 'colour ink'
  fi
}

# Pair comma-separated IPP marker names with their levels.
print_ink_levels() {
  local marker_names="$1"
  local marker_levels="$2"
  local names levels i name

  if [ -z "$marker_names" ] || [ -z "$marker_levels" ]; then
    printf 'Ink levels: (could not read from printer)\n'
    return 0
  fi

  printf 'Ink levels before printing:\n'
  IFS=',' read -ra names <<< "$marker_names"
  IFS=',' read -ra levels <<< "$marker_levels"
  for i in "${!names[@]}"; do
    name="$(trim "${names[$i]}")"
    [ -n "$name" ] || continue
    printf '  %s: %s%%\n' "$(ink_label "$name")" "$(trim "${levels[$i]:-}")"
  done
}

report_ink_levels() {
  local endpoint="$1"
  local ipp_raw=""

  if [ -n "$endpoint" ] && have ipptool; then
    ipp_raw="$(ipp_query "$endpoint" get-printer-attributes)"
  fi

  print_ink_levels \
    "$(extract_ipptool_value "$ipp_raw" "marker-names")" \
    "$(extract_ipptool_value "$ipp_raw" "marker-levels")"
}

write_test_page() {
  cat > "$1" <<'PSEOF'
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
}

send_test_page() {
  local ps_file

  # BSD mktemp only fills trailing X's, so the template must end in them.
  ps_file="$(mktemp "${TMPDIR:-/tmp}/prove-print.XXXXXX")"
  register_temp_file "$ps_file"
  write_test_page "$ps_file"

  printf '\nSending test page to %s...\n' "$QUEUE"
  lp -d "$QUEUE" "$ps_file" 2>&1 || die "Failed to send test page to printer"
}

main() {
  parse_args "$@"

  have lpstat || die "lpstat is required"
  have lp     || die "lp is required"

  [ -n "$QUEUE" ] || QUEUE="$(detect_default_queue)"
  [ -n "$QUEUE" ] || die "No CUPS printer queue found. Use --queue or connect a printer."
  [ -n "$HOST" ] || discover_host

  printf '\n== Colour Test Print ==\n'
  printf 'Queue: %s\n' "$QUEUE"
  report_ink_levels "$(resolve_endpoint)"

  send_test_page

  printf '\nThe test page has been sent.\n'
  printf 'Please check the printer:\n'
  printf '  - One line should be printed in BLACK ink\n'
  printf '  - One line should be printed in COLOUR (blue) ink\n'
  printf '\n'
  printf 'If the blue line did not print, your colour cartridge may need replacing.\n'
  printf 'If nothing printed, run: ./hp/repair.sh --execute\n'
}

trap cleanup_temp_files EXIT
main "$@"
