#!/usr/bin/env bash

set -u
set -o pipefail

lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/printer-discovery.sh
. "$lib_dir/printer-discovery.sh"

QUEUE=""
HOST=""
COMMUNITY="public"
OUTPUT_DIR=""
SAVE_RAW=0
TIMEOUT_SECONDS=4
MONITOR_PRINTING=0
MONITOR_INTERVAL=3
MONITOR_SAMPLES=20
PLAIN_OUTPUT=0
COMMAND="${HP_COMMAND_MODE:-diagnose}"
HELP_REQUESTED=0
PARSE_ERROR=""
REPAIR_ACTION_SELECTED=0
SEND_SOFT_RESET_PJL=0
EXPERIMENTAL_CLEAR_JOBS=0
CANCEL_CONNECTING=0

RESOLVED_IP=""
ENDPOINT_HOST=""
RESET_TIMESTAMP=""

CANCEL_CONNECTING_TIMESTAMP=""
CANCEL_CONNECTING_HTTP_CODE=""
CANCEL_CONNECTING_PRE_CONFIG_XML=""
CANCEL_CONNECTING_POST_CONFIG_XML=""
CANCEL_CONNECTING_PRE_STATUS_XML=""
CANCEL_CONNECTING_POST_STATUS_XML=""
CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML=""
CANCEL_CONNECTING_POST_SUBSCRIPTION_XML=""

EXPERIMENTAL_ACTION_LOG=""
POST_ACTION_JOB_LIST_XML=""
POST_ACTION_STATUS_XML=""
POST_ACTION_IPP_RAW=""
POST_ACTION_JOB_LIST_SUMMARY=""
POST_ACTION_STATUS_CATEGORY=""
POST_ACTION_IPP_STATE=""
POST_ACTION_IPP_REASONS=""
POST_ACTION_IPP_QUEUED=""

MONITOR_LAST_ACTIVE=0

# Endpoints read for the --plain summary: VARIABLE|path|raw capture name.
# Plain mode does not write raw captures, so the third column is empty.
HP_PLAIN_ENDPOINTS="
PRODUCT_STATUS_XML|/DevMgmt/ProductStatusDyn.xml|
PRODUCT_LOGS_XML|/DevMgmt/ProductLogsDyn.xml|
PRODUCT_USAGE_XML|/DevMgmt/ProductUsageDyn.xml|
CONSUMABLE_XML|/DevMgmt/ConsumableConfigDyn.xml|
EPRINT_CONFIG_XML|/ePrint/ePrintConfigDyn.xml|
CONSUMABLE_SUBSCRIPTION_INFO_XML|/ConsumableSubscription/Info|
HP_JOB_LIST_XML|/Jobs/JobList|
"

HP_REPORT_ENDPOINTS="
DISCOVERY_XML|/DevMgmt/DiscoveryTree.xml|20-discovery-tree.xml
PRODUCT_STATUS_XML|/DevMgmt/ProductStatusDyn.xml|21-product-status.xml
PRODUCT_LOGS_XML|/DevMgmt/ProductLogsDyn.xml|22-product-logs.xml
PRODUCT_USAGE_XML|/DevMgmt/ProductUsageDyn.xml|23-product-usage.xml
CONSUMABLE_XML|/DevMgmt/ConsumableConfigDyn.xml|24-consumable-config.xml
PRODUCT_CONFIG_XML|/DevMgmt/ProductConfigDyn.xml|25-product-config.xml
NETAPPS_DYN_XML|/DevMgmt/NetAppsDyn.xml|26-netapps-dyn.xml
SECURITY_DYN_XML|/DevMgmt/SecurityDyn.xml|27-security-dyn.xml
FIRMWARE_UPDATE_DYN_XML|/FirmwareUpdate/FirmwareUpdateDyn.xml|40-firmware-update-dyn.xml
FIRMWARE_UPDATE_STATE_XML|/FirmwareUpdate/WebFWUpdate/State|41-firmware-update-state.xml
FIRMWARE_UPDATE_CONFIG_XML|/FirmwareUpdate/WebFWUpdate/Config|42-firmware-update-config.xml
EPRINT_CONFIG_XML|/ePrint/ePrintConfigDyn.xml|43-eprint-config.xml
EPRINT_CLAIM_STATUS_XML|/ePrint/ClaimStatus|44-eprint-claim-status.xml
EPRINT_CONNECTION_REASON_XML|/ePrint/ConnectionStateReason|45-eprint-connection-state-reason.xml
CONSUMABLE_SUBSCRIPTION_INFO_XML|/ConsumableSubscription/Info|45a-consumable-subscription-info.xml
EVENT_TABLE_XML|/EventMgmt/EventTable|46-event-table.xml
HP_JOB_LIST_XML|/Jobs/JobList|47-jobs-joblist.xml
"

# VARIABLE|source variable|extractor|tag
HP_FIELDS="
STATUS_CATEGORY|PRODUCT_STATUS_XML|extract_tag_value|pscat:StatusCategory
STATUS_STRING_ID|PRODUCT_STATUS_XML|extract_tag_value|locid:StringId
STATUS_MODIFICATION_NUMBER|PRODUCT_STATUS_XML|extract_tag_value|dd:ModificationNumber
TOTAL_IMPRESSIONS|PRODUCT_USAGE_XML|extract_first_element_value|dd:TotalImpressions
DUPLEX_SHEETS|PRODUCT_USAGE_XML|extract_first_element_value|dd:DuplexSheets
JAM_EVENTS|PRODUCT_USAGE_XML|extract_first_element_value|dd:JamEvents
MISPICK_EVENTS|PRODUCT_USAGE_XML|extract_first_element_value|dd:MispickEvents
WIRELESS_IMPRESSIONS|PRODUCT_USAGE_XML|extract_first_element_value|dd:WirelessNetworkImpressions
SUBSCRIPTION_LEVEL|CONSUMABLE_XML|extract_tag_value|ccdyn:MarkingAgentSubscriptionLevel
FIRMWARE_REVISION|PRODUCT_CONFIG_XML|extract_product_information_value|dd:Revision
FIRMWARE_DATE|PRODUCT_CONFIG_XML|extract_product_information_value|dd:Date
SERVICE_ID|PRODUCT_CONFIG_XML|extract_tag_value|dd:ServiceID
DEVICE_TIMESTAMP|PRODUCT_CONFIG_XML|extract_tag_value|dd:TimeStamp
POWER_SAVE_MODE|PRODUCT_CONFIG_XML|extract_tag_value|dd:PowerSave
DNS_SD_DOMAIN|NETAPPS_DYN_XML|extract_tag_value|dd3:DomainName
PROXY_URI|NETAPPS_DYN_XML|extract_first_element_value|dd:ResourceURI
PROXY_PORT|NETAPPS_DYN_XML|extract_tag_value|dd:Port
FAILSAFE_STATE|SECURITY_DYN_XML|extract_tag_value|security:State
FW_AUTO_CHECK|FIRMWARE_UPDATE_CONFIG_XML|extract_tag_value|fwudyn:AutomaticCheck
FW_AUTO_UPDATE|FIRMWARE_UPDATE_CONFIG_XML|extract_tag_value|fwudyn:AutomaticUpdate
FW_STATUS|FIRMWARE_UPDATE_STATE_XML|extract_tag_value|fwudyn:Status
EPRINT_EMAIL_SERVICE|EPRINT_CONFIG_XML|extract_tag_value|ep:EmailService
EPRINT_SIP_SERVICE|EPRINT_CONFIG_XML|extract_tag_value|ep:SipService
EPRINT_MOBILE_APPS_SERVICE|EPRINT_CONFIG_XML|extract_tag_value|ep:MobileAppsService
EPRINT_REGISTRATION_STATE|EPRINT_CONFIG_XML|extract_tag_value|ep:RegistrationState
EPRINT_XMPP_STATE|EPRINT_CONFIG_XML|extract_tag_value|ep:XMPPConnectionState
EPRINT_SIGNALING_STATE|EPRINT_CONFIG_XML|extract_tag_value|ep:SignalingConnectionState
EPRINT_CLAIM_STATE|EPRINT_CLAIM_STATUS_XML|extract_tag_value|ep:Status
CONSUMABLE_SUBSCRIPTION_STATUS|CONSUMABLE_SUBSCRIPTION_INFO_XML|extract_tag_value|cs:Status
CONSUMABLE_SUBSCRIPTION_LAST_RECEIVED|CONSUMABLE_SUBSCRIPTION_INFO_XML|extract_tag_value|cs:ReceivedDate
CONSUMABLE_SUBSCRIPTION_LAST_CONNECTED|CONSUMABLE_SUBSCRIPTION_INFO_XML|extract_tag_value|cs:ConnectionDate
"

IPP_FIELDS="
IPP_STATE|printer-state
IPP_STATE_REASONS|printer-state-reasons
IPP_ACCEPTING|printer-is-accepting-jobs
IPP_QUEUED|queued-job-count
IPP_UPTIME|printer-up-time
IPP_ALERT|printer-alert
IPP_ALERT_DESCRIPTION|printer-alert-description
IPP_MARKER_NAMES|marker-names
IPP_MARKER_LEVELS|marker-levels
"

usage() {
  if [ "$COMMAND" = "repair" ]; then
    cat <<'EOF'
Usage:
  ./repair.sh --execute [options]
  ./repair.sh --fix [options]
  ./repair.sh --help

Description:
  Run the inspection flow plus the full repair recipe.

Shared options:
  --queue NAME          CUPS queue name to inspect.
  --host HOST           Printer hostname or IPv4 address.
  --community STRING    SNMP community string. Default: public
  --save-raw            Save raw responses into a timestamped directory.
  --output-dir DIR      Directory for raw responses. Implies --save-raw.
  --timeout SECONDS     Timeout used for dns-sd lookups. Default: 4
  --monitor-printing    Sample queue + printer state repeatedly during a job.
  --interval SECONDS    Monitor sample interval. Default: 3
  --samples COUNT       Maximum monitor samples. Default: 20

Repair recipe:
  --execute, --fix      Run the full best-effort repair recipe.
                        The full recipe may clear stuck jobs, send a soft PJL
                        reset, or disable HP web services as needed for the
                        detected fault.

Other:
  -h, --help            Show this help text.
  --plain               Emit a stable machine-readable summary and skip prose.

Examples:
  ./repair.sh --execute --host 192.0.2.25 --save-raw
  ./repair.sh --fix --host 192.0.2.25 --plain
EOF
  else
    cat <<'EOF'
Usage:
  ./diagnostics.sh [options]
  ./diagnostics.sh diagnose [options]

Description:
  Read-only printer, queue, and service inspection.

Shared options:
  --queue NAME          CUPS queue name to inspect.
  --host HOST           Printer hostname or IPv4 address.
  --community STRING    SNMP community string. Default: public
  --save-raw            Save raw responses into a timestamped directory.
  --output-dir DIR      Directory for raw responses. Implies --save-raw.
  --timeout SECONDS     Timeout used for dns-sd lookups. Default: 4
  --monitor-printing    Sample queue + printer state repeatedly during a job.
  --interval SECONDS    Monitor sample interval. Default: 3
  --samples COUNT       Maximum monitor samples. Default: 20

Other:
  -h, --help            Show this help text.
  --plain               Emit a stable machine-readable summary and skip prose.

Examples:
  ./diagnostics.sh --queue HP_Test_Series__ABC123_ --save-raw
  ./diagnostics.sh --host 192.0.2.25 --output-dir ./diagnostics-output
  ./diagnostics.sh --monitor-printing --interval 3 --samples 20 --save-raw
EOF
  fi
}

note() {
  printf '%s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

section() {
  printf '\n== %s ==\n' "$1"
}

# Print "label:" and the body when BODY is non-empty, else "label: EMPTY_TEXT".
note_block() {
  local label="$1"
  local body="$2"
  local empty_text="$3"

  if [ -n "$body" ]; then
    note "$label:"
    printf '%s\n' "$body"
  else
    note "$label: $empty_text"
  fi
}

now_stamp() {
  date '+%Y-%m-%d %H:%M:%S %Z'
}

# ---- transport ----

send_soft_reset_pjl() {
  local target_host="$1"

  have nc || die "nc is required for the repair recipe"
  printf '\033%%-12345X@PJL\r\n@PJL RESET\r\n\033%%-12345X' | nc -w 2 "$target_host" 9100
}

http_put_xml() {
  local url="$1"
  local payload="$2"
  local response_file="$3"

  curl -sS -o "$response_file" -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: text/xml' \
    --data-binary "$payload" \
    "$url"
}

send_hp_job_cancel_put() {
  local target_host="$1"
  local job_url="$2"
  local response_file="$3"

  http_put_xml "http://$target_host$job_url" '<?xml version="1.0" encoding="UTF-8"?>
<j:Job xmlns:j="http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30">
  <j:JobState>Canceled</j:JobState>
</j:Job>' "$response_file"
}

send_eprint_disable_put() {
  local target_host="$1"
  local response_file="$2"

  http_put_xml "http://$target_host/ePrint/ePrintConfigDyn.xml" '<?xml version="1.0" encoding="UTF-8"?>
<ep:ePrintConfigDyn xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:ep="http://www.hp.com/schemas/imaging/con/eprint/2010/04/30" xsi:schemaLocation="http://www.hp.com/schemas/imaging/con/eprint/2010/04/30 ../../schemas/ePrintConfigDyn.xsd">
  <dd:Version>
    <dd:Revision>SVN-IPG-LEDM.533</dd:Revision>
    <dd:Date>2012-08-29</dd:Date>
  </dd:Version>
  <ep:CloudConfiguration>
    <ep:EmailService>disabled</ep:EmailService>
    <ep:SipService>disabled</ep:SipService>
    <ep:MobileAppsService>disabled</ep:MobileAppsService>
  </ep:CloudConfiguration>
  <ep:RegistrationState>unregistered</ep:RegistrationState>
  <ep:XMPPConnectionState>disconnected</ep:XMPPConnectionState>
  <ep:BeaconState>disabled</ep:BeaconState>
</ep:ePrintConfigDyn>' "$response_file"
}

# Run a PUT sender with a temp response file; prints "http_code<TAB>body".
put_with_response() {
  local response_file http_code body

  response_file="$(mktemp)"
  register_temp_file "$response_file"
  http_code="$("$@" "$response_file" 2>&1 || true)"
  body="$(cat "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"
  printf '%s\t%s' "$http_code" "$body"
}

save_raw() {
  local name="$1"
  local content="$2"

  if [ "$SAVE_RAW" -ne 1 ]; then
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  printf '%s\n' "$content" >"$OUTPUT_DIR/$name"
}

fetch_url() {
  local path="$1"

  if [ -z "${ENDPOINT_HOST:-}" ]; then
    return 1
  fi

  curl -sS --max-time 10 "http://$ENDPOINT_HOST$path" 2>/dev/null
}

# Fetch each VARIABLE|path|raw-name row into VARIABLE, saving raw captures.
fetch_endpoints() {
  local var path raw_name

  while IFS='|' read -r var path raw_name; do
    [ -n "$var" ] || continue
    printf -v "$var" '%s' "$(fetch_url "$path" || true)"
    if [ -n "$ENDPOINT_HOST" ] && [ -n "$raw_name" ]; then
      save_raw "$raw_name" "${!var}"
    fi
  done <<EOF
$1
EOF
}

clear_endpoint_variables() {
  local var _rest

  while IFS='|' read -r var _rest; do
    [ -z "$var" ] || printf -v "$var" '%s' ""
  done <<EOF
$1
EOF
}

# ---- parsing ----

extract_tag_value() {
  local xml="$1"
  local tag="$2"

  printf '%s\n' "$xml" \
    | sed -n "s|.*<$tag>\\([^<]*\\)</$tag>.*|\\1|p" \
    | head -n 1
}

extract_first_element_value() {
  local xml="$1"
  local tag="$2"

  printf '%s\n' "$xml" | awk -v t="$tag" '
    $0 ~ "<" t "([[:space:]][^>]*)?>" {
      line = $0
      sub(".*<" t "([[:space:]][^>]*)?>", "", line)
      sub("</" t ">.*", "", line)
      print line
      exit
    }
  '
}

extract_block_tag_value() {
  local xml="$1"
  local start_tag="$2"
  local end_tag="$3"
  local target_tag="$4"

  printf '%s\n' "$xml" | awk -v start="$start_tag" -v end="$end_tag" -v tag="$target_tag" '
    index($0, "<" start ">") { in_block = 1 }
    in_block && $0 ~ "<" tag "([[:space:]][^>]*)?>" {
      line = $0
      sub(".*<" tag "([[:space:]][^>]*)?>", "", line)
      sub("</" tag ">.*", "", line)
      print line
      exit
    }
    index($0, "</" end ">") { in_block = 0 }
  '
}

extract_product_information_value() {
  extract_block_tag_value "$1" "prdcfgdyn:ProductInformation" "prdcfgdyn:ProductInformation" "$2"
}

# Apply each VARIABLE|source|extractor|tag row.
extract_fields() {
  local var source extractor tag

  while IFS='|' read -r var source extractor tag; do
    [ -n "$var" ] || continue
    printf -v "$var" '%s' "$("$extractor" "${!source}" "$tag")"
  done <<EOF
$1
EOF
}

extract_ipp_fields() {
  local raw="$1"
  local var key

  while IFS='|' read -r var key; do
    [ -n "$var" ] || continue
    printf -v "$var" '%s' "$(extract_ipptool_value "$raw" "$key")"
  done <<EOF
$IPP_FIELDS
EOF
}

# Print CUPS log (mode=log) or lpstat job (mode=jobs) lines that are
# newer (when=recent) or older (when=older) than HOURS.
filter_lines_by_age() {
  local mode="$1"
  local when="$2"
  local hours="$3"
  local lines="$4"

  FILTER_MODE="$mode" FILTER_WHEN="$when" FILTER_HOURS="$hours" perl -MTime::Piece -e '
    use strict;
    use warnings;

    my %formats = (
      log  => [qr/^[EW] \[(\d{2}\/[A-Z][a-z]{2}\/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]/, "%d/%b/%Y:%H:%M:%S %z"],
      jobs => [qr/^\S+\s+\S+\s+\d+\s+([A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})$/, "%a %b %d %H:%M:%S %Y"],
    );
    my ($pattern, $format) = @{ $formats{$ENV{FILTER_MODE}} };
    my $limit = ($ENV{FILTER_HOURS} || 24) * 3600;
    my $want_recent = $ENV{FILTER_WHEN} eq "recent";
    my $now = time;

    while (my $line = <STDIN>) {
      chomp $line;
      next unless $line =~ $pattern;
      my $ts = eval { Time::Piece->strptime($1, $format)->epoch };
      next if !defined $ts;
      my $is_recent = ($now - $ts) <= $limit;
      print "$line\n" if $is_recent == $want_recent;
    }
  ' <<EOF
$lines
EOF
}

extract_product_error_log() {
  local xml="$1"

  printf '%s\n' "$xml" | perl -0ne '
    while (/<pldyn:ErrorLog\b[^>]*>(.*?)<\/pldyn:ErrorLog>/sg) {
      my $block = $1;
      $block =~ s/&amp;/&/g;
      $block =~ s/&lt;/</g;
      $block =~ s/&gt;/>/g;
      $block =~ s/&quot;/"/g;
      $block =~ s/^\s+|\s+$//g;
      for my $line (split /\r?\n/, $block) {
        $line =~ s/^\s+|\s+$//g;
        print "$line\n" if length $line;
      }
    }
  '
}

extract_jobs_summary() {
  local raw="$1"

  printf '%s\n' "$raw" | awk '
    /job-id \(integer\) = / {
      sub(/.*= /, "")
      job_id = $0
    }
    /job-name \(/ {
      sub(/.*= /, "")
      job_name = $0
    }
    /job-state \(enum\) = / {
      sub(/.*= /, "")
      job_state = $0
    }
    /job-state-reasons/ {
      sub(/.*= /, "")
      job_reasons = $0
    }
    /job-impressions-completed \(integer\) = / {
      sub(/.*= /, "")
      impressions_completed = $0
    }
    /job-impressions \(integer\) = / {
      sub(/.*= /, "")
      impressions_total = $0
      if (job_id != "") {
        printf "job-id=%s job-name=%s job-state=%s reasons=%s impressions=%s/%s\n", job_id, job_name, job_state, job_reasons, impressions_completed, impressions_total
        job_id = ""
        job_name = ""
        job_state = ""
        job_reasons = ""
        impressions_completed = ""
        impressions_total = ""
      }
    }
  '
}

count_matching_lines() {
  local text="$1"
  local pattern="$2"

  printf '%s\n' "$text" | awk -v re="$pattern" '$0 ~ re { count++ } END { print count + 0 }'
}

extract_processing_hp_job_urls() {
  extract_hp_job_list_summary "$1" \
    | awk '/ state=Processing / { sub(/^job-url=/, ""); sub(/ .*/, ""); print }'
}

extract_hp_job_list_summary() {
  local xml="$1"

  printf '%s\n' "$xml" | awk '
    function value(tag,   line) {
      line = $0
      sub(".*<" tag ">", "", line)
      sub("<.*", "", line)
      return line
    }
    /<j:Job>/ { url = ""; category = ""; state = ""; update = "" }
    /<j:JobUrl>/ { url = value("j:JobUrl") }
    /<j:JobCategory>/ { category = value("j:JobCategory") }
    /<j:JobState>/ { state = value("j:JobState") }
    /<j:JobStateUpdate>/ { update = value("j:JobStateUpdate") }
    /<\/j:Job>/ {
      if (url != "") {
        printf "job-url=%s category=%s state=%s update=%s\n", url, category, state, update
      }
    }
  '
}

extract_event_table_summary() {
  local xml="$1"

  printf '%s\n' "$xml" | awk '
    /<ev:Event>/ {
      category = ""
      stamp = ""
    }
    /<dd:UnqualifiedEventCategory>/ {
      sub(/.*<dd:UnqualifiedEventCategory>/, "")
      sub(/<.*/, "")
      category = $0
    }
    /<dd:AgingStamp>/ {
      sub(/.*<dd:AgingStamp>/, "")
      sub(/<.*/, "")
      stamp = $0
    }
    /<\/ev:Event>/ {
      if (category != "") {
        printf "event=%s aging-stamp=%s\n", category, stamp
      }
    }
  '
}

extract_discovery_endpoints() {
  printf '%s\n' "$1" | awk '
    /<dd:ResourceURI>/ {
      line = $0
      sub(/.*<dd:ResourceURI>/, "", line)
      sub(/<\/dd:ResourceURI>.*/, "", line)
      print line
    }
  ' | grep '^/DevMgmt/' || true
}

extract_product_log_events() {
  printf '%s\n' "$1" | awk '
    /<pldyn:Event>/ {
      seq = ""
      occ = ""
      code = ""
    }
    /<dd:SequenceNumber>/ {
      sub(/.*<dd:SequenceNumber>/, "")
      sub(/<.*/, "")
      seq = $0
    }
    /<dd:EventOccurrences>/ {
      sub(/.*<dd:EventOccurrences>/, "")
      sub(/<.*/, "")
      occ = $0
    }
    /<dd:EventCode>/ {
      sub(/.*<dd:EventCode>/, "")
      sub(/<.*/, "")
      code = $0
    }
    /<\/pldyn:Event>/ {
      if (code != "") {
        printf "event-code=%s sequence=%s occurrences=%s\n", code, seq, occ
      }
    }
  '
}

extract_consumable_summary() {
  printf '%s\n' "$1" | awk '
    /<ccdyn:ConsumableInfo>/ {
      label = ""
      pct = ""
      measured = ""
      state = ""
    }
    /<dd:ConsumableLabelCode>/ {
      sub(/.*<dd:ConsumableLabelCode>/, "")
      sub(/<.*/, "")
      label = $0
    }
    /<dd:ConsumablePercentageLevelRemaining>/ {
      sub(/.*<dd:ConsumablePercentageLevelRemaining>/, "")
      sub(/<.*/, "")
      pct = $0
    }
    /<dd:MeasuredQuantityState>/ {
      sub(/.*<dd:MeasuredQuantityState>/, "")
      sub(/<.*/, "")
      measured = $0
    }
    /<dd:ConsumableState>/ {
      sub(/.*<dd:ConsumableState>/, "")
      sub(/<.*/, "")
      state = $0
    }
    /<\/ccdyn:ConsumableInfo>/ {
      if (label != "") {
        printf "%s: %s%% (%s, %s)\n", label, pct, state, measured
      }
    }
  '
}

extract_snmp_supplies_summary() {
  printf '%s\n' "$1" | awk -F' = ' '
    /43\.11\.1\.1\.6\.1\./ {
      idx = $1
      sub(/.*43\.11\.1\.1\.6\.1\./, "", idx)
      name = $2
      sub(/^STRING: /, "", name)
      gsub(/"/, "", name)
      names[idx] = name
    }
    /43\.11\.1\.1\.9\.1\./ {
      idx = $1
      sub(/.*43\.11\.1\.1\.9\.1\./, "", idx)
      level = $2
      sub(/^INTEGER: /, "", level)
      levels[idx] = level
    }
    END {
      for (i = 1; i <= 16; i++) {
        if (names[i] != "") {
          printf "%s: %s%%\n", names[i], levels[i]
        }
      }
    }
  '
}

first_line() {
  printf '%s\n' "$1" | head -n 1
}

# First line of lpstat -l output with tabs and runs of spaces collapsed.
queue_status_line() {
  printf '%s\n' "$1" | head -n 1 | tr '\t' ' ' | sed 's/  */ /g'
}

# ---- argument parsing ----

set_parse_error() {
  PARSE_ERROR="${PARSE_ERROR:-$1}"
}

set_value_option() {
  case "$1" in
    --queue) QUEUE="$2" ;;
    --host) HOST="$2" ;;
    --community) COMMUNITY="$2" ;;
    --output-dir) OUTPUT_DIR="$2"; SAVE_RAW=1 ;;
    --timeout) TIMEOUT_SECONDS="$2" ;;
    --interval) MONITOR_INTERVAL="$2" ;;
    --samples) MONITOR_SAMPLES="$2" ;;
  esac
}

handle_subcommand() {
  case "$1:$COMMAND" in
    diagnose:diagnose) ;;
    repair:diagnose) set_parse_error "repair actions are available in repair.sh" ;;
    *) set_parse_error "repair.sh does not take a subcommand" ;;
  esac
}

handle_repair_flag() {
  if [ "$COMMAND" = "repair" ]; then
    SEND_SOFT_RESET_PJL=1
    EXPERIMENTAL_CLEAR_JOBS=1
    CANCEL_CONNECTING=1
    REPAIR_ACTION_SELECTED=1
  else
    set_parse_error "repair actions are available in repair.sh"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      diagnose|repair) handle_subcommand "$1" ;;
      --queue|--host|--community|--output-dir|--timeout|--interval|--samples)
        if [ "$#" -lt 2 ]; then
          set_parse_error "$1 requires a value"
        else
          set_value_option "$1" "$2"
          shift
        fi
        ;;
      --save-raw) SAVE_RAW=1 ;;
      --monitor-printing) MONITOR_PRINTING=1 ;;
      --plain) PLAIN_OUTPUT=1 ;;
      --execute|--fix) handle_repair_flag ;;
      -h|--help) HELP_REQUESTED=1 ;;
      *) set_parse_error "Unknown option: $1" ;;
    esac
    shift
  done
}

exit_early_for_help_or_errors() {
  if [ "$HELP_REQUESTED" -eq 1 ]; then
    usage
    exit 0
  fi

  [ -z "$PARSE_ERROR" ] || usage_error "$PARSE_ERROR"

  if [ "$COMMAND" = "repair" ] && [ "$REPAIR_ACTION_SELECTED" -eq 0 ]; then
    usage
    exit 0
  fi
}

# ---- discovery ----

collect_cups_state() {
  CUPS_OVERVIEW="$(lpstat -p -d -v 2>/dev/null || true)"
  QUEUE_DETAIL="$(lpstat -l -p "$QUEUE" 2>/dev/null || true)"
  ALL_JOBS="$(lpstat -W all -o "$QUEUE" 2>/dev/null || true)"
  RECENT_JOBS="$(filter_lines_by_age jobs recent 24 "$ALL_JOBS")"
  OLDER_JOBS="$(filter_lines_by_age jobs older 24 "$ALL_JOBS" | tail -n 10)"

  save_raw "01-cups-overview.txt" "$CUPS_OVERVIEW"
  save_raw "02-queue-detail.txt" "$QUEUE_DETAIL"
  save_raw "03-recent-jobs.txt" "$RECENT_JOBS"
  save_raw "03-all-jobs.txt" "$ALL_JOBS"

  PRINTER_DESCRIPTION="$(printf '%s\n' "$QUEUE_DETAIL" | sed -n 's/^[[:space:]]*Description: //p' | head -n 1)"
  DEVICE_URI="$(device_uri_for_queue "$CUPS_OVERVIEW" "$QUEUE")"
  SERVICE_NAME="$(bonjour_service_name "$DEVICE_URI")"
  QUEUE_STATUS_LINE="$(queue_status_line "$QUEUE_DETAIL")"
}

resolve_printer_host() {
  local lookup resolve

  if [ -z "$HOST" ] && [ -n "$SERVICE_NAME" ] && have dns-sd; then
    lookup="$(dnssd_lookup_service "$TIMEOUT_SECONDS" "$SERVICE_NAME")"
    HOST="$(host_from_dnssd_lookup "$lookup")"
    save_raw "04-dnssd-lookup.txt" "$lookup"
  fi

  [ -n "$HOST" ] || HOST="$(host_from_ipp_uri "$DEVICE_URI")"

  if [ -n "$HOST" ] && have dns-sd; then
    resolve="$(run_for_seconds "$TIMEOUT_SECONDS" dns-sd -G v4v6 "$HOST")"
    RESOLVED_IP="$(first_ipv4 "$resolve")"
    save_raw "05-dnssd-resolve.txt" "$resolve"
  fi

  if [ -z "$RESOLVED_IP" ] && is_ipv4 "$HOST"; then
    RESOLVED_IP="$HOST"
  fi

  ENDPOINT_HOST="${RESOLVED_IP:-$HOST}"
}

require_endpoint_host() {
  [ -n "$ENDPOINT_HOST" ] || die "the repair recipe requires a resolved printer host"
}

# ---- repair recipe ----

run_soft_reset() {
  local result

  require_endpoint_host
  RESET_TIMESTAMP="$(now_stamp)"
  result="$(send_soft_reset_pjl "$ENDPOINT_HOST" 2>&1 || true)"
  save_raw "07-soft-reset-pjl.txt" "timestamp=$RESET_TIMESTAMP
target=$ENDPOINT_HOST
$result"
}

fetch_cancel_connecting_snapshot() {
  local phase="$1"

  fetch_endpoints "
CANCEL_CONNECTING_${phase}_CONFIG_XML|/ePrint/ePrintConfigDyn.xml|
CANCEL_CONNECTING_${phase}_STATUS_XML|/DevMgmt/ProductStatusDyn.xml|
CANCEL_CONNECTING_${phase}_SUBSCRIPTION_XML|/ConsumableSubscription/Info|
"
}

run_cancel_connecting() {
  local put_result response

  require_endpoint_host
  CANCEL_CONNECTING_TIMESTAMP="$(now_stamp)"
  fetch_cancel_connecting_snapshot PRE

  put_result="$(put_with_response send_eprint_disable_put "$ENDPOINT_HOST")"
  CANCEL_CONNECTING_HTTP_CODE="${put_result%%$'\t'*}"
  response="${put_result#*$'\t'}"

  sleep 3
  fetch_cancel_connecting_snapshot POST

  save_raw "52-cancel-connecting-pre-eprint-config.xml" "$CANCEL_CONNECTING_PRE_CONFIG_XML"
  save_raw "53-cancel-connecting-pre-product-status.xml" "$CANCEL_CONNECTING_PRE_STATUS_XML"
  save_raw "54-cancel-connecting-pre-subscription.xml" "$CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML"
  save_raw "55-cancel-connecting-http-response.txt" "timestamp=$CANCEL_CONNECTING_TIMESTAMP
target=$ENDPOINT_HOST
http_code=$CANCEL_CONNECTING_HTTP_CODE
$response"
  save_raw "56-cancel-connecting-post-eprint-config.xml" "$CANCEL_CONNECTING_POST_CONFIG_XML"
  save_raw "57-cancel-connecting-post-product-status.xml" "$CANCEL_CONNECTING_POST_STATUS_XML"
  save_raw "58-cancel-connecting-post-subscription.xml" "$CANCEL_CONNECTING_POST_SUBSCRIPTION_XML"
}

refresh_post_action_state() {
  sleep 2
  POST_ACTION_JOB_LIST_XML="$(fetch_url "/Jobs/JobList" || true)"
  POST_ACTION_STATUS_XML="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
  POST_ACTION_IPP_RAW="$(ipp_query "$ENDPOINT_HOST" get-printer-attributes)"
  POST_ACTION_JOB_LIST_SUMMARY="$(extract_hp_job_list_summary "$POST_ACTION_JOB_LIST_XML")"
  POST_ACTION_STATUS_CATEGORY="$(extract_tag_value "$POST_ACTION_STATUS_XML" "pscat:StatusCategory")"
  POST_ACTION_IPP_STATE="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "printer-state")"
  POST_ACTION_IPP_REASONS="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "printer-state-reasons")"
  POST_ACTION_IPP_QUEUED="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "queued-job-count")"
}

cancel_processing_jobs() {
  local job_urls="$1"
  local job_url put_result

  while IFS= read -r job_url; do
    [ -n "$job_url" ] || continue
    put_result="$(put_with_response send_hp_job_cancel_put "$ENDPOINT_HOST" "$job_url")"
    EXPERIMENTAL_ACTION_LOG="${EXPERIMENTAL_ACTION_LOG}PUT ${job_url} -> ${put_result%%$'\t'*}\n${put_result#*$'\t'}\n"
  done <<EOF
$job_urls
EOF
}

run_clear_jobs() {
  local job_urls soft_reset_output

  require_endpoint_host
  job_urls="$(extract_processing_hp_job_urls "$(fetch_url "/Jobs/JobList" || true)")"

  if [ -z "$job_urls" ]; then
    EXPERIMENTAL_ACTION_LOG="No processing printer-side jobs found in /Jobs/JobList.\n"
  else
    EXPERIMENTAL_ACTION_LOG="Found processing jobs:\n${job_urls}\n"
    cancel_processing_jobs "$job_urls"
    refresh_post_action_state

    if printf '%s\n' "$POST_ACTION_JOB_LIST_SUMMARY" | grep -q ' state=Processing'; then
      soft_reset_output="$(send_soft_reset_pjl "$ENDPOINT_HOST" 2>&1 || true)"
      EXPERIMENTAL_ACTION_LOG="${EXPERIMENTAL_ACTION_LOG}Fallback soft PJL reset sent\n${soft_reset_output}\n"
      refresh_post_action_state
    fi
  fi

  save_raw "48-experimental-clear-jobs.txt" "$EXPERIMENTAL_ACTION_LOG"
  save_raw "49-post-action-jobs-joblist.xml" "$POST_ACTION_JOB_LIST_XML"
  save_raw "50-post-action-product-status.xml" "$POST_ACTION_STATUS_XML"
  save_raw "51-post-action-ipp-attributes.txt" "$POST_ACTION_IPP_RAW"
}

run_repair_recipe() {
  [ "$SEND_SOFT_RESET_PJL" -eq 0 ] || run_soft_reset
  [ "$CANCEL_CONNECTING" -eq 0 ] || run_cancel_connecting
  [ "$EXPERIMENTAL_CLEAR_JOBS" -eq 0 ] || run_clear_jobs
}

# ---- collection ----

can_query_ipp() {
  [ -n "$ENDPOINT_HOST" ] && have ipptool
}

collect_ipp_jobs() {
  IPP_JOBS_RAW=""
  if can_query_ipp; then
    IPP_JOBS_RAW="$(ipp_query "$ENDPOINT_HOST" get-jobs)"
  fi
  IPP_JOBS_SUMMARY="$(extract_jobs_summary "$IPP_JOBS_RAW")"
  IPP_PROCESSING_JOB_COUNT="$(count_matching_lines "$IPP_JOBS_SUMMARY" "job-state=processing")"
}

collect_ipp_state() {
  IPP_RAW=""
  if can_query_ipp; then
    IPP_RAW="$(ipp_query "$ENDPOINT_HOST" get-printer-attributes)"
  fi
  collect_ipp_jobs
  if can_query_ipp; then
    save_raw "10-ipp-attributes.txt" "$IPP_RAW"
    save_raw "11-ipp-jobs.txt" "$IPP_JOBS_RAW"
  fi
  extract_ipp_fields "$IPP_RAW"
}

# Derive every HP field from whichever *_XML variables are populated.
parse_hp_state() {
  extract_fields "$HP_FIELDS"
  DISCOVERY_ENDPOINTS="$(extract_discovery_endpoints "${DISCOVERY_XML:-}")"
  PRODUCT_LOG_EVENTS="$(extract_product_log_events "$PRODUCT_LOGS_XML")"
  PRODUCT_ERROR_LOG="$(extract_product_error_log "$PRODUCT_LOGS_XML")"
  CONSUMABLE_SUMMARY="$(extract_consumable_summary "$CONSUMABLE_XML")"
  SUBSCRIPTION_CONSUMABLE_COUNT="$(count_matching_lines "$CONSUMABLE_XML" "<dd:IsSubscription>true</dd:IsSubscription>")"
  EPRINT_CONNECTION_REASON="$(printf '%s\n' "${EPRINT_CONNECTION_REASON_XML:-}" | tr -d '[:space:]')"
  EVENT_TABLE_SUMMARY="$(extract_event_table_summary "${EVENT_TABLE_XML:-}")"
  HP_JOB_LIST_SUMMARY="$(extract_hp_job_list_summary "$HP_JOB_LIST_XML")"
  HP_PROCESSING_JOB_COUNT="$(count_matching_lines "$HP_JOB_LIST_SUMMARY" " state=Processing( |$)")"
}

collect_hp_state() {
  fetch_endpoints "$1"
  parse_hp_state
}

collect_snmp_state() {
  SNMP_STATUS_RAW=""
  SNMP_SUPPLIES_RAW=""

  if [ -n "$RESOLVED_IP" ] && have snmpget; then
    SNMP_STATUS_RAW="$(snmpget -v1 -c "$COMMUNITY" "$RESOLVED_IP" 1.3.6.1.2.1.25.3.5.1.1.1 1.3.6.1.2.1.25.3.5.1.2.1 2>&1 || true)"
    save_raw "30-snmp-status.txt" "$SNMP_STATUS_RAW"
  fi

  if [ -n "$RESOLVED_IP" ] && have snmpwalk; then
    SNMP_SUPPLIES_RAW="$(snmpwalk -v1 -c "$COMMUNITY" "$RESOLVED_IP" 1.3.6.1.2.1.43.11.1.1 2>&1 || true)"
    save_raw "31-snmp-supplies.txt" "$SNMP_SUPPLIES_RAW"
  fi

  SNMP_SUPPLIES_SUMMARY="$(extract_snmp_supplies_summary "$SNMP_SUPPLIES_RAW")"
}

# ---- health classification ----

classify_print_engine_health() {
  if [ "$IPP_STATE_REASONS" = "spool-area-full-report" ]; then
    PRINT_ENGINE_HEALTH="stuck"
    PRINT_ENGINE_DETAIL="printer reports spool-area-full-report"
  elif [ "$HP_PROCESSING_JOB_COUNT" -gt 0 ] && [ "$IPP_PROCESSING_JOB_COUNT" -eq 0 ]; then
    PRINT_ENGINE_HEALTH="stuck"
    PRINT_ENGINE_DETAIL="internal printer job is still processing"
  elif status_is_busy; then
    PRINT_ENGINE_HEALTH="active"
    PRINT_ENGINE_DETAIL="printer status is ${STATUS_CATEGORY}"
  elif [ -n "$PRODUCT_ERROR_LOG" ]; then
    PRINT_ENGINE_HEALTH="degraded"
    PRINT_ENGINE_DETAIL="hidden HP error log is non-empty"
  elif [ -z "$STATUS_CATEGORY" ] && [ -z "${IPP_STATE:-}" ]; then
    PRINT_ENGINE_HEALTH="unknown"
    PRINT_ENGINE_DETAIL="printer status could not be observed"
  else
    PRINT_ENGINE_HEALTH="healthy"
    PRINT_ENGINE_DETAIL="printer reports ready/idle"
  fi
}

status_is_busy() {
  case "$STATUS_CATEGORY" in
    ""|ready|inPowerSave) return 1 ;;
  esac
}

eprint_services_disabled() {
  [ "$EPRINT_EMAIL_SERVICE:$EPRINT_SIP_SERVICE:$EPRINT_MOBILE_APPS_SERVICE:$EPRINT_REGISTRATION_STATE" = "disabled:disabled:disabled:unregistered" ]
}

eprint_fully_connected() {
  [ "$EPRINT_REGISTRATION_STATE:$EPRINT_XMPP_STATE:$EPRINT_SIGNALING_STATE" = "registered:connected:connected" ]
}

eprint_state_reported() {
  [ -n "$EPRINT_REGISTRATION_STATE$EPRINT_XMPP_STATE$EPRINT_SIGNALING_STATE" ]
}

classify_cloud_health() {
  if eprint_services_disabled; then
    CLOUD_HEALTH="disabled"
    CLOUD_DETAIL="HP web services are intentionally disabled"
    if [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ]; then
      CLOUD_DETAIL="$CLOUD_DETAIL while subscription cartridges remain installed"
    fi
  elif [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ] && eprint_fully_connected; then
    CLOUD_HEALTH="healthy"
    CLOUD_DETAIL="Instant Ink cloud path is fully connected"
  elif [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ]; then
    CLOUD_HEALTH="degraded"
    CLOUD_DETAIL="subscription cartridges installed, but HP cloud signaling is not fully connected"
  elif eprint_state_reported; then
    CLOUD_HEALTH="not-in-use"
    CLOUD_DETAIL="no subscription cartridges detected"
  else
    CLOUD_HEALTH="unknown"
    CLOUD_DETAIL="cloud state not available"
  fi
}

classify_mac_queue_health() {
  case "$QUEUE_STATUS_LINE" in
    *disabled*)
      MAC_QUEUE_HEALTH="degraded"
      MAC_QUEUE_DETAIL="CUPS queue is disabled"
      ;;
    *"now printing"*)
      MAC_QUEUE_HEALTH="active"
      MAC_QUEUE_DETAIL="CUPS queue currently has an active job"
      ;;
    *)
      MAC_QUEUE_HEALTH="healthy"
      MAC_QUEUE_DETAIL="CUPS queue is enabled and idle"
      ;;
  esac
}

classify_health() {
  classify_print_engine_health
  classify_cloud_health
  classify_mac_queue_health
}

# ---- plain output ----

plain_value() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'
}

plain_kv() {
  printf '%s=%s\n' "$1" "$(plain_value "$2")"
}

emit_plain_repair_actions() {
  if [ "$SEND_SOFT_RESET_PJL" -eq 1 ]; then
    plain_kv repair_action soft-reset-pjl
  fi

  if [ "$EXPERIMENTAL_CLEAR_JOBS" -eq 1 ]; then
    plain_kv repair_action experimental-clear-jobs
    plain_kv experimental_clear_jobs_post_action_status_category "${POST_ACTION_STATUS_CATEGORY:-unknown}"
    plain_kv experimental_clear_jobs_post_action_printer_state "${POST_ACTION_IPP_STATE:-unknown}"
    plain_kv experimental_clear_jobs_post_action_printer_state_reasons "${POST_ACTION_IPP_REASONS:-unknown}"
    plain_kv experimental_clear_jobs_post_action_queued_job_count "${POST_ACTION_IPP_QUEUED:-unknown}"
    if [ -n "$POST_ACTION_JOB_LIST_SUMMARY" ]; then
      plain_kv experimental_clear_jobs_post_action_joblist_summary "$POST_ACTION_JOB_LIST_SUMMARY"
    fi
  fi

  if [ "$CANCEL_CONNECTING" -eq 1 ]; then
    plain_kv repair_action cancel-connecting
    plain_kv cancel_connecting_http_code "${CANCEL_CONNECTING_HTTP_CODE:-unknown}"
    plain_kv pre_action_product_status_category "$(extract_tag_value "$CANCEL_CONNECTING_PRE_STATUS_XML" "pscat:StatusCategory")"
    plain_kv post_action_product_status_category "$(extract_tag_value "$CANCEL_CONNECTING_POST_STATUS_XML" "pscat:StatusCategory")"
    plain_kv pre_action_eprint_registration_state "$(extract_tag_value "$CANCEL_CONNECTING_PRE_CONFIG_XML" "ep:RegistrationState")"
    plain_kv post_action_eprint_registration_state "$(extract_tag_value "$CANCEL_CONNECTING_POST_CONFIG_XML" "ep:RegistrationState")"
    plain_kv pre_action_consumable_subscription_status "$(extract_tag_value "$CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML" "cs:Status")"
    plain_kv post_action_consumable_subscription_status "$(extract_tag_value "$CANCEL_CONNECTING_POST_SUBSCRIPTION_XML" "cs:Status")"
  fi
}

emit_plain_summary() {
  plain_kv command "$COMMAND"
  plain_kv queue "${QUEUE:-unknown}"
  plain_kv host "${HOST:-unknown}"
  plain_kv ipv4 "${RESOLVED_IP:-unknown}"
  plain_kv print_engine_health "$PRINT_ENGINE_HEALTH"
  plain_kv cloud_health "$CLOUD_HEALTH"
  plain_kv mac_queue_health "$MAC_QUEUE_HEALTH"
  plain_kv status_category "${STATUS_CATEGORY:-unknown}"
  plain_kv product_error_log "${PRODUCT_ERROR_LOG:-empty}"
  plain_kv mispick_events "${MISPICK_EVENTS:-unknown}"
  plain_kv eprint_registration_state "${EPRINT_REGISTRATION_STATE:-unknown}"
  plain_kv eprint_signaling_state "${EPRINT_SIGNALING_STATE:-unknown}"
  emit_plain_repair_actions
}

run_plain_report() {
  IPP_STATE_REASONS=""
  clear_endpoint_variables "$HP_REPORT_ENDPOINTS"
  collect_hp_state "$HP_PLAIN_ENDPOINTS"
  collect_ipp_jobs
  classify_health
  emit_plain_summary
}

# ---- prose report ----

report_quick_summary() {
  section "Quick Summary"
  note "Queue: ${QUEUE:-unknown}"
  note "Description: ${PRINTER_DESCRIPTION:-unknown}"
  note "Device URI: ${DEVICE_URI:-unknown}"
  note "Bonjour service: ${SERVICE_NAME:-unknown}"
  note "Host: ${HOST:-unknown}"
  note "IPv4: ${RESOLVED_IP:-unknown}"
  if [ "$SAVE_RAW" -eq 1 ]; then
    note "Raw output directory: $OUTPUT_DIR"
  fi
  if [ "$SEND_SOFT_RESET_PJL" -eq 1 ]; then
    note "Soft PJL reset sent: ${RESET_TIMESTAMP:-unknown}"
    note "Soft PJL reset target: ${ENDPOINT_HOST:-unknown}"
  fi
  if [ "$CANCEL_CONNECTING" -eq 1 ]; then
    note "Cancel connecting action sent: ${CANCEL_CONNECTING_TIMESTAMP:-unknown}"
    note "Cancel connecting target: ${ENDPOINT_HOST:-unknown}"
    note "Cancel connecting HTTP code: ${CANCEL_CONNECTING_HTTP_CODE:-unknown}"
  fi
}

report_cups_jobs() {
  section "CUPS"
  printf '%s\n' "$CUPS_OVERVIEW"
  printf '\n'
  printf '%s\n' "$QUEUE_DETAIL"
  printf '\n'
  note_block "Recent jobs (last 24 hours)" "$RECENT_JOBS" "none found"

  printf '\n'
  if [ -n "$OLDER_JOBS" ]; then
    note "Older jobs (latest 10 before the last 24 hours):"
    printf '%s\n' "$OLDER_JOBS"
  fi
}

cups_error_log_path() {
  local path="${CUPS_ERROR_LOG_PATH:-}"
  local candidate

  if [ -n "$path" ]; then
    [ -r "$path" ] && { printf '%s' "$path"; return 0; }
    warn "CUPS_ERROR_LOG_PATH is set but not readable: $path"
  fi

  for candidate in /var/log/cups/error_log /private/var/log/cups/error_log; do
    [ -r "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
}

report_cups_errors() {
  local log_path all_errors="" recent_errors="" older_errors=""

  log_path="$(cups_error_log_path)"
  if [ -n "$log_path" ]; then
    all_errors="$(tail -n 200 "$log_path" 2>/dev/null | grep -E '^[EW]' || true)"
    recent_errors="$(filter_lines_by_age log recent 24 "$all_errors")"
    older_errors="$(filter_lines_by_age log older 24 "$all_errors")"
    save_raw "06-cups-errors.txt" "$recent_errors"
    save_raw "06-cups-errors-all.txt" "$all_errors"
  fi

  printf '\n'
  note_block "Recent CUPS errors/warnings (last 24 hours)" "$recent_errors" "none found"

  printf '\n'
  if [ -n "$older_errors" ]; then
    note "Older CUPS errors/warnings (before the last 24 hours):"
    printf '%s\n' "$older_errors"
  fi
}

report_ipp() {
  section "IPP"
  if [ -z "$IPP_RAW" ]; then
    warn "IPP query did not return data"
    return 0
  fi

  note "printer-state: ${IPP_STATE:-unknown}"
  note "printer-state-reasons: ${IPP_STATE_REASONS:-unknown}"
  note "printer-is-accepting-jobs: ${IPP_ACCEPTING:-unknown}"
  note "queued-job-count: ${IPP_QUEUED:-unknown}"
  note "printer-up-time (seconds): ${IPP_UPTIME:-unknown}"
  note "printer-alert-description: ${IPP_ALERT_DESCRIPTION:-unknown}"
  note "printer-alert: ${IPP_ALERT:-unknown}"
  note "marker-names: ${IPP_MARKER_NAMES:-unknown}"
  note "marker-levels: ${IPP_MARKER_LEVELS:-unknown}"
  if [ -n "$IPP_JOBS_SUMMARY" ]; then
    note "IPP jobs:"
    printf '%s\n' "$IPP_JOBS_SUMMARY"
  fi
}

report_hp_status_and_logs() {
  if [ -n "$DISCOVERY_ENDPOINTS" ]; then
    note "DiscoveryTree DevMgmt endpoints:"
    printf '%s\n' "$DISCOVERY_ENDPOINTS"
  else
    warn "DiscoveryTree.xml did not return endpoints"
  fi

  printf '\n'
  if [ -n "$STATUS_CATEGORY$STATUS_STRING_ID" ]; then
    note "ProductStatusDyn status-category: ${STATUS_CATEGORY:-unknown}"
    note "ProductStatusDyn string-id: ${STATUS_STRING_ID:-unknown}"
  else
    warn "ProductStatusDyn.xml did not return a status summary"
  fi

  printf '\n'
  note_block "ProductLogsDyn event codes" "$PRODUCT_LOG_EVENTS" "none returned"

  printf '\n'
  note_block "ProductLogsDyn hidden error log" "$PRODUCT_ERROR_LOG" "empty"
}

report_hp_usage_and_consumables() {
  printf '\n'
  if [ -n "$TOTAL_IMPRESSIONS$JAM_EVENTS$MISPICK_EVENTS" ]; then
    note "ProductUsageDyn total-impressions: ${TOTAL_IMPRESSIONS:-unknown}"
    note "ProductUsageDyn duplex-sheets: ${DUPLEX_SHEETS:-unknown}"
    note "ProductUsageDyn jam-events: ${JAM_EVENTS:-unknown}"
    note "ProductUsageDyn mispick-events: ${MISPICK_EVENTS:-unknown}"
    note "ProductUsageDyn wireless-network-impressions: ${WIRELESS_IMPRESSIONS:-unknown}"
  else
    warn "ProductUsageDyn.xml did not return usage counters"
  fi

  printf '\n'
  if [ -n "$CONSUMABLE_SUMMARY" ]; then
    note "ConsumableConfigDyn summary:"
    printf '%s\n' "$CONSUMABLE_SUMMARY"
    note "Consumable subscription-level: ${SUBSCRIPTION_LEVEL:-unknown}"
    note "Consumables marked as subscription cartridges: ${SUBSCRIPTION_CONSUMABLE_COUNT}"
  else
    warn "ConsumableConfigDyn.xml did not return consumable data"
  fi
}

report_hp_firmware() {
  section "HP Services"
  if [ -n "$FIRMWARE_REVISION$SERVICE_ID" ]; then
    note "ProductConfigDyn firmware-revision: ${FIRMWARE_REVISION:-unknown}"
    note "ProductConfigDyn firmware-date: ${FIRMWARE_DATE:-unknown}"
    note "ProductConfigDyn service-id: ${SERVICE_ID:-unknown}"
    note "ProductConfigDyn device-timestamp: ${DEVICE_TIMESTAMP:-unknown}"
    note "ProductConfigDyn power-save: ${POWER_SAVE_MODE:-unknown}"
    note "ProductStatusDyn alert-table-modification-number: ${STATUS_MODIFICATION_NUMBER:-unknown}"
  else
    warn "ProductConfigDyn.xml did not return support identifiers"
  fi

  printf '\n'
  if [ -n "$FW_STATUS$FW_AUTO_CHECK$FW_AUTO_UPDATE" ]; then
    note "FirmwareUpdate state: ${FW_STATUS:-unknown}"
    note "FirmwareUpdate automatic-check: ${FW_AUTO_CHECK:-unknown}"
    note "FirmwareUpdate automatic-update: ${FW_AUTO_UPDATE:-unknown}"
  else
    note "FirmwareUpdate endpoints did not return data"
  fi
}

report_hp_eprint() {
  printf '\n'
  if ! eprint_state_reported; then
    note "ePrint endpoints did not return connection data"
    return 0
  fi

  note "ePrint email-service: ${EPRINT_EMAIL_SERVICE:-unknown}"
  note "ePrint sip-service: ${EPRINT_SIP_SERVICE:-unknown}"
  note "ePrint mobile-apps-service: ${EPRINT_MOBILE_APPS_SERVICE:-unknown}"
  note "ePrint registration-state: ${EPRINT_REGISTRATION_STATE:-unknown}"
  note "ePrint xmpp-connection-state: ${EPRINT_XMPP_STATE:-unknown}"
  note "ePrint signaling-connection-state: ${EPRINT_SIGNALING_STATE:-unknown}"
  note "ePrint claim-status: ${EPRINT_CLAIM_STATE:-unknown}"
  note "ePrint connection-state-reason: ${EPRINT_CONNECTION_REASON:-none returned}"
}

report_hp_subscription_and_events() {
  printf '\n'
  if [ -n "$CONSUMABLE_SUBSCRIPTION_STATUS" ]; then
    note "ConsumableSubscription status: ${CONSUMABLE_SUBSCRIPTION_STATUS}"
    note "ConsumableSubscription last-received-date: ${CONSUMABLE_SUBSCRIPTION_LAST_RECEIVED:-unknown}"
    note "ConsumableSubscription last-connection-date: ${CONSUMABLE_SUBSCRIPTION_LAST_CONNECTED:-unknown}"
  else
    note "ConsumableSubscription endpoints did not return subscription data"
  fi

  printf '\n'
  note_block "EventMgmt event table" "$EVENT_TABLE_SUMMARY" "none returned"

  printf '\n'
  if [ -n "$HP_JOB_LIST_SUMMARY" ]; then
    note "Jobs/JobList summary:"
    printf '%s\n' "$HP_JOB_LIST_SUMMARY"
  fi

  printf '\n'
  if [ -n "$DNS_SD_DOMAIN$PROXY_PORT" ]; then
    note "NetApps domain-name: ${DNS_SD_DOMAIN:-unknown}"
    note "NetApps proxy-uri: ${PROXY_URI:-none}"
    note "NetApps proxy-port: ${PROXY_PORT:-0}"
    note "Security failsafe-state: ${FAILSAFE_STATE:-unknown}"
  fi
}

report_hp() {
  section "HP Embedded Web Server"
  report_hp_status_and_logs
  report_hp_usage_and_consumables
  report_hp_firmware
  report_hp_eprint
  report_hp_subscription_and_events
}

report_health_summary() {
  section "Health Summary"
  note "Print engine: ${PRINT_ENGINE_HEALTH} (${PRINT_ENGINE_DETAIL})"
  note "Cloud/Instant Ink: ${CLOUD_HEALTH} (${CLOUD_DETAIL})"
  note "Mac queue: ${MAC_QUEUE_HEALTH} (${MAC_QUEUE_DETAIL})"
}

report_snmp() {
  section "SNMP"
  if [ -n "$SNMP_STATUS_RAW" ]; then
    printf '%s\n' "$SNMP_STATUS_RAW"
  else
    note "SNMP status query: unavailable or no IPv4 address resolved"
  fi

  printf '\n'
  note_block "SNMP supply summary" "$SNMP_SUPPLIES_SUMMARY" "unavailable"
}

# True when VALUE is a number greater than LIMIT (non-numbers are false).
number_above() {
  [ -n "$1" ] && [ "$1" -gt "$2" ] 2>/dev/null
}

set_and_not() {
  [ -n "$1" ] && [ "$1" != "$2" ]
}

report_device_interpretation() {
  if [ -n "$PRODUCT_ERROR_LOG" ]; then
    note "Hidden HP errors were found in ProductLogsDyn.xml."
  fi
  if set_and_not "$IPP_STATE_REASONS" none; then
    note "IPP is reporting an active printer-state-reasons value: $IPP_STATE_REASONS"
  fi
  if set_and_not "$STATUS_CATEGORY" ready; then
    note "HP ProductStatusDyn is not reporting ready: $STATUS_CATEGORY"
  fi
  if [ -n "$IPP_UPTIME" ] && [ "$IPP_UPTIME" -lt 900 ] 2>/dev/null; then
    note "The printer uptime is only ${IPP_UPTIME}s, which suggests a recent reboot."
  fi
  if number_above "$MISPICK_EVENTS" 0; then
    note "The printer has a lifetime history of ${MISPICK_EVENTS} paper mispick events."
  fi
  if number_above "$STATUS_MODIFICATION_NUMBER" 0; then
    note "ProductStatusDyn reports alert-table changes with modification number ${STATUS_MODIFICATION_NUMBER}."
  fi
  if set_and_not "$FW_STATUS" idle; then
    note "FirmwareUpdate is not idle: ${FW_STATUS}."
  fi
}

report_cloud_interpretation() {
  if [ "$CLOUD_HEALTH" = "disabled" ]; then
    note "HP web services are intentionally disabled, so HP Connected/Instant Ink panel prompts should stay cleared."
    return 0
  fi

  if set_and_not "$EPRINT_SIGNALING_STATE" connected; then
    note "ePrint signaling is not connected: ${EPRINT_SIGNALING_STATE}."
    if [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ]; then
      note "Instant Ink subscription cartridges are installed, but HP cloud signaling is not fully connected."
    fi
  fi
}

report_job_interpretation() {
  if [ -n "$EVENT_TABLE_SUMMARY" ]; then
    note "EventMgmt shows the most recent device-side event categories above."
  fi
  if [ "$IPP_PROCESSING_JOB_COUNT" -gt 0 ] && [ "$HP_PROCESSING_JOB_COUNT" -gt 0 ] && [ "$IPP_STATE_REASONS" = "spool-area-full-report" ]; then
    note "The printer is still holding at least one print job open internally while reporting spool-area-full-report."
  fi
  if [ "$IPP_PROCESSING_JOB_COUNT" -gt 0 ] && printf '%s\n' "$QUEUE_DETAIL" | grep -q 'Finished page'; then
    note "CUPS reports a page finished, but the printer still has the job open as processing."
  fi
  if [ "$IPP_STATE_REASONS:$STATUS_CATEGORY" = "none:ready" ]; then
    note "There is no active printer-side fault being reported through CUPS, IPP, or ProductStatusDyn right now."
  fi
}

report_interpretation() {
  section "Interpretation"
  report_device_interpretation
  report_cloud_interpretation
  report_job_interpretation
  note "If print jobs still sit in 'printing' for a long time while the checks above remain healthy, the next suspects are network delivery, Bonjour name resolution, or the printer taking a long time to rasterize a specific job."
}

report_clear_jobs_action() {
  section "Experimental Actions"
  printf '%b' "$EXPERIMENTAL_ACTION_LOG"
  if [ -z "$POST_ACTION_JOB_LIST_SUMMARY$POST_ACTION_STATUS_CATEGORY$POST_ACTION_IPP_STATE" ]; then
    return 0
  fi

  note "Post-action printer-state: ${POST_ACTION_IPP_STATE:-unknown}"
  note "Post-action printer-state-reasons: ${POST_ACTION_IPP_REASONS:-unknown}"
  note "Post-action queued-job-count: ${POST_ACTION_IPP_QUEUED:-unknown}"
  note "Post-action ProductStatusDyn status-category: ${POST_ACTION_STATUS_CATEGORY:-unknown}"
  if [ -n "$POST_ACTION_JOB_LIST_SUMMARY" ]; then
    note "Post-action Jobs/JobList summary:"
    printf '%s\n' "$POST_ACTION_JOB_LIST_SUMMARY"
  fi
}

report_cancel_connecting_action() {
  section "Web Services Action"
  note "PUT /ePrint/ePrintConfigDyn.xml -> ${CANCEL_CONNECTING_HTTP_CODE:-unknown}"
  note "Pre-action ProductStatusDyn status-category: $(extract_tag_value "$CANCEL_CONNECTING_PRE_STATUS_XML" "pscat:StatusCategory")"
  note "Post-action ProductStatusDyn status-category: $(extract_tag_value "$CANCEL_CONNECTING_POST_STATUS_XML" "pscat:StatusCategory")"
  note "Pre-action ePrint registration-state: $(extract_tag_value "$CANCEL_CONNECTING_PRE_CONFIG_XML" "ep:RegistrationState")"
  note "Post-action ePrint registration-state: $(extract_tag_value "$CANCEL_CONNECTING_POST_CONFIG_XML" "ep:RegistrationState")"
  note "Pre-action ConsumableSubscription status: $(extract_tag_value "$CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML" "cs:Status")"
  note "Post-action ConsumableSubscription status: $(extract_tag_value "$CANCEL_CONNECTING_POST_SUBSCRIPTION_XML" "cs:Status")"
}

report_repair_actions() {
  [ "$EXPERIMENTAL_CLEAR_JOBS" -eq 0 ] || report_clear_jobs_action
  [ "$CANCEL_CONNECTING" -eq 0 ] || report_cancel_connecting_action
}

# ---- during-printing monitor ----

monitor_sample_dir() {
  local sample_index="$1"
  local dir

  [ "$SAVE_RAW" -eq 1 ] || return 0
  dir="$OUTPUT_DIR/monitor/$(printf '%03d' "$sample_index")-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

collect_monitor_sample() {
  SAMPLE_CUPS_STATUS="$(lpstat -l -p "$QUEUE" 2>/dev/null || true)"
  SAMPLE_ACTIVE_JOBS="$(lpstat -W not-completed -o "$QUEUE" 2>/dev/null || true)"
  SAMPLE_IPP_ATTRS=""
  SAMPLE_IPP_JOBS=""
  if can_query_ipp; then
    SAMPLE_IPP_ATTRS="$(ipp_query "$ENDPOINT_HOST" get-printer-attributes)"
    SAMPLE_IPP_JOBS="$(ipp_query "$ENDPOINT_HOST" get-jobs)"
  fi
  fetch_endpoints "
SAMPLE_HP_STATUS_XML|/DevMgmt/ProductStatusDyn.xml|
SAMPLE_HP_JOBS_XML|/Jobs/JobList|
SAMPLE_HP_LOGS_XML|/DevMgmt/ProductLogsDyn.xml|
"
}

save_monitor_sample() {
  local dir="$1"

  [ -n "$dir" ] || return 0
  printf '%s\n' "$SAMPLE_CUPS_STATUS" >"$dir/cups-status.txt"
  printf '%s\n' "$SAMPLE_ACTIVE_JOBS" >"$dir/active-jobs.txt"
  printf '%s\n' "$SAMPLE_IPP_ATTRS" >"$dir/ipp-printer-attributes.txt"
  printf '%s\n' "$SAMPLE_IPP_JOBS" >"$dir/ipp-jobs.txt"
  printf '%s\n' "$SAMPLE_HP_STATUS_XML" >"$dir/product-status.xml"
  printf '%s\n' "$SAMPLE_HP_JOBS_XML" >"$dir/jobs-joblist.xml"
  printf '%s\n' "$SAMPLE_HP_LOGS_XML" >"$dir/product-logs.xml"
}

parse_monitor_sample() {
  SAMPLE_CUPS_HEAD="$(queue_status_line "$SAMPLE_CUPS_STATUS")"
  SAMPLE_IPP_STATE="$(extract_ipptool_value "$SAMPLE_IPP_ATTRS" "printer-state")"
  SAMPLE_IPP_REASONS="$(extract_ipptool_value "$SAMPLE_IPP_ATTRS" "printer-state-reasons")"
  SAMPLE_IPP_QUEUED="$(extract_ipptool_value "$SAMPLE_IPP_ATTRS" "queued-job-count")"
  SAMPLE_IPP_JOB="$(first_line "$(extract_jobs_summary "$SAMPLE_IPP_JOBS")")"
  SAMPLE_HP_STATUS="$(extract_tag_value "$SAMPLE_HP_STATUS_XML" "pscat:StatusCategory")"
  SAMPLE_HP_JOBS_SUMMARY="$(extract_hp_job_list_summary "$SAMPLE_HP_JOBS_XML")"
  SAMPLE_HP_JOB="$(first_line "$SAMPLE_HP_JOBS_SUMMARY")"
  SAMPLE_HP_ERROR="$(first_line "$(extract_product_error_log "$SAMPLE_HP_LOGS_XML")")"
}

monitor_sample_is_active() {
  case "$SAMPLE_CUPS_HEAD" in
    *"now printing"*) return 0 ;;
  esac
  case "$SAMPLE_IPP_STATE:$SAMPLE_HP_STATUS" in
    processing:*|*:processing) return 0 ;;
  esac
  # The HP job list keeps completed jobs as history; only Processing ones are live.
  [ "$(count_matching_lines "$SAMPLE_HP_JOBS_SUMMARY" " state=Processing( |$)")" -gt 0 ] && return 0
  [ -n "$SAMPLE_ACTIVE_JOBS$SAMPLE_IPP_JOB" ] || [ "${SAMPLE_IPP_QUEUED:-0}" != "0" ]
}

print_monitor_sample() {
  local dir="$1"

  printf '[%s] cups="%s" ipp-state=%s ipp-reasons=%s queued=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    "${SAMPLE_CUPS_HEAD:-unknown}" \
    "${SAMPLE_IPP_STATE:-unknown}" \
    "${SAMPLE_IPP_REASONS:-unknown}" \
    "${SAMPLE_IPP_QUEUED:-unknown}"

  [ -z "$SAMPLE_IPP_JOB" ] || printf '  ipp-job: %s\n' "$SAMPLE_IPP_JOB"

  if [ -n "$SAMPLE_HP_STATUS$SAMPLE_HP_JOB" ]; then
    printf '  hp-status: %s\n' "${SAMPLE_HP_STATUS:-unknown}"
    [ -z "$SAMPLE_HP_JOB" ] || printf '  hp-job: %s\n' "$SAMPLE_HP_JOB"
  fi

  [ -z "$SAMPLE_HP_ERROR" ] || printf '  hp-error-first-line: %s\n' "$SAMPLE_HP_ERROR"
  [ -z "$dir" ] || printf '  raw-sample-dir: %s\n' "$dir"
}

capture_monitor_sample() {
  local dir

  dir="$(monitor_sample_dir "$1")"
  collect_monitor_sample
  save_monitor_sample "$dir"
  parse_monitor_sample

  MONITOR_LAST_ACTIVE=0
  if monitor_sample_is_active; then
    MONITOR_LAST_ACTIVE=1
  fi

  print_monitor_sample "$dir"
}

run_monitor() {
  local seen_active=0
  local sample_index=1

  section "During Printing Monitor"
  note "Sampling every ${MONITOR_INTERVAL}s for up to ${MONITOR_SAMPLES} samples."

  while [ "$sample_index" -le "$MONITOR_SAMPLES" ]; do
    capture_monitor_sample "$sample_index"

    if [ "$MONITOR_LAST_ACTIVE" -eq 1 ]; then
      seen_active=1
    elif [ "$seen_active" -eq 0 ]; then
      note "Monitor stopping because no active print job was detected on the first sample."
      break
    else
      note "Monitor stopping early because the printer returned to idle after an active print state."
      break
    fi

    if [ "$sample_index" -lt "$MONITOR_SAMPLES" ]; then
      sleep "$MONITOR_INTERVAL"
    fi

    sample_index=$((sample_index + 1))
  done
}

# ---- entrypoint ----

run_prose_report() {
  report_quick_summary
  report_cups_jobs
  report_cups_errors

  collect_ipp_state
  report_ipp

  collect_hp_state "$HP_REPORT_ENDPOINTS"
  report_hp

  classify_health
  report_health_summary

  collect_snmp_state
  report_snmp

  report_interpretation
  report_repair_actions

  if [ "$MONITOR_PRINTING" -eq 1 ]; then
    run_monitor
  fi
}

main() {
  parse_args "$@"
  exit_early_for_help_or_errors

  have lpstat || die "lpstat is required"
  have curl || die "curl is required"

  if [ "$SAVE_RAW" -eq 1 ] && [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="./diagnostics-output/$(date +%Y%m%d-%H%M%S)"
  fi

  [ -n "$QUEUE" ] || QUEUE="$(detect_default_queue)"
  [ -n "$QUEUE" ] || die "No CUPS printer queue found. Use --queue or --host."

  collect_cups_state
  resolve_printer_host
  run_repair_recipe

  if [ "$PLAIN_OUTPUT" -eq 1 ]; then
    run_plain_report
  else
    run_prose_report
  fi
}

trap cleanup_temp_files EXIT INT TERM
main "$@"
