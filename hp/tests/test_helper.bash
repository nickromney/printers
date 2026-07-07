#!/usr/bin/env bash

setup_mock_printer_env() {
  local helper_dir
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  export SCRIPT_UNDER_TEST="${helper_dir%/tests}/diagnostics.sh"
  export REPAIR_SCRIPT_UNDER_TEST="${helper_dir%/tests}/repair.sh"
  export PROVE_PRINT_UNDER_TEST="${helper_dir%/tests}/prove-print.sh"
  export LUCKY_UNDER_TEST="${helper_dir%/tests}/lucky.sh"
  TEST_ROOT="$(mktemp -d "${BATS_TEST_TMPDIR}/mock-printer.XXXXXX")"
  export TEST_ROOT
  export MOCK_BIN="${TEST_ROOT}/bin"
  export MOCK_STATE_DIR="${TEST_ROOT}/state"
  export MOCK_OUTPUT_DIR="${TEST_ROOT}/output"
  if [ -z "${BASE_PATH:-}" ]; then
    BASE_PATH="$(getconf PATH 2>/dev/null || printf '%s' '/usr/bin:/bin:/usr/sbin:/sbin')"
    case ":$BASE_PATH:" in
      *:/opt/homebrew/bin:*)
        ;;
      *)
        BASE_PATH="${BASE_PATH}:/opt/homebrew/bin:/opt/homebrew/sbin"
        ;;
    esac
    export BASE_PATH
  fi

  mkdir -p "$MOCK_BIN" "$MOCK_STATE_DIR" "$MOCK_OUTPUT_DIR"

  export PATH="$MOCK_BIN:$BASE_PATH"
  export MOCK_PRINTER_STATE_DIR="$MOCK_STATE_DIR"
  export CUPS_ERROR_LOG_PATH="${MOCK_STATE_DIR}/cups-error.log"

  : > "$CUPS_ERROR_LOG_PATH"
  printf 'clean\n' > "${MOCK_STATE_DIR}/product_logs_mode"
  printf 'completed\n' > "${MOCK_STATE_DIR}/job_list_mode"
  printf 'registered\n' > "${MOCK_STATE_DIR}/eprint_mode"
  printf 'warning\n' > "${MOCK_STATE_DIR}/status_mode"
  printf 'connectNowWarning\n' > "${MOCK_STATE_DIR}/subscription_status"

  create_mock_lpstat
  create_mock_dns_sd
  create_mock_ipptool
  create_mock_snmpget
  create_mock_snmpwalk
  create_mock_sleep
  create_mock_nc
  create_mock_curl
  create_mock_lp
}

assert_output_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]]
}

assert_output_not_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" != *"$needle"* ]]
}

assert_output_equals_file() {
  local haystack="$1"
  local file="$2"

  diff -u "$file" <(printf '%s\n' "$haystack")
}

assert_file_contains() {
  local file="$1"
  local needle="$2"

  grep -Fq -- "$needle" "$file"
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"

  ! grep -Fq -- "$needle" "$file"
}

assert_file_not_exists() {
  local file="$1"

  [ ! -e "$file" ]
}

create_mock_lpstat() {
  cat > "${MOCK_BIN}/lpstat" <<'EOF'
#!/usr/bin/env bash
set -eu

queue="HP_Test_Series__ABC123_"

case "$*" in
  "-d")
    printf 'system default destination: %s\n' "$queue"
    ;;
  "-p")
    printf 'printer %s is idle.  enabled since Sun Mar 22 21:17:15 2026\n' "$queue"
    ;;
  "-p -d -v")
    cat <<OUT
printer $queue is idle.  enabled since Sun Mar 22 21:17:15 2026
system default destination: $queue
device for $queue: dnssd://HP%20Test%20Series%20%5BABC123%5D._ipp._tcp.local./?uuid=11111111-2222-3333-4444-555555555555
OUT
    ;;
  "-l -p HP_Test_Series__ABC123_")
    cat <<OUT
printer $queue is idle.  enabled since Sun Mar 22 21:17:15 2026
	Form mounted:
	Content types: any
	Printer types: unknown
	Description: HP Test Series [ABC123]
	Alerts: none
	Location:
	Connection: direct
	Interface: /private/etc/cups/ppd/${queue}.ppd
	On fault: no alert
	After fault: continue
OUT
    ;;
  "-W all -o HP_Test_Series__ABC123_"|"-W not-completed -o HP_Test_Series__ABC123_")
    exit 0
    ;;
  *)
    printf 'unexpected lpstat args: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${MOCK_BIN}/lpstat"
}

create_mock_dns_sd() {
  cat > "${MOCK_BIN}/dns-sd" <<'EOF'
#!/usr/bin/env bash
set -eu

case "${1:-}" in
  -L)
    printf 'DATE: ---  HP Test Series [ABC123]._ipp._tcp.local. can be reached at hp-test-printer.local.:631 (interface 12)\n'
    ;;
  -G)
    printf 'Timestamp A/R Flags if Hostname Address TTL\n'
    printf '21:18:29 Add 2 3 hp-test-printer.local. 192.0.2.25 120\n'
    ;;
  *)
    printf 'unexpected dns-sd args: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${MOCK_BIN}/dns-sd"
}

create_mock_ipptool() {
  cat > "${MOCK_BIN}/ipptool" <<'EOF'
#!/usr/bin/env bash
set -eu

case "${3:-}" in
  */get-printer-attributes.test)
    cat <<OUT
    printer-state (enum) = idle
    printer-state-reasons (keyword) = none
    printer-is-accepting-jobs (boolean) = true
    queued-job-count (integer) = 0
    printer-up-time (integer) = 1234
    printer-alert-description (textWithoutLanguage) = ready
    printer-alert (textWithoutLanguage) = printerReadyToPrint
    marker-names (nameWithoutLanguage) = tri-color ink,black ink
    marker-levels (integer) = 40,40
OUT
    ;;
  */get-jobs.test)
    exit 0
    ;;
  *)
    printf 'unexpected ipptool args: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${MOCK_BIN}/ipptool"
}

create_mock_snmpget() {
  cat > "${MOCK_BIN}/snmpget" <<'EOF'
#!/usr/bin/env bash
set -eu

cat <<OUT
HOST-RESOURCES-MIB::hrPrinterStatus.1 = INTEGER: idle(3)
HOST-RESOURCES-MIB::hrPrinterDetectedErrorState.1 = Hex-STRING: 00
OUT
EOF
  chmod +x "${MOCK_BIN}/snmpget"
}

create_mock_snmpwalk() {
  cat > "${MOCK_BIN}/snmpwalk" <<'EOF'
#!/usr/bin/env bash
set -eu

cat <<OUT
iso.3.6.1.2.1.43.11.1.1.6.1.1 = STRING: "black ink cartridge"
iso.3.6.1.2.1.43.11.1.1.9.1.1 = INTEGER: 35
iso.3.6.1.2.1.43.11.1.1.6.1.2 = STRING: "tri-color ink cartridge"
iso.3.6.1.2.1.43.11.1.1.9.1.2 = INTEGER: 44
OUT
EOF
  chmod +x "${MOCK_BIN}/snmpwalk"
}

create_mock_sleep() {
  cat > "${MOCK_BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-0}" = "0" ]; then
  exit 0
fi

/bin/sleep 0.01
EOF
  chmod +x "${MOCK_BIN}/sleep"
}

create_mock_nc() {
  cat > "${MOCK_BIN}/nc" <<'EOF'
#!/usr/bin/env bash
set -eu

state_dir="${MOCK_PRINTER_STATE_DIR:?}"
printf '%s\n' "$*" > "${state_dir}/last_nc_args.txt"
cat > "${state_dir}/last_nc_payload.txt"
exit 0
EOF
  chmod +x "${MOCK_BIN}/nc"
}

create_mock_lp() {
  cat > "${MOCK_BIN}/lp" <<'EOF'
#!/usr/bin/env bash
set -eu

state_dir="${MOCK_PRINTER_STATE_DIR:?}"
dest=""
input_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      shift
      dest="$1"
      shift
      ;;
    -*)
      shift
      ;;
    *)
      input_file="$1"
      shift
      ;;
  esac
done

if [ -n "$input_file" ] && [ -f "$input_file" ]; then
  cp "$input_file" "${state_dir}/last_lp_file.ps"
fi

printf '%s\n' "$dest" > "${state_dir}/last_lp_dest.txt"
printf 'request id is %s-1 (1 file(s))\n' "${dest:-unknown}"
exit 0
EOF
  chmod +x "${MOCK_BIN}/lp"
}

create_mock_curl() {
  cat > "${MOCK_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
set -eu

state_dir="${MOCK_PRINTER_STATE_DIR:?}"
method="GET"
output_file=""
write_out=""
data=""
url=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -s|-S|-sS|-k|-i)
      shift
      ;;
    --max-time|-H|-o|-w|-X|--data-binary)
      option="$1"
      shift
      [ "$#" -gt 0 ] || exit 2
      value="$1"
      shift
      case "$option" in
        -o)
          output_file="$value"
          ;;
        -w)
          write_out="$value"
          ;;
        -X)
          method="$value"
          ;;
        --data-binary)
          data="$value"
          ;;
      esac
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

case "$url" in
  http://*)
    trimmed="${url#http://}"
    ;;
  https://*)
    trimmed="${url#https://}"
    ;;
  *)
    printf 'unsupported url: %s\n' "$url" >&2
    exit 2
    ;;
esac

if [ "$trimmed" = "${trimmed#*/}" ]; then
  path="/"
else
  path="/${trimmed#*/}"
fi

render_discovery_tree() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ledm:DiscoveryTree xmlns:ledm="http://www.hp.com/schemas/imaging/con/ledm/discovery/2009/02/01" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ProductStatusDyn.xml</dd:ResourceURI></ledm:SupportedTree>
  <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ProductLogsDyn.xml</dd:ResourceURI></ledm:SupportedTree>
  <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ProductUsageDyn.xml</dd:ResourceURI></ledm:SupportedTree>
  <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ConsumableConfigDyn.xml</dd:ResourceURI></ledm:SupportedTree>
  <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ProductConfigDyn.xml</dd:ResourceURI></ledm:SupportedTree>
</ledm:DiscoveryTree>
XML
}

render_product_status() {
  status_mode="$(cat "${state_dir}/status_mode")"
  if [ "$status_mode" = "warning" ]; then
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<psdyn:ProductStatusDyn xmlns:psdyn="http://www.hp.com/schemas/imaging/con/ledm/productstatusdyn/2007/10/31" xmlns:pscat="http://www.hp.com/schemas/imaging/con/ledm/productstatuscategories/2007/10/31" xmlns:locid="http://www.hp.com/schemas/imaging/con/ledm/localizationids/2007/10/31" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:ad="http://www.hp.com/schemas/imaging/con/ledm/alertdetails/2007/10/31">
  <psdyn:Status>
    <pscat:StatusCategory>subscribedPagesLow</pscat:StatusCategory>
    <locid:StringId>65737</locid:StringId>
  </psdyn:Status>
  <psdyn:Status>
    <pscat:StatusCategory>ready</pscat:StatusCategory>
    <locid:StringId>65638</locid:StringId>
  </psdyn:Status>
  <psdyn:AlertTable>
    <dd:ModificationNumber>3</dd:ModificationNumber>
    <psdyn:Alert>
      <ad:ProductStatusAlertID>subscribedPagesLow</ad:ProductStatusAlertID>
      <ad:AlertDetails>
        <ad:AlertDetailsUserAction>pressOK</ad:AlertDetailsUserAction>
        <ad:AlertDetailsSubscriptionError>notConnected</ad:AlertDetailsSubscriptionError>
        <ad:AlertDetailsLocation>HP Connected</ad:AlertDetailsLocation>
      </ad:AlertDetails>
    </psdyn:Alert>
  </psdyn:AlertTable>
</psdyn:ProductStatusDyn>
XML
  else
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<psdyn:ProductStatusDyn xmlns:psdyn="http://www.hp.com/schemas/imaging/con/ledm/productstatusdyn/2007/10/31" xmlns:pscat="http://www.hp.com/schemas/imaging/con/ledm/productstatuscategories/2007/10/31" xmlns:locid="http://www.hp.com/schemas/imaging/con/ledm/localizationids/2007/10/31" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <psdyn:Status>
    <pscat:StatusCategory>ready</pscat:StatusCategory>
    <locid:StringId>65638</locid:StringId>
  </psdyn:Status>
  <psdyn:AlertTable>
    <dd:ModificationNumber>6</dd:ModificationNumber>
  </psdyn:AlertTable>
</psdyn:ProductStatusDyn>
XML
  fi
}

render_product_logs() {
  product_logs_mode="$(cat "${state_dir}/product_logs_mode")"
  if [ "$product_logs_mode" = "single-line-error" ]; then
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<pldyn:ProductLogsDyn xmlns:pldyn="http://www.hp.com/schemas/imaging/con/ledm/productlogsdyn/2009/03/31" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <pldyn:Event>
    <dd:SequenceNumber>131585</dd:SequenceNumber>
    <dd:EventOccurrences>1</dd:EventOccurrences>
    <dd:EventCode>74899</dd:EventCode>
  </pldyn:Event>
  <pldyn:ErrorLog>paper jam &amp; cover open</pldyn:ErrorLog>
</pldyn:ProductLogsDyn>
XML
    return
  fi

  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<pldyn:ProductLogsDyn xmlns:pldyn="http://www.hp.com/schemas/imaging/con/ledm/productlogsdyn/2009/03/31" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <pldyn:Event>
    <dd:SequenceNumber>131585</dd:SequenceNumber>
    <dd:EventOccurrences>1</dd:EventOccurrences>
    <dd:EventCode>74899</dd:EventCode>
  </pldyn:Event>
</pldyn:ProductLogsDyn>
XML
}

render_product_usage() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<usage:ProductUsageDyn xmlns:usage="http://www.hp.com/schemas/imaging/con/ledm/productusagedyn/2007/10/31" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <dd:TotalImpressions>12981</dd:TotalImpressions>
  <dd:DuplexSheets>1236</dd:DuplexSheets>
  <dd:JamEvents>0</dd:JamEvents>
  <dd:MispickEvents>66</dd:MispickEvents>
  <dd:WirelessNetworkImpressions>8450</dd:WirelessNetworkImpressions>
</usage:ProductUsageDyn>
XML
}

render_consumable_config() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ccdyn:ConsumableConfigDyn xmlns:ccdyn="http://www.hp.com/schemas/imaging/con/ledm/consumableconfigdyn/2007/11/19" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <ccdyn:ConsumableInfo>
    <dd:ConsumableLabelCode>CMY</dd:ConsumableLabelCode>
    <dd:ConsumablePercentageLevelRemaining>40</dd:ConsumablePercentageLevelRemaining>
    <dd:ConsumableState>ok</dd:ConsumableState>
    <dd:MeasuredQuantityState>newGenuineHP</dd:MeasuredQuantityState>
    <dd:IsSubscription>true</dd:IsSubscription>
  </ccdyn:ConsumableInfo>
  <ccdyn:ConsumableInfo>
    <dd:ConsumableLabelCode>K</dd:ConsumableLabelCode>
    <dd:ConsumablePercentageLevelRemaining>40</dd:ConsumablePercentageLevelRemaining>
    <dd:ConsumableState>ok</dd:ConsumableState>
    <dd:MeasuredQuantityState>newGenuineHP</dd:MeasuredQuantityState>
    <dd:IsSubscription>true</dd:IsSubscription>
  </ccdyn:ConsumableInfo>
  <ccdyn:MarkingAgentSubscriptionLevel>1</ccdyn:MarkingAgentSubscriptionLevel>
</ccdyn:ConsumableConfigDyn>
XML
}

render_product_config() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<prdcfgdyn:ProductConfigDyn xmlns:prdcfgdyn="http://www.hp.com/schemas/imaging/con/ledm/productconfigdyn/2009/11/16" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <prdcfgdyn:ProductInformation>
    <dd:Revision>MKM1FN2025AR</dd:Revision>
    <dd:Date>2020-06-15</dd:Date>
  </prdcfgdyn:ProductInformation>
  <dd:ServiceID>24149</dd:ServiceID>
  <dd:TimeStamp>2000-01-01T00:00:01</dd:TimeStamp>
  <dd:PowerSave>on</dd:PowerSave>
</prdcfgdyn:ProductConfigDyn>
XML
}

render_netapps() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<nadyn:NetAppsDyn xmlns:nadyn="http://www.hp.com/schemas/imaging/con/ledm/netappdyn/2009/06/24" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:dd3="http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06">
  <nadyn:DNSSDConfig>
    <dd3:DomainName>hp-test-printer.local.</dd3:DomainName>
  </nadyn:DNSSDConfig>
  <nadyn:ProxyConfig>
    <dd:ResourceURI></dd:ResourceURI>
    <dd:Port>0</dd:Port>
  </nadyn:ProxyConfig>
</nadyn:NetAppsDyn>
XML
}

render_security() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<security:SecurityDyn xmlns:security="http://www.hp.com/schemas/imaging/con/ledm/securitydyn/2009/08/12">
  <security:State>off</security:State>
</security:SecurityDyn>
XML
}

render_firmware_update_state() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<fwudyn:WebFWUpdateState xmlns:fwudyn="http://www.hp.com/schemas/imaging/con/ledm/firmwareupdatedyn/2009/03/16">
  <fwudyn:Status>idle</fwudyn:Status>
</fwudyn:WebFWUpdateState>
XML
}

render_firmware_update_config() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<fwudyn:WebFWUpdateConfig xmlns:fwudyn="http://www.hp.com/schemas/imaging/con/ledm/firmwareupdatedyn/2009/03/16">
  <fwudyn:AutomaticCheck>disabled</fwudyn:AutomaticCheck>
  <fwudyn:AutomaticUpdate>enabled</fwudyn:AutomaticUpdate>
</fwudyn:WebFWUpdateConfig>
XML
}

render_claim_status() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ep:ClaimStatus xmlns:ep="http://www.hp.com/schemas/imaging/con/eprint/2010/04/30">
  <ep:Status>idle</ep:Status>
</ep:ClaimStatus>
XML
}

render_eprint_config() {
  eprint_mode="$(cat "${state_dir}/eprint_mode")"
  if [ "$eprint_mode" = "disabled" ]; then
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ep:ePrintConfigDyn xmlns:ep="http://www.hp.com/schemas/imaging/con/eprint/2010/04/30" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
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
  <dd:DeviceWebServicesURI>#hId-pgePrintOptIn</dd:DeviceWebServicesURI>
  <ep:SignalingConnectionState>disconnected</ep:SignalingConnectionState>
</ep:ePrintConfigDyn>
XML
  else
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ep:ePrintConfigDyn xmlns:ep="http://www.hp.com/schemas/imaging/con/eprint/2010/04/30" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dd:Version>
    <dd:Revision>SVN-IPG-LEDM.533</dd:Revision>
    <dd:Date>2012-08-29</dd:Date>
  </dd:Version>
  <ep:CloudConfiguration>
    <ep:EmailService>enabled</ep:EmailService>
    <ep:SipService>enabled</ep:SipService>
    <ep:MobileAppsService>enabled</ep:MobileAppsService>
  </ep:CloudConfiguration>
  <ep:RegistrationState>registered</ep:RegistrationState>
  <ep:XMPPConnectionState>connected</ep:XMPPConnectionState>
  <ep:PrinterID>xik6f0nisp6c-cm-cez4cg</ep:PrinterID>
  <ep:BeaconState>enabled</ep:BeaconState>
  <dd:DeviceWebServicesURI>#hId-pgWebServicesSetup</dd:DeviceWebServicesURI>
  <ep:SignalingConnectionState>disconnected</ep:SignalingConnectionState>
</ep:ePrintConfigDyn>
XML
  fi
}

render_subscription_info() {
  subscription_status="$(cat "${state_dir}/subscription_status")"
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<cs:ConsumableSubscriptionInfo xmlns:cs="http://www.hp.com/schemas/imaging/con/ledm/consumablesubscription/2012/06/18" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <cs:Name>Hy:Gem1</cs:Name>
  <cs:Status>${subscription_status}</cs:Status>
  <cs:ConnectionURLs>
    <cs:HPWeb>www.hpconnected.com</cs:HPWeb>
    <cs:InstantInk>www.hpinstantink.com</cs:InstantInk>
    <cs:InstantInkSupport>www.hpconnected.com/support/ink</cs:InstantInkSupport>
  </cs:ConnectionURLs>
  <cs:DeviceLastConnectionData>
    <cs:SequenceNumber>1909</cs:SequenceNumber>
    <cs:ReceivedDate>2026-03-22</cs:ReceivedDate>
    <cs:ConnectionDate>2026-03-22</cs:ConnectionDate>
  </cs:DeviceLastConnectionData>
  <cs:CurrentSequenceNumber>1909</cs:CurrentSequenceNumber>
  <cs:OutOfPagesExtensionAvailable>true</cs:OutOfPagesExtensionAvailable>
  <cs:EffectiveOutOfPages>13159</cs:EffectiveOutOfPages>
</cs:ConsumableSubscriptionInfo>
XML
}

render_event_table() {
  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ev:EventTable xmlns:ev="http://www.hp.com/schemas/imaging/con/ledm/events/2007/09/16" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
  <ev:Event>
    <dd:UnqualifiedEventCategory>JobEvent</dd:UnqualifiedEventCategory>
    <dd:AgingStamp>239-48</dd:AgingStamp>
  </ev:Event>
</ev:EventTable>
XML
}

render_job_list() {
  job_list_mode="$(cat "${state_dir}/job_list_mode")"
  if [ "$job_list_mode" = "processing" ]; then
    cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<j:JobList xmlns:j="http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30">
  <j:Job>
    <j:JobUrl>/Jobs/JobList/10</j:JobUrl>
    <j:JobCategory>Print</j:JobCategory>
    <j:JobState>Processing</j:JobState>
    <j:JobStateUpdate>239-99</j:JobStateUpdate>
  </j:Job>
</j:JobList>
XML
    return
  fi

  cat <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<j:JobList xmlns:j="http://www.hp.com/schemas/imaging/con/ledm/jobs/2009/04/30">
  <j:Job>
    <j:JobUrl>/Jobs/JobList/10</j:JobUrl>
    <j:JobCategory>Print</j:JobCategory>
    <j:JobState>Completed</j:JobState>
    <j:JobStateUpdate>239-42</j:JobStateUpdate>
  </j:Job>
</j:JobList>
XML
}

if [ "$method" = "PUT" ] && [ "$path" = "/ePrint/ePrintConfigDyn.xml" ]; then
  printf '%s' "$data" > "${state_dir}/last_eprint_put_payload.xml"
  printf 'disabled\n' > "${state_dir}/eprint_mode"
  printf 'ready\n' > "${state_dir}/status_mode"
  printf 'active\n' > "${state_dir}/subscription_status"
  if [ -n "$output_file" ]; then
    : > "$output_file"
  fi
  if [ -n "$write_out" ]; then
    printf '200'
  fi
  exit 0
fi

if [ "$method" = "PUT" ] && [ "${path#/Jobs/JobList/}" != "$path" ]; then
  printf '%s' "$data" > "${state_dir}/last_job_cancel_payload.xml"
  printf 'completed\n' > "${state_dir}/job_list_mode"
  if [ -n "$output_file" ]; then
    : > "$output_file"
  fi
  if [ -n "$write_out" ]; then
    printf '200'
  fi
  exit 0
fi

case "$path" in
  /DevMgmt/DiscoveryTree.xml)
    body="$(render_discovery_tree)"
    ;;
  /DevMgmt/ProductStatusDyn.xml)
    body="$(render_product_status)"
    ;;
  /DevMgmt/ProductLogsDyn.xml)
    body="$(render_product_logs)"
    ;;
  /DevMgmt/ProductUsageDyn.xml)
    body="$(render_product_usage)"
    ;;
  /DevMgmt/ConsumableConfigDyn.xml)
    body="$(render_consumable_config)"
    ;;
  /DevMgmt/ProductConfigDyn.xml)
    body="$(render_product_config)"
    ;;
  /DevMgmt/NetAppsDyn.xml)
    body="$(render_netapps)"
    ;;
  /DevMgmt/SecurityDyn.xml)
    body="$(render_security)"
    ;;
  /FirmwareUpdate/FirmwareUpdateDyn.xml)
    body=""
    ;;
  /FirmwareUpdate/WebFWUpdate/State)
    body="$(render_firmware_update_state)"
    ;;
  /FirmwareUpdate/WebFWUpdate/Config)
    body="$(render_firmware_update_config)"
    ;;
  /ePrint/ePrintConfigDyn.xml)
    body="$(render_eprint_config)"
    ;;
  /ePrint/ClaimStatus)
    body="$(render_claim_status)"
    ;;
  /ePrint/ConnectionStateReason)
    body=""
    ;;
  /ConsumableSubscription/Info)
    body="$(render_subscription_info)"
    ;;
  /EventMgmt/EventTable)
    body="$(render_event_table)"
    ;;
  /Jobs/JobList)
    body="$(render_job_list)"
    ;;
  *)
    printf 'unexpected curl path: %s\n' "$path" >&2
    exit 1
    ;;
esac

if [ -n "$output_file" ]; then
  printf '%s' "$body" > "$output_file"
fi

if [ -z "$write_out" ]; then
  printf '%s' "$body"
fi
EOF
  chmod +x "${MOCK_BIN}/curl"
}
