#!/usr/bin/env bash

set -u
set -o pipefail

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

trap cleanup_temp_files EXIT INT TERM

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

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

section() {
  printf '\n== %s ==\n' "$1"
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

  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  else
    wait "$pid" 2>/dev/null || true
  fi

  cat "$tmp"
  rm -f "$tmp"
}

send_soft_reset_pjl() {
  local target_host="$1"

  have nc || die "nc is required for the repair recipe"
  printf '\033%%-12345X@PJL\r\n@PJL RESET\r\n\033%%-12345X' | nc -w 2 "$target_host" 9100
}

extract_processing_hp_job_urls() {
  local xml="$1"

  printf '%s\n' "$xml" | awk '
    /<j:Job>/ {
      url = ""
      state = ""
    }
    /<j:JobUrl>/ {
      sub(/.*<j:JobUrl>/, "")
      sub(/<.*/, "")
      url = $0
    }
    /<j:JobState>/ {
      sub(/.*<j:JobState>/, "")
      sub(/<.*/, "")
      state = $0
    }
    /<\/j:Job>/ {
      if (state == "Processing" && url != "") {
        print url
      }
    }
  '
}

send_hp_job_cancel_put() {
  local target_host="$1"
  local job_url="$2"
  local response_file="$3"
  local payload

  payload='<?xml version="1.0" encoding="UTF-8"?>
<j:Job xmlns:j="http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30">
  <j:JobState>Canceled</j:JobState>
</j:Job>'

  curl -sS -o "$response_file" -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: text/xml' \
    --data-binary "$payload" \
    "http://$target_host$job_url"
}

send_eprint_disable_put() {
  local target_host="$1"
  local response_file="$2"
  local payload

  payload='<?xml version="1.0" encoding="UTF-8"?>
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
</ep:ePrintConfigDyn>'

  curl -sS -o "$response_file" -w '%{http_code}' \
    -X PUT \
    -H 'Content-Type: text/xml' \
    --data-binary "$payload" \
    "http://$target_host/ePrint/ePrintConfigDyn.xml"
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

extract_ipptool_value() {
  local raw="$1"
  local key="$2"

  printf '%s\n' "$raw" \
    | grep -E "^[[:space:]]*$key \\(" \
    | head -n 1 \
    | sed 's/^[^=]*= //'
}

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

fetch_url() {
  local path="$1"

  if [ -z "${ENDPOINT_HOST:-}" ]; then
    return 1
  fi

  curl -sS --max-time 10 "http://$ENDPOINT_HOST$path" 2>/dev/null
}

filter_cups_log_by_age_hours() {
  local log_lines="$1"
  local max_age_hours="$2"

  MAX_AGE_HOURS="$max_age_hours" perl -MTime::Piece -e '
    use strict;
    use warnings;

    my $max_age_seconds = ($ENV{MAX_AGE_HOURS} || 24) * 3600;
    my $now = time;

    while (my $line = <STDIN>) {
      if ($line =~ /^[EW] \[(\d{2}\/[A-Z][a-z]{2}\/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]/) {
        my $ts = eval { Time::Piece->strptime($1, "%d/%b/%Y:%H:%M:%S %z")->epoch };
        next if !defined $ts;
        print $line if ($now - $ts) <= $max_age_seconds;
      }
    }
  ' <<EOF
$log_lines
EOF
}

filter_cups_log_older_than_hours() {
  local log_lines="$1"
  local min_age_hours="$2"

  MIN_AGE_HOURS="$min_age_hours" perl -MTime::Piece -e '
    use strict;
    use warnings;

    my $min_age_seconds = ($ENV{MIN_AGE_HOURS} || 24) * 3600;
    my $now = time;

    while (my $line = <STDIN>) {
      if ($line =~ /^[EW] \[(\d{2}\/[A-Z][a-z]{2}\/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]/) {
        my $ts = eval { Time::Piece->strptime($1, "%d/%b/%Y:%H:%M:%S %z")->epoch };
        next if !defined $ts;
        print $line if ($now - $ts) > $min_age_seconds;
      }
    }
  ' <<EOF
$log_lines
EOF
}

filter_lpstat_jobs_by_age_hours() {
  local job_lines="$1"
  local max_age_hours="$2"

  MAX_AGE_HOURS="$max_age_hours" perl -MTime::Piece -e '
    use strict;
    use warnings;

    my $max_age_seconds = ($ENV{MAX_AGE_HOURS} || 24) * 3600;
    my $now = time;

    while (my $line = <STDIN>) {
      chomp $line;
      if ($line =~ /^\S+\s+\S+\s+\d+\s+([A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})$/) {
        my $ts = eval { Time::Piece->strptime($1, "%a %b %d %H:%M:%S %Y")->epoch };
        next if !defined $ts;
        print "$line\n" if ($now - $ts) <= $max_age_seconds;
      }
    }
  ' <<EOF
$job_lines
EOF
}

filter_lpstat_jobs_older_than_hours() {
  local job_lines="$1"
  local min_age_hours="$2"

  MIN_AGE_HOURS="$min_age_hours" perl -MTime::Piece -e '
    use strict;
    use warnings;

    my $min_age_seconds = ($ENV{MIN_AGE_HOURS} || 24) * 3600;
    my $now = time;

    while (my $line = <STDIN>) {
      chomp $line;
      if ($line =~ /^\S+\s+\S+\s+\d+\s+([A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4})$/) {
        my $ts = eval { Time::Piece->strptime($1, "%a %b %d %H:%M:%S %Y")->epoch };
        next if !defined $ts;
        print "$line\n" if ($now - $ts) > $min_age_seconds;
      }
    }
  ' <<EOF
$job_lines
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

count_jobs_summary_lines() {
  local jobs_summary="$1"

  printf '%s\n' "$jobs_summary" | awk 'NF { count++ } END { print count + 0 }'
}

count_processing_jobs_summary_lines() {
  local jobs_summary="$1"

  printf '%s\n' "$jobs_summary" | awk '/job-state=processing/ { count++ } END { print count + 0 }'
}

extract_hp_job_list_summary() {
  local xml="$1"

  printf '%s\n' "$xml" | awk '
    /<j:Job>/ {
      url = ""
      category = ""
      state = ""
      update = ""
    }
    /<j:JobUrl>/ {
      sub(/.*<j:JobUrl>/, "")
      sub(/<.*/, "")
      url = $0
    }
    /<j:JobCategory>/ {
      sub(/.*<j:JobCategory>/, "")
      sub(/<.*/, "")
      category = $0
    }
    /<j:JobState>/ {
      sub(/.*<j:JobState>/, "")
      sub(/<.*/, "")
      state = $0
    }
    /<j:JobStateUpdate>/ {
      sub(/.*<j:JobStateUpdate>/, "")
      sub(/<.*/, "")
      update = $0
    }
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

MONITOR_LAST_ACTIVE=0

capture_monitor_sample() {
  local sample_index="$1"
  local sample_dir=""
  local sample_stamp
  local sample_iso
  local cups_status=""
  local active_jobs=""
  local ipp_attrs=""
  local ipp_jobs=""
  local hp_status_xml=""
  local hp_jobs_xml=""
  local hp_logs_xml=""
  local cups_head=""
  local ipp_state=""
  local ipp_reasons=""
  local ipp_queued=""
  local ipp_job_summary=""
  local hp_status=""
  local hp_job_summary=""
  local hp_error_first=""

  sample_stamp="$(date +%Y%m%d-%H%M%S)"
  sample_iso="$(date '+%Y-%m-%dT%H:%M:%S%z')"

  if [ "$SAVE_RAW" -eq 1 ]; then
    sample_dir="$OUTPUT_DIR/monitor/$(printf '%03d' "$sample_index")-${sample_stamp}"
    mkdir -p "$sample_dir"
  fi

  cups_status="$(lpstat -l -p "$QUEUE" 2>/dev/null || true)"
  active_jobs="$(lpstat -W not-completed -o "$QUEUE" 2>/dev/null || true)"

  if [ -n "$ENDPOINT_HOST" ] && have ipptool; then
    ipp_attrs="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-printer-attributes.test 2>&1 || true)"
    ipp_jobs="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-jobs.test 2>&1 || true)"
  fi

  if [ -n "$ENDPOINT_HOST" ]; then
    hp_status_xml="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
    hp_jobs_xml="$(fetch_url "/Jobs/JobList" || true)"
    hp_logs_xml="$(fetch_url "/DevMgmt/ProductLogsDyn.xml" || true)"
  fi

  if [ -n "$sample_dir" ]; then
    printf '%s\n' "$cups_status" >"$sample_dir/cups-status.txt"
    printf '%s\n' "$active_jobs" >"$sample_dir/active-jobs.txt"
    printf '%s\n' "$ipp_attrs" >"$sample_dir/ipp-printer-attributes.txt"
    printf '%s\n' "$ipp_jobs" >"$sample_dir/ipp-jobs.txt"
    printf '%s\n' "$hp_status_xml" >"$sample_dir/product-status.xml"
    printf '%s\n' "$hp_jobs_xml" >"$sample_dir/jobs-joblist.xml"
    printf '%s\n' "$hp_logs_xml" >"$sample_dir/product-logs.xml"
  fi

  cups_head="$(printf '%s\n' "$cups_status" | head -n 1 | tr '\t' ' ' | sed 's/  */ /g')"
  ipp_state="$(extract_ipptool_value "$ipp_attrs" "printer-state")"
  ipp_reasons="$(extract_ipptool_value "$ipp_attrs" "printer-state-reasons")"
  ipp_queued="$(extract_ipptool_value "$ipp_attrs" "queued-job-count")"
  ipp_job_summary="$(extract_jobs_summary "$ipp_jobs" | head -n 1)"
  hp_status="$(extract_tag_value "$hp_status_xml" "pscat:StatusCategory")"
  hp_job_summary="$(extract_hp_job_list_summary "$hp_jobs_xml" | head -n 1)"
  hp_error_first="$(extract_product_error_log "$hp_logs_xml" | head -n 1)"

  MONITOR_LAST_ACTIVE=0
  if printf '%s' "$cups_head" | grep -q 'now printing'; then
    MONITOR_LAST_ACTIVE=1
  fi
  if [ -n "$active_jobs" ] || [ "${ipp_state:-}" = "processing" ] || [ "${ipp_queued:-0}" != "0" ] || [ "${hp_status:-}" = "processing" ] || [ -n "$ipp_job_summary" ] || [ -n "$hp_job_summary" ]; then
    MONITOR_LAST_ACTIVE=1
  fi

  printf '[%s] cups="%s" ipp-state=%s ipp-reasons=%s queued=%s\n' \
    "$sample_iso" \
    "${cups_head:-unknown}" \
    "${ipp_state:-unknown}" \
    "${ipp_reasons:-unknown}" \
    "${ipp_queued:-unknown}"

  if [ -n "$ipp_job_summary" ]; then
    printf '  ipp-job: %s\n' "$ipp_job_summary"
  fi

  if [ -n "$hp_status" ] || [ -n "$hp_job_summary" ]; then
    printf '  hp-status: %s\n' "${hp_status:-unknown}"
    if [ -n "$hp_job_summary" ]; then
      printf '  hp-job: %s\n' "$hp_job_summary"
    fi
  fi

  if [ -n "$hp_error_first" ]; then
    printf '  hp-error-first-line: %s\n' "$hp_error_first"
  fi

  if [ -n "$sample_dir" ]; then
    printf '  raw-sample-dir: %s\n' "$sample_dir"
  fi
}

plain_value() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'
}

plain_kv() {
  printf '%s=%s\n' "$1" "$(plain_value "$2")"
}

collect_plain_summary_inputs() {
  if [ -n "$ENDPOINT_HOST" ]; then
    PLAIN_PRODUCT_STATUS_XML="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
    PLAIN_PRODUCT_LOGS_XML="$(fetch_url "/DevMgmt/ProductLogsDyn.xml" || true)"
    PLAIN_PRODUCT_USAGE_XML="$(fetch_url "/DevMgmt/ProductUsageDyn.xml" || true)"
    PLAIN_CONSUMABLE_XML="$(fetch_url "/DevMgmt/ConsumableConfigDyn.xml" || true)"
    PLAIN_EPRINT_CONFIG_XML="$(fetch_url "/ePrint/ePrintConfigDyn.xml" || true)"
    PLAIN_CONSUMABLE_SUBSCRIPTION_INFO_XML="$(fetch_url "/ConsumableSubscription/Info" || true)"
    PLAIN_HP_JOB_LIST_XML="$(fetch_url "/Jobs/JobList" || true)"
  fi

  STATUS_CATEGORY="$(extract_tag_value "${PLAIN_PRODUCT_STATUS_XML:-}" "pscat:StatusCategory")"
  STATUS_STRING_ID="$(extract_tag_value "${PLAIN_PRODUCT_STATUS_XML:-}" "locid:StringId")"
  PRODUCT_ERROR_LOG="$(extract_product_error_log "${PLAIN_PRODUCT_LOGS_XML:-}")"
  MISPICK_EVENTS="$(extract_first_element_value "${PLAIN_PRODUCT_USAGE_XML:-}" "dd:MispickEvents")"
  EPRINT_EMAIL_SERVICE="$(extract_tag_value "${PLAIN_EPRINT_CONFIG_XML:-}" "ep:EmailService")"
  EPRINT_SIP_SERVICE="$(extract_tag_value "${PLAIN_EPRINT_CONFIG_XML:-}" "ep:SipService")"
  EPRINT_MOBILE_APPS_SERVICE="$(extract_tag_value "${PLAIN_EPRINT_CONFIG_XML:-}" "ep:MobileAppsService")"
  EPRINT_REGISTRATION_STATE="$(extract_tag_value "${PLAIN_EPRINT_CONFIG_XML:-}" "ep:RegistrationState")"
  EPRINT_XMPP_STATE="$(extract_tag_value "${PLAIN_EPRINT_CONFIG_XML:-}" "ep:XMPPConnectionState")"
  EPRINT_SIGNALING_STATE="$(extract_tag_value "${PLAIN_EPRINT_CONFIG_XML:-}" "ep:SignalingConnectionState")"
  CONSUMABLE_SUBSCRIPTION_STATUS="$(extract_tag_value "${PLAIN_CONSUMABLE_SUBSCRIPTION_INFO_XML:-}" "cs:Status")"
  SUBSCRIPTION_CONSUMABLE_COUNT="$(printf '%s\n' "${PLAIN_CONSUMABLE_XML:-}" | awk '/<dd:IsSubscription>true<\/dd:IsSubscription>/ { count++ } END { print count + 0 }')"

  # Count HP-side processing jobs for the plain stuck detection
  PLAIN_HP_PROCESSING_JOB_COUNT="$(printf '%s\n' "${PLAIN_HP_JOB_LIST_XML:-}" | awk '/<j:JobState>Processing<\/j:JobState>/ { count++ } END { print count + 0 }')"

  # Count IPP-side processing jobs if ipptool is available
  PLAIN_IPP_PROCESSING_JOB_COUNT=0
  if [ -n "$ENDPOINT_HOST" ] && have ipptool; then
    PLAIN_IPP_JOBS_RAW="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-jobs.test 2>&1 || true)"
    PLAIN_IPP_JOBS_SUMMARY="$(extract_jobs_summary "$PLAIN_IPP_JOBS_RAW")"
    PLAIN_IPP_PROCESSING_JOB_COUNT="$(count_processing_jobs_summary_lines "$PLAIN_IPP_JOBS_SUMMARY")"
  fi

  if [ "${EPRINT_EMAIL_SERVICE:-}" = "disabled" ] && [ "${EPRINT_SIP_SERVICE:-}" = "disabled" ] && [ "${EPRINT_MOBILE_APPS_SERVICE:-}" = "disabled" ] && [ "${EPRINT_REGISTRATION_STATE:-}" = "unregistered" ]; then
    CLOUD_HEALTH="disabled"
  elif [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ]; then
    if [ "${EPRINT_REGISTRATION_STATE:-}" = "registered" ] && [ "${EPRINT_XMPP_STATE:-}" = "connected" ] && [ "${EPRINT_SIGNALING_STATE:-}" = "connected" ]; then
      CLOUD_HEALTH="healthy"
    else
      CLOUD_HEALTH="degraded"
    fi
  elif [ -n "${EPRINT_REGISTRATION_STATE:-}" ] || [ -n "${EPRINT_XMPP_STATE:-}" ] || [ -n "${EPRINT_SIGNALING_STATE:-}" ]; then
    CLOUD_HEALTH="not-in-use"
  else
    CLOUD_HEALTH="unknown"
  fi

  # Mirror the prose-path stuck detection in plain mode:
  # HP has a processing job but IPP reports no processing jobs → job is trapped.
  if [ "${PLAIN_HP_PROCESSING_JOB_COUNT:-0}" -gt 0 ] && [ "${PLAIN_IPP_PROCESSING_JOB_COUNT:-0}" -eq 0 ]; then
    PRINT_ENGINE_HEALTH="stuck"
  elif [ -n "${STATUS_CATEGORY:-}" ] && [ "$STATUS_CATEGORY" != "ready" ] && [ "$STATUS_CATEGORY" != "inPowerSave" ]; then
    PRINT_ENGINE_HEALTH="active"
  elif [ -n "${PRODUCT_ERROR_LOG:-}" ]; then
    PRINT_ENGINE_HEALTH="degraded"
  else
    PRINT_ENGINE_HEALTH="healthy"
  fi

  if printf '%s\n' "$QUEUE_STATUS_LINE" | grep -q 'disabled'; then
    MAC_QUEUE_HEALTH="degraded"
  elif printf '%s\n' "$QUEUE_STATUS_LINE" | grep -q 'now printing'; then
    MAC_QUEUE_HEALTH="active"
  else
    MAC_QUEUE_HEALTH="healthy"
  fi
}

emit_plain_summary() {
  plain_kv command "$COMMAND"
  plain_kv queue "${QUEUE:-unknown}"
  plain_kv host "${HOST:-unknown}"
  plain_kv ipv4 "${RESOLVED_IP:-unknown}"
  plain_kv print_engine_health "${PRINT_ENGINE_HEALTH:-unknown}"
  plain_kv cloud_health "${CLOUD_HEALTH:-unknown}"
  plain_kv mac_queue_health "${MAC_QUEUE_HEALTH:-unknown}"
  plain_kv status_category "${STATUS_CATEGORY:-unknown}"
  if [ -n "$PRODUCT_ERROR_LOG" ]; then
    plain_kv product_error_log "$PRODUCT_ERROR_LOG"
  else
    plain_kv product_error_log empty
  fi
  plain_kv mispick_events "${MISPICK_EVENTS:-unknown}"
  plain_kv eprint_registration_state "${EPRINT_REGISTRATION_STATE:-unknown}"
  plain_kv eprint_signaling_state "${EPRINT_SIGNALING_STATE:-unknown}"

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

enable_full_repair_recipe() {
  SEND_SOFT_RESET_PJL=1
  EXPERIMENTAL_CLEAR_JOBS=1
  CANCEL_CONNECTING=1
  REPAIR_ACTION_SELECTED=1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    diagnose)
      if [ "$COMMAND" = "diagnose" ]; then
        shift
      else
        PARSE_ERROR="${PARSE_ERROR:-repair.sh does not take a subcommand}"
        shift
      fi
      ;;
    repair)
      if [ "$COMMAND" = "diagnose" ]; then
        PARSE_ERROR="${PARSE_ERROR:-repair actions are available in repair.sh}"
      else
        PARSE_ERROR="${PARSE_ERROR:-repair.sh does not take a subcommand}"
      fi
      shift
      ;;
    --queue)
      if [ "$#" -lt 2 ]; then
        PARSE_ERROR="${PARSE_ERROR:---queue requires a value}"
        shift
        continue
      fi
      QUEUE="$2"
      shift 2
      ;;
    --host)
      if [ "$#" -lt 2 ]; then
        PARSE_ERROR="${PARSE_ERROR:---host requires a value}"
        shift
        continue
      fi
      HOST="$2"
      shift 2
      ;;
    --community)
      if [ "$#" -lt 2 ]; then
        PARSE_ERROR="${PARSE_ERROR:---community requires a value}"
        shift
        continue
      fi
      COMMUNITY="$2"
      shift 2
      ;;
    --save-raw)
      SAVE_RAW=1
      shift
      ;;
    --output-dir)
      if [ "$#" -lt 2 ]; then
        PARSE_ERROR="${PARSE_ERROR:---output-dir requires a value}"
        shift
        continue
      fi
      OUTPUT_DIR="$2"
      SAVE_RAW=1
      shift 2
      ;;
    --timeout)
      if [ "$#" -lt 2 ]; then
        PARSE_ERROR="${PARSE_ERROR:---timeout requires a value}"
        shift
        continue
      fi
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --monitor-printing)
      MONITOR_PRINTING=1
      shift
      ;;
    --interval)
      if [ "$#" -lt 2 ]; then
        PARSE_ERROR="${PARSE_ERROR:---interval requires a value}"
        shift
        continue
      fi
      MONITOR_INTERVAL="$2"
      shift 2
      ;;
    --samples)
      if [ "$#" -lt 2 ]; then
        PARSE_ERROR="${PARSE_ERROR:---samples requires a value}"
        shift
        continue
      fi
      MONITOR_SAMPLES="$2"
      shift 2
      ;;
    --plain)
      PLAIN_OUTPUT=1
      shift
      ;;
    --execute|--fix)
      if [ "$COMMAND" = "repair" ]; then
        enable_full_repair_recipe
      else
        PARSE_ERROR="${PARSE_ERROR:-repair actions are available in repair.sh}"
      fi
      shift
      ;;
    -h|--help)
      HELP_REQUESTED=1
      shift
      ;;
    *)
      PARSE_ERROR="${PARSE_ERROR:-Unknown option: $1}"
      shift
      ;;
  esac
done

if [ "$HELP_REQUESTED" -eq 1 ]; then
  usage "$COMMAND"
  exit 0
fi

if [ -n "$PARSE_ERROR" ]; then
  usage_error "$PARSE_ERROR"
fi

if [ "$COMMAND" = "repair" ] && [ "$REPAIR_ACTION_SELECTED" -eq 0 ]; then
  usage "$COMMAND"
  exit 0
fi

have lpstat || die "lpstat is required"
have curl || die "curl is required"

if [ "$SAVE_RAW" -eq 1 ] && [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="./diagnostics-output/$(date +%Y%m%d-%H%M%S)"
fi

if [ -z "$QUEUE" ]; then
  QUEUE="$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p' | head -n 1)"
fi

if [ -z "$QUEUE" ]; then
  QUEUE="$(lpstat -p 2>/dev/null | awk '/^printer / { print $2; exit }')"
fi

[ -n "$QUEUE" ] || die "No CUPS printer queue found. Use --queue or --host."

CUPS_OVERVIEW="$(lpstat -p -d -v 2>/dev/null || true)"
QUEUE_DETAIL="$(lpstat -l -p "$QUEUE" 2>/dev/null || true)"
ALL_JOBS="$(lpstat -W all -o "$QUEUE" 2>/dev/null || true)"
RECENT_JOBS="$(filter_lpstat_jobs_by_age_hours "$ALL_JOBS" 24)"
OLDER_JOBS="$(filter_lpstat_jobs_older_than_hours "$ALL_JOBS" 24 | tail -n 10)"

save_raw "01-cups-overview.txt" "$CUPS_OVERVIEW"
save_raw "02-queue-detail.txt" "$QUEUE_DETAIL"
save_raw "03-recent-jobs.txt" "$RECENT_JOBS"
save_raw "03-all-jobs.txt" "$ALL_JOBS"

PRINTER_DESCRIPTION="$(printf '%s\n' "$QUEUE_DETAIL" | sed -n 's/^[[:space:]]*Description: //p' | head -n 1)"
DEVICE_URI="$(printf '%s\n' "$CUPS_OVERVIEW" | awk -v q="$QUEUE" '$1 == "device" && $3 == (q ":") { sub(/^device for [^:]+: /, ""); print; exit }')"

SERVICE_NAME=""
if printf '%s' "$DEVICE_URI" | grep -q '^dnssd://'; then
  SERVICE_NAME="${DEVICE_URI#dnssd://}"
  SERVICE_NAME="${SERVICE_NAME%%._ipp._tcp.local.*}"
  SERVICE_NAME="$(url_decode "$SERVICE_NAME")"
fi

DNS_SD_LOOKUP=""
if [ -z "$HOST" ] && [ -n "$SERVICE_NAME" ] && have dns-sd; then
  DNS_SD_LOOKUP="$(run_for_seconds "$TIMEOUT_SECONDS" dns-sd -L "$SERVICE_NAME" _ipp._tcp local.)"
  HOST="$(printf '%s\n' "$DNS_SD_LOOKUP" | sed -n 's/.* can be reached at \([^:]*\):.*/\1/p' | tail -n 1)"
  HOST="${HOST%.}"
  save_raw "04-dnssd-lookup.txt" "$DNS_SD_LOOKUP"
fi

if [ -z "$HOST" ] && printf '%s' "$DEVICE_URI" | grep -Eq '^ipps?://'; then
  HOST="$(printf '%s\n' "$DEVICE_URI" | sed -n 's|^ipps\?://\([^/:?]*\).*|\1|p' | head -n 1)"
fi

RESOLVED_IP=""
DNS_SD_RESOLVE=""
if [ -n "$HOST" ] && have dns-sd; then
  DNS_SD_RESOLVE="$(run_for_seconds "$TIMEOUT_SECONDS" dns-sd -G v4v6 "$HOST")"
  RESOLVED_IP="$(printf '%s\n' "$DNS_SD_RESOLVE" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1)"
  save_raw "05-dnssd-resolve.txt" "$DNS_SD_RESOLVE"
fi

if [ -z "$RESOLVED_IP" ] && printf '%s' "$HOST" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
  RESOLVED_IP="$HOST"
fi

ENDPOINT_HOST="$HOST"
if [ -n "$RESOLVED_IP" ]; then
  ENDPOINT_HOST="$RESOLVED_IP"
fi

if [ "$COMMAND" = "repair" ] && [ "$SEND_SOFT_RESET_PJL" -eq 1 ]; then
  [ -n "$ENDPOINT_HOST" ] || die "the repair recipe requires a resolved printer host"
  RESET_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  RESET_RESULT="$(send_soft_reset_pjl "$ENDPOINT_HOST" 2>&1 || true)"
  save_raw "07-soft-reset-pjl.txt" "timestamp=$RESET_TIMESTAMP
target=$ENDPOINT_HOST
$RESET_RESULT"
fi

CANCEL_CONNECTING_TIMESTAMP=""
CANCEL_CONNECTING_HTTP_CODE=""
CANCEL_CONNECTING_RESPONSE=""
CANCEL_CONNECTING_PRE_CONFIG_XML=""
CANCEL_CONNECTING_POST_CONFIG_XML=""
CANCEL_CONNECTING_PRE_STATUS_XML=""
CANCEL_CONNECTING_POST_STATUS_XML=""
CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML=""
CANCEL_CONNECTING_POST_SUBSCRIPTION_XML=""

if [ "$COMMAND" = "repair" ] && [ "$CANCEL_CONNECTING" -eq 1 ]; then
  [ -n "$ENDPOINT_HOST" ] || die "the repair recipe requires a resolved printer host"
  CANCEL_CONNECTING_TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  CANCEL_CONNECTING_PRE_CONFIG_XML="$(fetch_url "/ePrint/ePrintConfigDyn.xml" || true)"
  CANCEL_CONNECTING_PRE_STATUS_XML="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
  CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML="$(fetch_url "/ConsumableSubscription/Info" || true)"

  response_file="$(mktemp)"
  register_temp_file "$response_file"
  CANCEL_CONNECTING_HTTP_CODE="$(send_eprint_disable_put "$ENDPOINT_HOST" "$response_file" 2>&1 || true)"
  CANCEL_CONNECTING_RESPONSE="$(cat "$response_file" 2>/dev/null || true)"
  rm -f "$response_file"

  sleep 3

  CANCEL_CONNECTING_POST_CONFIG_XML="$(fetch_url "/ePrint/ePrintConfigDyn.xml" || true)"
  CANCEL_CONNECTING_POST_STATUS_XML="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
  CANCEL_CONNECTING_POST_SUBSCRIPTION_XML="$(fetch_url "/ConsumableSubscription/Info" || true)"

  save_raw "52-cancel-connecting-pre-eprint-config.xml" "$CANCEL_CONNECTING_PRE_CONFIG_XML"
  save_raw "53-cancel-connecting-pre-product-status.xml" "$CANCEL_CONNECTING_PRE_STATUS_XML"
  save_raw "54-cancel-connecting-pre-subscription.xml" "$CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML"
  save_raw "55-cancel-connecting-http-response.txt" "timestamp=$CANCEL_CONNECTING_TIMESTAMP
target=$ENDPOINT_HOST
http_code=$CANCEL_CONNECTING_HTTP_CODE
$CANCEL_CONNECTING_RESPONSE"
  save_raw "56-cancel-connecting-post-eprint-config.xml" "$CANCEL_CONNECTING_POST_CONFIG_XML"
  save_raw "57-cancel-connecting-post-product-status.xml" "$CANCEL_CONNECTING_POST_STATUS_XML"
  save_raw "58-cancel-connecting-post-subscription.xml" "$CANCEL_CONNECTING_POST_SUBSCRIPTION_XML"
fi

EXPERIMENTAL_ACTION_LOG=""
POST_ACTION_JOB_LIST_XML=""
POST_ACTION_STATUS_XML=""
POST_ACTION_IPP_RAW=""
POST_ACTION_JOB_LIST_SUMMARY=""
POST_ACTION_STATUS_CATEGORY=""
POST_ACTION_IPP_STATE=""
POST_ACTION_IPP_REASONS=""
POST_ACTION_IPP_QUEUED=""

if [ "$EXPERIMENTAL_CLEAR_JOBS" -eq 1 ]; then
  [ -n "$ENDPOINT_HOST" ] || die "the repair recipe requires a resolved printer host"
  HP_JOB_LIST_XML="$(fetch_url "/Jobs/JobList" || true)"
  processing_job_urls="$(extract_processing_hp_job_urls "$HP_JOB_LIST_XML")"

  if [ -n "$processing_job_urls" ]; then
    EXPERIMENTAL_ACTION_LOG="${EXPERIMENTAL_ACTION_LOG}Found processing jobs:\n${processing_job_urls}\n"

    while IFS= read -r job_url; do
      [ -n "$job_url" ] || continue
      response_file="$(mktemp)"
      register_temp_file "$response_file"
      http_code="$(send_hp_job_cancel_put "$ENDPOINT_HOST" "$job_url" "$response_file" 2>&1 || true)"
      response_body="$(cat "$response_file" 2>/dev/null || true)"
      rm -f "$response_file"
      EXPERIMENTAL_ACTION_LOG="${EXPERIMENTAL_ACTION_LOG}PUT ${job_url} -> ${http_code}\n${response_body}\n"
    done <<EOF
$processing_job_urls
EOF

    sleep 2
    POST_ACTION_JOB_LIST_XML="$(fetch_url "/Jobs/JobList" || true)"
    POST_ACTION_STATUS_XML="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
    POST_ACTION_IPP_RAW="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-printer-attributes.test 2>&1 || true)"
    POST_ACTION_JOB_LIST_SUMMARY="$(extract_hp_job_list_summary "$POST_ACTION_JOB_LIST_XML")"
    POST_ACTION_STATUS_CATEGORY="$(extract_tag_value "$POST_ACTION_STATUS_XML" "pscat:StatusCategory")"
    POST_ACTION_IPP_STATE="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "printer-state")"
    POST_ACTION_IPP_REASONS="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "printer-state-reasons")"
    POST_ACTION_IPP_QUEUED="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "queued-job-count")"

    if printf '%s\n' "$POST_ACTION_JOB_LIST_SUMMARY" | grep -q ' state=Processing'; then
      soft_reset_output="$(send_soft_reset_pjl "$ENDPOINT_HOST" 2>&1 || true)"
      EXPERIMENTAL_ACTION_LOG="${EXPERIMENTAL_ACTION_LOG}Fallback soft PJL reset sent\n${soft_reset_output}\n"
      sleep 2
      POST_ACTION_JOB_LIST_XML="$(fetch_url "/Jobs/JobList" || true)"
      POST_ACTION_STATUS_XML="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
      POST_ACTION_IPP_RAW="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-printer-attributes.test 2>&1 || true)"
      POST_ACTION_JOB_LIST_SUMMARY="$(extract_hp_job_list_summary "$POST_ACTION_JOB_LIST_XML")"
      POST_ACTION_STATUS_CATEGORY="$(extract_tag_value "$POST_ACTION_STATUS_XML" "pscat:StatusCategory")"
      POST_ACTION_IPP_STATE="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "printer-state")"
      POST_ACTION_IPP_REASONS="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "printer-state-reasons")"
      POST_ACTION_IPP_QUEUED="$(extract_ipptool_value "$POST_ACTION_IPP_RAW" "queued-job-count")"
    fi
  else
    EXPERIMENTAL_ACTION_LOG="No processing printer-side jobs found in /Jobs/JobList.\n"
  fi

  save_raw "48-experimental-clear-jobs.txt" "$EXPERIMENTAL_ACTION_LOG"
  save_raw "49-post-action-jobs-joblist.xml" "$POST_ACTION_JOB_LIST_XML"
  save_raw "50-post-action-product-status.xml" "$POST_ACTION_STATUS_XML"
  save_raw "51-post-action-ipp-attributes.txt" "$POST_ACTION_IPP_RAW"
fi

QUEUE_STATUS_LINE="$(printf '%s\n' "$QUEUE_DETAIL" | head -n 1 | tr '\t' ' ' | sed 's/  */ /g')"

if [ "$PLAIN_OUTPUT" -eq 1 ]; then
  collect_plain_summary_inputs
  emit_plain_summary
  exit 0
fi

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

section "CUPS"
printf '%s\n' "$CUPS_OVERVIEW"
printf '\n'
printf '%s\n' "$QUEUE_DETAIL"
printf '\n'
if [ -n "$RECENT_JOBS" ]; then
  note "Recent jobs (last 24 hours):"
  printf '%s\n' "$RECENT_JOBS"
else
  note "Recent jobs (last 24 hours): none found"
fi

printf '\n'
if [ -n "$OLDER_JOBS" ]; then
  note "Older jobs (latest 10 before the last 24 hours):"
  printf '%s\n' "$OLDER_JOBS"
fi

CUPS_LOG_PATH="${CUPS_ERROR_LOG_PATH:-}"
ALL_CUPS_ERRORS=""
RECENT_CUPS_ERRORS=""
OLDER_CUPS_ERRORS=""
if [ -n "$CUPS_LOG_PATH" ] && [ ! -r "$CUPS_LOG_PATH" ]; then
  warn "CUPS_ERROR_LOG_PATH is set but not readable: $CUPS_LOG_PATH"
  CUPS_LOG_PATH=""
fi

if [ -z "$CUPS_LOG_PATH" ] && [ -r /var/log/cups/error_log ]; then
  CUPS_LOG_PATH="/var/log/cups/error_log"
elif [ -z "$CUPS_LOG_PATH" ] && [ -r /private/var/log/cups/error_log ]; then
  CUPS_LOG_PATH="/private/var/log/cups/error_log"
fi

if [ -n "$CUPS_LOG_PATH" ]; then
  ALL_CUPS_ERRORS="$(tail -n 200 "$CUPS_LOG_PATH" 2>/dev/null | grep -E '^[EW]' || true)"
  RECENT_CUPS_ERRORS="$(filter_cups_log_by_age_hours "$ALL_CUPS_ERRORS" 24)"
  OLDER_CUPS_ERRORS="$(filter_cups_log_older_than_hours "$ALL_CUPS_ERRORS" 24)"
  save_raw "06-cups-errors.txt" "$RECENT_CUPS_ERRORS"
  save_raw "06-cups-errors-all.txt" "$ALL_CUPS_ERRORS"
fi

printf '\n'
if [ -n "$RECENT_CUPS_ERRORS" ]; then
  note "Recent CUPS errors/warnings (last 24 hours):"
  printf '%s\n' "$RECENT_CUPS_ERRORS"
else
  note "Recent CUPS errors/warnings (last 24 hours): none found"
fi

printf '\n'
if [ -n "$OLDER_CUPS_ERRORS" ]; then
  note "Older CUPS errors/warnings (before the last 24 hours):"
  printf '%s\n' "$OLDER_CUPS_ERRORS"
fi

IPP_RAW=""
IPP_STATE=""
IPP_STATE_REASONS=""
IPP_ACCEPTING=""
IPP_QUEUED=""
IPP_UPTIME=""
IPP_ALERT=""
IPP_ALERT_DESCRIPTION=""
IPP_MARKER_NAMES=""
IPP_MARKER_LEVELS=""
IPP_JOBS_RAW=""
IPP_JOBS_SUMMARY=""
IPP_PROCESSING_JOB_COUNT=0

if [ -n "$ENDPOINT_HOST" ] && have ipptool; then
  IPP_RAW="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-printer-attributes.test 2>&1 || true)"
  IPP_JOBS_RAW="$(ipptool -tv "ipp://$ENDPOINT_HOST/ipp/print" /usr/share/cups/ipptool/get-jobs.test 2>&1 || true)"
  save_raw "10-ipp-attributes.txt" "$IPP_RAW"
  save_raw "11-ipp-jobs.txt" "$IPP_JOBS_RAW"

  IPP_STATE="$(extract_ipptool_value "$IPP_RAW" "printer-state")"
  IPP_STATE_REASONS="$(extract_ipptool_value "$IPP_RAW" "printer-state-reasons")"
  IPP_ACCEPTING="$(extract_ipptool_value "$IPP_RAW" "printer-is-accepting-jobs")"
  IPP_QUEUED="$(extract_ipptool_value "$IPP_RAW" "queued-job-count")"
  IPP_UPTIME="$(extract_ipptool_value "$IPP_RAW" "printer-up-time")"
  IPP_ALERT="$(extract_ipptool_value "$IPP_RAW" "printer-alert")"
  IPP_ALERT_DESCRIPTION="$(extract_ipptool_value "$IPP_RAW" "printer-alert-description")"
  IPP_MARKER_NAMES="$(extract_ipptool_value "$IPP_RAW" "marker-names")"
  IPP_MARKER_LEVELS="$(extract_ipptool_value "$IPP_RAW" "marker-levels")"
  IPP_JOBS_SUMMARY="$(extract_jobs_summary "$IPP_JOBS_RAW")"
  IPP_PROCESSING_JOB_COUNT="$(count_processing_jobs_summary_lines "$IPP_JOBS_SUMMARY")"
fi

section "IPP"
if [ -n "$IPP_RAW" ]; then
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
else
  warn "IPP query did not return data"
fi

DISCOVERY_XML=""
PRODUCT_STATUS_XML=""
PRODUCT_LOGS_XML=""
PRODUCT_USAGE_XML=""
CONSUMABLE_XML=""
PRODUCT_CONFIG_XML=""
NETAPPS_DYN_XML=""
SECURITY_DYN_XML=""
FIRMWARE_UPDATE_DYN_XML=""
FIRMWARE_UPDATE_STATE_XML=""
FIRMWARE_UPDATE_CONFIG_XML=""
EPRINT_CONFIG_XML=""
EPRINT_CLAIM_STATUS_XML=""
EPRINT_CONNECTION_REASON_XML=""
CONSUMABLE_SUBSCRIPTION_INFO_XML=""
EVENT_TABLE_XML=""

DISCOVERY_ENDPOINTS=""
STATUS_CATEGORY=""
STATUS_STRING_ID=""
STATUS_MODIFICATION_NUMBER=""
PRODUCT_LOG_EVENTS=""
PRODUCT_ERROR_LOG=""
TOTAL_IMPRESSIONS=""
DUPLEX_SHEETS=""
JAM_EVENTS=""
MISPICK_EVENTS=""
WIRELESS_IMPRESSIONS=""
CONSUMABLE_SUMMARY=""
SUBSCRIPTION_LEVEL=""
SUBSCRIPTION_CONSUMABLE_COUNT=0
FIRMWARE_REVISION=""
FIRMWARE_DATE=""
SERVICE_ID=""
DEVICE_TIMESTAMP=""
POWER_SAVE_MODE=""
DNS_SD_DOMAIN=""
PROXY_URI=""
PROXY_PORT=""
FAILSAFE_STATE=""
FW_AUTO_CHECK=""
FW_AUTO_UPDATE=""
FW_STATUS=""
EPRINT_REGISTRATION_STATE=""
EPRINT_XMPP_STATE=""
EPRINT_SIGNALING_STATE=""
EPRINT_CLAIM_STATE=""
EPRINT_CONNECTION_REASON=""
EPRINT_EMAIL_SERVICE=""
EPRINT_SIP_SERVICE=""
EPRINT_MOBILE_APPS_SERVICE=""
CONSUMABLE_SUBSCRIPTION_STATUS=""
CONSUMABLE_SUBSCRIPTION_LAST_RECEIVED=""
CONSUMABLE_SUBSCRIPTION_LAST_CONNECTED=""
EVENT_TABLE_SUMMARY=""
HP_JOB_LIST_XML=""
HP_JOB_LIST_SUMMARY=""
HP_PROCESSING_JOB_COUNT=0
PRINT_ENGINE_HEALTH=""
PRINT_ENGINE_DETAIL=""
CLOUD_HEALTH=""
CLOUD_DETAIL=""
MAC_QUEUE_HEALTH=""
MAC_QUEUE_DETAIL=""
if [ -n "$ENDPOINT_HOST" ]; then
  DISCOVERY_XML="$(fetch_url "/DevMgmt/DiscoveryTree.xml" || true)"
  PRODUCT_STATUS_XML="$(fetch_url "/DevMgmt/ProductStatusDyn.xml" || true)"
  PRODUCT_LOGS_XML="$(fetch_url "/DevMgmt/ProductLogsDyn.xml" || true)"
  PRODUCT_USAGE_XML="$(fetch_url "/DevMgmt/ProductUsageDyn.xml" || true)"
  CONSUMABLE_XML="$(fetch_url "/DevMgmt/ConsumableConfigDyn.xml" || true)"
  PRODUCT_CONFIG_XML="$(fetch_url "/DevMgmt/ProductConfigDyn.xml" || true)"
  NETAPPS_DYN_XML="$(fetch_url "/DevMgmt/NetAppsDyn.xml" || true)"
  SECURITY_DYN_XML="$(fetch_url "/DevMgmt/SecurityDyn.xml" || true)"
  FIRMWARE_UPDATE_DYN_XML="$(fetch_url "/FirmwareUpdate/FirmwareUpdateDyn.xml" || true)"
  FIRMWARE_UPDATE_STATE_XML="$(fetch_url "/FirmwareUpdate/WebFWUpdate/State" || true)"
  FIRMWARE_UPDATE_CONFIG_XML="$(fetch_url "/FirmwareUpdate/WebFWUpdate/Config" || true)"
  EPRINT_CONFIG_XML="$(fetch_url "/ePrint/ePrintConfigDyn.xml" || true)"
  EPRINT_CLAIM_STATUS_XML="$(fetch_url "/ePrint/ClaimStatus" || true)"
  EPRINT_CONNECTION_REASON_XML="$(fetch_url "/ePrint/ConnectionStateReason" || true)"
  CONSUMABLE_SUBSCRIPTION_INFO_XML="$(fetch_url "/ConsumableSubscription/Info" || true)"
  EVENT_TABLE_XML="$(fetch_url "/EventMgmt/EventTable" || true)"
  HP_JOB_LIST_XML="$(fetch_url "/Jobs/JobList" || true)"

  save_raw "20-discovery-tree.xml" "$DISCOVERY_XML"
  save_raw "21-product-status.xml" "$PRODUCT_STATUS_XML"
  save_raw "22-product-logs.xml" "$PRODUCT_LOGS_XML"
  save_raw "23-product-usage.xml" "$PRODUCT_USAGE_XML"
  save_raw "24-consumable-config.xml" "$CONSUMABLE_XML"
  save_raw "25-product-config.xml" "$PRODUCT_CONFIG_XML"
  save_raw "26-netapps-dyn.xml" "$NETAPPS_DYN_XML"
  save_raw "27-security-dyn.xml" "$SECURITY_DYN_XML"
  save_raw "40-firmware-update-dyn.xml" "$FIRMWARE_UPDATE_DYN_XML"
  save_raw "41-firmware-update-state.xml" "$FIRMWARE_UPDATE_STATE_XML"
  save_raw "42-firmware-update-config.xml" "$FIRMWARE_UPDATE_CONFIG_XML"
  save_raw "43-eprint-config.xml" "$EPRINT_CONFIG_XML"
  save_raw "44-eprint-claim-status.xml" "$EPRINT_CLAIM_STATUS_XML"
  save_raw "45-eprint-connection-state-reason.xml" "$EPRINT_CONNECTION_REASON_XML"
  save_raw "45a-consumable-subscription-info.xml" "$CONSUMABLE_SUBSCRIPTION_INFO_XML"
  save_raw "46-event-table.xml" "$EVENT_TABLE_XML"
  save_raw "47-jobs-joblist.xml" "$HP_JOB_LIST_XML"

  DISCOVERY_ENDPOINTS="$(
    printf '%s\n' "$DISCOVERY_XML" | awk '
      /<dd:ResourceURI>/ {
        line = $0
        sub(/.*<dd:ResourceURI>/, "", line)
        sub(/<\/dd:ResourceURI>.*/, "", line)
        print line
      }
    ' | grep '^/DevMgmt/' || true
  )"
  STATUS_CATEGORY="$(extract_tag_value "$PRODUCT_STATUS_XML" "pscat:StatusCategory")"
  STATUS_STRING_ID="$(extract_tag_value "$PRODUCT_STATUS_XML" "locid:StringId")"
  STATUS_MODIFICATION_NUMBER="$(extract_tag_value "$PRODUCT_STATUS_XML" "dd:ModificationNumber")"

  PRODUCT_LOG_EVENTS="$(
    printf '%s\n' "$PRODUCT_LOGS_XML" | awk '
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
  )"

  PRODUCT_ERROR_LOG="$(extract_product_error_log "$PRODUCT_LOGS_XML")"

  TOTAL_IMPRESSIONS="$(extract_first_element_value "$PRODUCT_USAGE_XML" "dd:TotalImpressions")"
  DUPLEX_SHEETS="$(extract_first_element_value "$PRODUCT_USAGE_XML" "dd:DuplexSheets")"
  JAM_EVENTS="$(extract_first_element_value "$PRODUCT_USAGE_XML" "dd:JamEvents")"
  MISPICK_EVENTS="$(extract_first_element_value "$PRODUCT_USAGE_XML" "dd:MispickEvents")"
  WIRELESS_IMPRESSIONS="$(extract_first_element_value "$PRODUCT_USAGE_XML" "dd:WirelessNetworkImpressions")"

  CONSUMABLE_SUMMARY="$(
    printf '%s\n' "$CONSUMABLE_XML" | awk '
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
  )"
  SUBSCRIPTION_LEVEL="$(extract_tag_value "$CONSUMABLE_XML" "ccdyn:MarkingAgentSubscriptionLevel")"
  SUBSCRIPTION_CONSUMABLE_COUNT="$(printf '%s\n' "$CONSUMABLE_XML" | awk '/<dd:IsSubscription>true<\/dd:IsSubscription>/ { count++ } END { print count + 0 }')"

  FIRMWARE_REVISION="$(extract_block_tag_value "$PRODUCT_CONFIG_XML" "prdcfgdyn:ProductInformation" "prdcfgdyn:ProductInformation" "dd:Revision")"
  FIRMWARE_DATE="$(extract_block_tag_value "$PRODUCT_CONFIG_XML" "prdcfgdyn:ProductInformation" "prdcfgdyn:ProductInformation" "dd:Date")"
  SERVICE_ID="$(extract_tag_value "$PRODUCT_CONFIG_XML" "dd:ServiceID")"
  DEVICE_TIMESTAMP="$(extract_tag_value "$PRODUCT_CONFIG_XML" "dd:TimeStamp")"
  POWER_SAVE_MODE="$(extract_tag_value "$PRODUCT_CONFIG_XML" "dd:PowerSave")"
  DNS_SD_DOMAIN="$(extract_tag_value "$NETAPPS_DYN_XML" "dd3:DomainName")"
  PROXY_URI="$(extract_first_element_value "$NETAPPS_DYN_XML" "dd:ResourceURI")"
  PROXY_PORT="$(extract_tag_value "$NETAPPS_DYN_XML" "dd:Port")"
  FAILSAFE_STATE="$(extract_tag_value "$SECURITY_DYN_XML" "security:State")"
  FW_AUTO_CHECK="$(extract_tag_value "$FIRMWARE_UPDATE_CONFIG_XML" "fwudyn:AutomaticCheck")"
  FW_AUTO_UPDATE="$(extract_tag_value "$FIRMWARE_UPDATE_CONFIG_XML" "fwudyn:AutomaticUpdate")"
  FW_STATUS="$(extract_tag_value "$FIRMWARE_UPDATE_STATE_XML" "fwudyn:Status")"
  EPRINT_EMAIL_SERVICE="$(extract_tag_value "$EPRINT_CONFIG_XML" "ep:EmailService")"
  EPRINT_SIP_SERVICE="$(extract_tag_value "$EPRINT_CONFIG_XML" "ep:SipService")"
  EPRINT_MOBILE_APPS_SERVICE="$(extract_tag_value "$EPRINT_CONFIG_XML" "ep:MobileAppsService")"
  EPRINT_REGISTRATION_STATE="$(extract_tag_value "$EPRINT_CONFIG_XML" "ep:RegistrationState")"
  EPRINT_XMPP_STATE="$(extract_tag_value "$EPRINT_CONFIG_XML" "ep:XMPPConnectionState")"
  EPRINT_SIGNALING_STATE="$(extract_tag_value "$EPRINT_CONFIG_XML" "ep:SignalingConnectionState")"
  EPRINT_CLAIM_STATE="$(extract_tag_value "$EPRINT_CLAIM_STATUS_XML" "ep:Status")"
  EPRINT_CONNECTION_REASON="$(printf '%s\n' "$EPRINT_CONNECTION_REASON_XML" | tr -d '[:space:]')"
  CONSUMABLE_SUBSCRIPTION_STATUS="$(extract_tag_value "$CONSUMABLE_SUBSCRIPTION_INFO_XML" "cs:Status")"
  CONSUMABLE_SUBSCRIPTION_LAST_RECEIVED="$(extract_tag_value "$CONSUMABLE_SUBSCRIPTION_INFO_XML" "cs:ReceivedDate")"
  CONSUMABLE_SUBSCRIPTION_LAST_CONNECTED="$(extract_tag_value "$CONSUMABLE_SUBSCRIPTION_INFO_XML" "cs:ConnectionDate")"
  EVENT_TABLE_SUMMARY="$(extract_event_table_summary "$EVENT_TABLE_XML")"
  HP_JOB_LIST_SUMMARY="$(extract_hp_job_list_summary "$HP_JOB_LIST_XML")"
  HP_PROCESSING_JOB_COUNT="$(printf '%s\n' "$HP_JOB_LIST_SUMMARY" | awk '/ state=Processing / || / state=Processing$/ { count++ } END { print count + 0 }')"
fi

section "HP Embedded Web Server"
if [ -n "$DISCOVERY_ENDPOINTS" ]; then
  note "DiscoveryTree DevMgmt endpoints:"
  printf '%s\n' "$DISCOVERY_ENDPOINTS"
else
  warn "DiscoveryTree.xml did not return endpoints"
fi

printf '\n'
if [ -n "$STATUS_CATEGORY" ] || [ -n "$STATUS_STRING_ID" ]; then
  note "ProductStatusDyn status-category: ${STATUS_CATEGORY:-unknown}"
  note "ProductStatusDyn string-id: ${STATUS_STRING_ID:-unknown}"
else
  warn "ProductStatusDyn.xml did not return a status summary"
fi

printf '\n'
if [ -n "$PRODUCT_LOG_EVENTS" ]; then
  note "ProductLogsDyn event codes:"
  printf '%s\n' "$PRODUCT_LOG_EVENTS"
else
  note "ProductLogsDyn event codes: none returned"
fi

printf '\n'
if [ -n "$PRODUCT_ERROR_LOG" ]; then
  note "ProductLogsDyn hidden error log:"
  printf '%s\n' "$PRODUCT_ERROR_LOG"
else
  note "ProductLogsDyn hidden error log: empty"
fi

printf '\n'
if [ -n "$TOTAL_IMPRESSIONS" ] || [ -n "$JAM_EVENTS" ] || [ -n "$MISPICK_EVENTS" ]; then
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

section "HP Services"
if [ -n "$FIRMWARE_REVISION" ] || [ -n "$SERVICE_ID" ]; then
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
if [ -n "$FW_STATUS" ] || [ -n "$FW_AUTO_CHECK" ] || [ -n "$FW_AUTO_UPDATE" ]; then
  note "FirmwareUpdate state: ${FW_STATUS:-unknown}"
  note "FirmwareUpdate automatic-check: ${FW_AUTO_CHECK:-unknown}"
  note "FirmwareUpdate automatic-update: ${FW_AUTO_UPDATE:-unknown}"
else
  note "FirmwareUpdate endpoints did not return data"
fi

printf '\n'
if [ -n "$EPRINT_REGISTRATION_STATE" ] || [ -n "$EPRINT_XMPP_STATE" ] || [ -n "$EPRINT_SIGNALING_STATE" ]; then
  note "ePrint email-service: ${EPRINT_EMAIL_SERVICE:-unknown}"
  note "ePrint sip-service: ${EPRINT_SIP_SERVICE:-unknown}"
  note "ePrint mobile-apps-service: ${EPRINT_MOBILE_APPS_SERVICE:-unknown}"
  note "ePrint registration-state: ${EPRINT_REGISTRATION_STATE:-unknown}"
  note "ePrint xmpp-connection-state: ${EPRINT_XMPP_STATE:-unknown}"
  note "ePrint signaling-connection-state: ${EPRINT_SIGNALING_STATE:-unknown}"
  note "ePrint claim-status: ${EPRINT_CLAIM_STATE:-unknown}"
  if [ -n "$EPRINT_CONNECTION_REASON" ]; then
    note "ePrint connection-state-reason: $EPRINT_CONNECTION_REASON"
  else
    note "ePrint connection-state-reason: none returned"
  fi
else
  note "ePrint endpoints did not return connection data"
fi

printf '\n'
if [ -n "$CONSUMABLE_SUBSCRIPTION_STATUS" ]; then
  note "ConsumableSubscription status: ${CONSUMABLE_SUBSCRIPTION_STATUS}"
  note "ConsumableSubscription last-received-date: ${CONSUMABLE_SUBSCRIPTION_LAST_RECEIVED:-unknown}"
  note "ConsumableSubscription last-connection-date: ${CONSUMABLE_SUBSCRIPTION_LAST_CONNECTED:-unknown}"
else
  note "ConsumableSubscription endpoints did not return subscription data"
fi

printf '\n'
if [ -n "$EVENT_TABLE_SUMMARY" ]; then
  note "EventMgmt event table:"
  printf '%s\n' "$EVENT_TABLE_SUMMARY"
else
  note "EventMgmt event table: none returned"
fi

printf '\n'
if [ -n "$HP_JOB_LIST_SUMMARY" ]; then
  note "Jobs/JobList summary:"
  printf '%s\n' "$HP_JOB_LIST_SUMMARY"
fi

printf '\n'
if [ -n "$DNS_SD_DOMAIN" ] || [ -n "$PROXY_PORT" ]; then
  note "NetApps domain-name: ${DNS_SD_DOMAIN:-unknown}"
  note "NetApps proxy-uri: ${PROXY_URI:-none}"
  note "NetApps proxy-port: ${PROXY_PORT:-0}"
  note "Security failsafe-state: ${FAILSAFE_STATE:-unknown}"
fi

if [ -n "$IPP_STATE_REASONS" ] && [ "$IPP_STATE_REASONS" = "spool-area-full-report" ]; then
  PRINT_ENGINE_HEALTH="stuck"
  PRINT_ENGINE_DETAIL="printer reports spool-area-full-report"
elif [ "$HP_PROCESSING_JOB_COUNT" -gt 0 ] && [ "$IPP_PROCESSING_JOB_COUNT" -eq 0 ]; then
  PRINT_ENGINE_HEALTH="stuck"
  PRINT_ENGINE_DETAIL="internal printer job is still processing"
elif [ -n "$STATUS_CATEGORY" ] && [ "$STATUS_CATEGORY" != "ready" ] && [ "$STATUS_CATEGORY" != "inPowerSave" ]; then
  PRINT_ENGINE_HEALTH="active"
  PRINT_ENGINE_DETAIL="printer status is ${STATUS_CATEGORY}"
elif [ -n "$PRODUCT_ERROR_LOG" ]; then
  PRINT_ENGINE_HEALTH="degraded"
  PRINT_ENGINE_DETAIL="hidden HP error log is non-empty"
else
  PRINT_ENGINE_HEALTH="healthy"
  PRINT_ENGINE_DETAIL="printer reports ready/idle"
fi

if [ "${EPRINT_EMAIL_SERVICE:-}" = "disabled" ] && [ "${EPRINT_SIP_SERVICE:-}" = "disabled" ] && [ "${EPRINT_MOBILE_APPS_SERVICE:-}" = "disabled" ] && [ "${EPRINT_REGISTRATION_STATE:-}" = "unregistered" ]; then
  CLOUD_HEALTH="disabled"
  if [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ]; then
    CLOUD_DETAIL="HP web services are intentionally disabled while subscription cartridges remain installed"
  else
    CLOUD_DETAIL="HP web services are intentionally disabled"
  fi
elif [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ]; then
  if [ "${EPRINT_REGISTRATION_STATE:-}" = "registered" ] && [ "${EPRINT_XMPP_STATE:-}" = "connected" ] && [ "${EPRINT_SIGNALING_STATE:-}" = "connected" ]; then
    CLOUD_HEALTH="healthy"
    CLOUD_DETAIL="Instant Ink cloud path is fully connected"
  else
    CLOUD_HEALTH="degraded"
    CLOUD_DETAIL="subscription cartridges installed, but HP cloud signaling is not fully connected"
  fi
elif [ -n "$EPRINT_REGISTRATION_STATE" ] || [ -n "$EPRINT_XMPP_STATE" ] || [ -n "$EPRINT_SIGNALING_STATE" ]; then
  CLOUD_HEALTH="not-in-use"
  CLOUD_DETAIL="no subscription cartridges detected"
else
  CLOUD_HEALTH="unknown"
  CLOUD_DETAIL="cloud state not available"
fi

if printf '%s\n' "$QUEUE_STATUS_LINE" | grep -q 'disabled'; then
  MAC_QUEUE_HEALTH="degraded"
  MAC_QUEUE_DETAIL="CUPS queue is disabled"
elif printf '%s\n' "$QUEUE_STATUS_LINE" | grep -q 'now printing'; then
  MAC_QUEUE_HEALTH="active"
  MAC_QUEUE_DETAIL="CUPS queue currently has an active job"
else
  MAC_QUEUE_HEALTH="healthy"
  MAC_QUEUE_DETAIL="CUPS queue is enabled and idle"
fi

section "Health Summary"
note "Print engine: ${PRINT_ENGINE_HEALTH} (${PRINT_ENGINE_DETAIL})"
note "Cloud/Instant Ink: ${CLOUD_HEALTH} (${CLOUD_DETAIL})"
note "Mac queue: ${MAC_QUEUE_HEALTH} (${MAC_QUEUE_DETAIL})"

SNMP_STATUS_RAW=""
SNMP_SUPPLIES_RAW=""
SNMP_SUPPLIES_SUMMARY=""

if [ -n "$RESOLVED_IP" ] && have snmpget; then
  SNMP_STATUS_RAW="$(snmpget -v1 -c "$COMMUNITY" "$RESOLVED_IP" 1.3.6.1.2.1.25.3.5.1.1.1 1.3.6.1.2.1.25.3.5.1.2.1 2>&1 || true)"
  save_raw "30-snmp-status.txt" "$SNMP_STATUS_RAW"
fi

if [ -n "$RESOLVED_IP" ] && have snmpwalk; then
  SNMP_SUPPLIES_RAW="$(snmpwalk -v1 -c "$COMMUNITY" "$RESOLVED_IP" 1.3.6.1.2.1.43.11.1.1 2>&1 || true)"
  save_raw "31-snmp-supplies.txt" "$SNMP_SUPPLIES_RAW"
  SNMP_SUPPLIES_SUMMARY="$(
    printf '%s\n' "$SNMP_SUPPLIES_RAW" | awk -F' = ' '
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
  )"
fi

section "SNMP"
if [ -n "$SNMP_STATUS_RAW" ]; then
  printf '%s\n' "$SNMP_STATUS_RAW"
else
  note "SNMP status query: unavailable or no IPv4 address resolved"
fi

printf '\n'
if [ -n "$SNMP_SUPPLIES_SUMMARY" ]; then
  note "SNMP supply summary:"
  printf '%s\n' "$SNMP_SUPPLIES_SUMMARY"
else
  note "SNMP supply summary: unavailable"
fi

section "Interpretation"
if [ -n "$PRODUCT_ERROR_LOG" ]; then
  note "Hidden HP errors were found in ProductLogsDyn.xml."
fi

if [ -n "$IPP_STATE_REASONS" ] && [ "$IPP_STATE_REASONS" != "none" ]; then
  note "IPP is reporting an active printer-state-reasons value: $IPP_STATE_REASONS"
fi

if [ -n "$STATUS_CATEGORY" ] && [ "$STATUS_CATEGORY" != "ready" ]; then
  note "HP ProductStatusDyn is not reporting ready: $STATUS_CATEGORY"
fi

if [ -n "$IPP_UPTIME" ] && [ "$IPP_UPTIME" -lt 900 ] 2>/dev/null; then
  note "The printer uptime is only ${IPP_UPTIME}s, which suggests a recent reboot."
fi

if [ -n "$MISPICK_EVENTS" ] && [ "$MISPICK_EVENTS" -gt 0 ] 2>/dev/null; then
  note "The printer has a lifetime history of ${MISPICK_EVENTS} paper mispick events."
fi

if [ -n "$STATUS_MODIFICATION_NUMBER" ] && [ "$STATUS_MODIFICATION_NUMBER" -gt 0 ] 2>/dev/null; then
  note "ProductStatusDyn reports alert-table changes with modification number ${STATUS_MODIFICATION_NUMBER}."
fi

if [ -n "$FW_STATUS" ] && [ "$FW_STATUS" != "idle" ]; then
  note "FirmwareUpdate is not idle: ${FW_STATUS}."
fi

if [ "${CLOUD_HEALTH:-}" = "disabled" ]; then
  note "HP web services are intentionally disabled, so HP Connected/Instant Ink panel prompts should stay cleared."
elif [ -n "$EPRINT_SIGNALING_STATE" ] && [ "$EPRINT_SIGNALING_STATE" != "connected" ]; then
  note "ePrint signaling is not connected: ${EPRINT_SIGNALING_STATE}."
fi

if [ "${CLOUD_HEALTH:-}" != "disabled" ] && [ "$SUBSCRIPTION_CONSUMABLE_COUNT" -gt 0 ] && [ -n "$EPRINT_SIGNALING_STATE" ] && [ "$EPRINT_SIGNALING_STATE" != "connected" ]; then
  note "Instant Ink subscription cartridges are installed, but HP cloud signaling is not fully connected."
fi

if [ -n "$EVENT_TABLE_SUMMARY" ]; then
  note "EventMgmt shows the most recent device-side event categories above."
fi

if [ "$IPP_PROCESSING_JOB_COUNT" -gt 0 ] && [ "$HP_PROCESSING_JOB_COUNT" -gt 0 ] && [ "${IPP_STATE_REASONS:-}" = "spool-area-full-report" ]; then
  note "The printer is still holding at least one print job open internally while reporting spool-area-full-report."
fi

if [ "$IPP_PROCESSING_JOB_COUNT" -gt 0 ] && printf '%s\n' "$QUEUE_DETAIL" | grep -q 'Finished page'; then
  note "CUPS reports a page finished, but the printer still has the job open as processing."
fi

if [ "${IPP_STATE_REASONS:-}" = "none" ] && [ "${STATUS_CATEGORY:-}" = "ready" ]; then
  note "There is no active printer-side fault being reported through CUPS, IPP, or ProductStatusDyn right now."
fi

note "If print jobs still sit in 'printing' for a long time while the checks above remain healthy, the next suspects are network delivery, Bonjour name resolution, or the printer taking a long time to rasterize a specific job."

if [ "$COMMAND" = "repair" ] && [ "$EXPERIMENTAL_CLEAR_JOBS" -eq 1 ]; then
  section "Experimental Actions"
  printf '%b' "$EXPERIMENTAL_ACTION_LOG"
  if [ -n "$POST_ACTION_JOB_LIST_SUMMARY" ] || [ -n "$POST_ACTION_STATUS_CATEGORY" ] || [ -n "$POST_ACTION_IPP_STATE" ]; then
    note "Post-action printer-state: ${POST_ACTION_IPP_STATE:-unknown}"
    note "Post-action printer-state-reasons: ${POST_ACTION_IPP_REASONS:-unknown}"
    note "Post-action queued-job-count: ${POST_ACTION_IPP_QUEUED:-unknown}"
    note "Post-action ProductStatusDyn status-category: ${POST_ACTION_STATUS_CATEGORY:-unknown}"
    if [ -n "$POST_ACTION_JOB_LIST_SUMMARY" ]; then
      note "Post-action Jobs/JobList summary:"
      printf '%s\n' "$POST_ACTION_JOB_LIST_SUMMARY"
    fi
  fi
fi

if [ "$COMMAND" = "repair" ] && [ "$CANCEL_CONNECTING" -eq 1 ]; then
  section "Web Services Action"
  note "PUT /ePrint/ePrintConfigDyn.xml -> ${CANCEL_CONNECTING_HTTP_CODE:-unknown}"
  note "Pre-action ProductStatusDyn status-category: $(extract_tag_value "$CANCEL_CONNECTING_PRE_STATUS_XML" "pscat:StatusCategory")"
  note "Post-action ProductStatusDyn status-category: $(extract_tag_value "$CANCEL_CONNECTING_POST_STATUS_XML" "pscat:StatusCategory")"
  note "Pre-action ePrint registration-state: $(extract_tag_value "$CANCEL_CONNECTING_PRE_CONFIG_XML" "ep:RegistrationState")"
  note "Post-action ePrint registration-state: $(extract_tag_value "$CANCEL_CONNECTING_POST_CONFIG_XML" "ep:RegistrationState")"
  note "Pre-action ConsumableSubscription status: $(extract_tag_value "$CANCEL_CONNECTING_PRE_SUBSCRIPTION_XML" "cs:Status")"
  note "Post-action ConsumableSubscription status: $(extract_tag_value "$CANCEL_CONNECTING_POST_SUBSCRIPTION_XML" "cs:Status")"
fi

if [ "$MONITOR_PRINTING" -eq 1 ]; then
  local_seen_active=0

  section "During Printing Monitor"
  note "Sampling every ${MONITOR_INTERVAL}s for up to ${MONITOR_SAMPLES} samples."

  sample_index=1
  while [ "$sample_index" -le "$MONITOR_SAMPLES" ]; do
    capture_monitor_sample "$sample_index"

    if [ "$MONITOR_LAST_ACTIVE" -eq 1 ]; then
      local_seen_active=1
    fi

    if [ "$sample_index" -eq 1 ] && [ "$local_seen_active" -eq 0 ]; then
      note "Monitor stopping because no active print job was detected on the first sample."
      break
    fi

    if [ "$local_seen_active" -eq 1 ] && [ "$MONITOR_LAST_ACTIVE" -eq 0 ]; then
      note "Monitor stopping early because the printer returned to idle after an active print state."
      break
    fi

    if [ "$sample_index" -lt "$MONITOR_SAMPLES" ]; then
      sleep "$MONITOR_INTERVAL"
    fi

    sample_index=$((sample_index + 1))
  done
fi
