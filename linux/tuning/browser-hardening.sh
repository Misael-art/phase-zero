#!/usr/bin/env bash
# browser-hardening.sh - privacy/security hardening (apply | revert | status)
set -euo pipefail
PZ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PZ_ROOT/linux/lib/common.sh"
source "$PZ_ROOT/linux/tuning/tune-common.sh"

pz_tune_init browser "$@"

pz_harden_firefox() {
    local profile_dir userjs
    # shellcheck disable=SC2012
    profile_dir=$(ls -d ~/.mozilla/firefox/*.default-release 2>/dev/null | head -1)
    # shellcheck disable=SC2012
    [ -z "$profile_dir" ] && profile_dir=$(ls -d ~/.mozilla/firefox/*.default 2>/dev/null | head -1)
    [ -z "$profile_dir" ] && { pz_warn "no firefox profile found"; return 0; }

    userjs="$profile_dir/user.js"
    pz_tune_file "$userjs" user <<'EOF'
// PhaseZero Firefox Hardening
// Privacy & security preferences
user_pref("privacy.trackingprotection.fingerprinting.enabled", true);
user_pref("privacy.trackingprotection.cryptomining.enabled", true);
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.resistFingerprinting", false); // breaks some sites
user_pref("privacy.firstparty.isolate", true);
user_pref("privacy.webrtc.allow_old_tls_ciphers", false);
user_pref("media.peerconnection.enabled", false);
user_pref("geo.enabled", false);
user_pref("geo.provider.use_corelocation", false);
user_pref("geo.provider.network.url", "");
user_pref("browser.region.network.url", "");
user_pref("browser.region.update.enabled", false);
user_pref("browser.send_pings", false);
user_pref("dom.event.clipboardevents.enabled", false);
user_pref("webgl.disabled", false);
user_pref("xpinstall.signatures.required", true);
user_pref("extensions.webservice.discoverURL", "");
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
user_pref("browser.newtabpage.activity-stream.feeds.snippets", false);
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.prerender", false);
user_pref("browser.newtabpage.enhanced", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("devtools.onboarding.telemetry.logged", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.bhrPing.enabled", false);
user_pref("toolkit.telemetry.cachedClientID", "");
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
user_pref("toolkit.telemetry.hybridContent.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.safebrowsing.downloads.remote.enabled", true);
user_pref("browser.safebrowsing.malware.enabled", true);
user_pref("browser.safebrowsing.phishing.enabled", true);
EOF
    pz_info "firefox hardened: $userjs"
}

pz_harden_chromium() {
    local config_dir="${HOME}/.config/chromium" policies_dir
    [ ! -d "$config_dir" ] && config_dir="${HOME}/.config/google-chrome"
    [ ! -d "$config_dir" ] && { pz_warn "no chrome/chromium profile found"; return 0; }

    policies_dir="$config_dir/Default/policies/managed"
    pz_tune_file "$policies_dir/phasezero-hardening.json" user <<'EOF'
{
  "BlockThirdPartyCookies": true,
  "DoNotTrackEnabled": true,
  "MetricsReportingEnabled": false,
  "PasswordManagerEnabled": false,
  "SafeBrowsingEnabled": true,
  "SafeBrowsingExtendedReportingEnabled": false,
  "SearchSuggestEnabled": false,
  "SpellCheckServiceEnabled": false,
  "UrlKeyedAnonymizedDataCollectionEnabled": false,
  "ChromeVariations": 1,
  "BuiltInDnsClientEnabled": false,
  "PrivacySandboxPromptEnabled": false,
  "PrivacySandboxAdMeasurementEnabled": false,
  "PrivacySandboxAdPersonalizationEnabled": false,
  "PrivacySandboxAdTopicsEnabled": false,
  "WebRtcUdpPortRange": {
    "UdpPortMin": 32768,
    "UdpPortMax": 60999
  }
}
EOF
    pz_info "chromium/chrome hardened via policies: $policies_dir"
}

pz_tune_apply() {
    pz_harden_firefox
    pz_harden_chromium
    pz_info "browser hardening complete"
}

pz_tune_main
