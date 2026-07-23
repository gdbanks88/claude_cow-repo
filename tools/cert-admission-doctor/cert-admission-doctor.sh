#!/usr/bin/env bash
#
# cert-admission-doctor.sh
#
# Read-only diagnostic for "my soft (PKCS#12) client cert used to work, but after
# a server/app upgrade it is no longer accepted / no longer appears in the browser's
# certificate picker."
#
# It inspects every layer that decides whether a client certificate is OFFERED and
# ACCEPTED, and prints a ranked list of likely causes with concrete mitigations.
# It NEVER changes anything — no config edits, no service restarts, no key material
# written to disk. Passwords are read from an env var or an interactive prompt and
# are never echoed or logged.
#
# Core idea: a browser only offers a client cert whose ISSUER is in the acceptable-CA
# list the SERVER advertises in its TLS CertificateRequest. So the #1 check is:
# "what CA names does the server actually advertise, and is your cert's issuer in it?"
#
# Usage:
#   cert-admission-doctor.sh [--connect HOST:PORT] [--p12 FILE|DIR]
#                            [--p12-pass-env VAR] [--server auto|nginx|apache|haproxy]
#                            [--servername NAME] [--no-probe]
#
# Examples:
#   # Full run: probe the live endpoint and inspect a soft cert
#   ./cert-admission-doctor.sh --connect app.example.com:443 --p12 ~/mycert.p12
#
#   # Just find out what the server advertises (no cert on hand)
#   ./cert-admission-doctor.sh --connect app.example.com:443
#
#   # Inspect config + a directory of .p12/.pfx files, no network probe
#   ./cert-admission-doctor.sh --p12 /etc/pki/soft-certs --no-probe
#
# Exit status: 0 if it ran (findings are printed regardless); non-zero only on
# a usage error or if no diagnostic input was available at all.

set -uo pipefail

# ----------------------------------------------------------------------------
# Presentation helpers
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; C=$'\033[36m'; Z=$'\033[0m'
else
  B=''; R=''; Y=''; G=''; C=''; Z=''
fi
hr() { printf '%s\n' "----------------------------------------------------------------------"; }
h1() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
kv() { printf '  %-28s %s\n' "$1" "$2"; }
info() { printf '  %s\n' "$1"; }
warn() { printf '  %s! %s%s\n' "$Y" "$1" "$Z"; }

# Findings are stored as: SEVERITY|TITLE|EVIDENCE|MITIGATION
# SEVERITY: 1=critical (best explanation), 2=likely, 3=worth-checking, 4=info
FINDINGS=()
add_finding() { FINDINGS+=("$1|$2|$3|$4"); }

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
CONNECT=""; P12_PATH=""; P12_PASS_ENV=""; SERVER="auto"; SERVERNAME=""; DO_PROBE=1
usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --connect) CONNECT="${2:-}"; shift 2;;
    --p12) P12_PATH="${2:-}"; shift 2;;
    --p12-pass-env) P12_PASS_ENV="${2:-}"; shift 2;;
    --server) SERVER="${2:-auto}"; shift 2;;
    --servername) SERVERNAME="${2:-}"; shift 2;;
    --no-probe) DO_PROBE=0; shift;;
    -h|--help) usage 0;;
    *) echo "Unknown argument: $1" >&2; usage 2;;
  esac
done
[ -n "$CONNECT" ] || DO_PROBE=0
if [ -z "$CONNECT" ] && [ -z "$P12_PATH" ] && [ "$SERVER" = "auto" ]; then
  : # still useful: will at least report the local server config it can find
fi

have() { command -v "$1" >/dev/null 2>&1; }
OPENSSL="$(command -v openssl || true)"

printf '%scert-admission-doctor%s  (read-only)\n' "$B" "$Z"
hr

# ----------------------------------------------------------------------------
# 1. Crypto environment
# ----------------------------------------------------------------------------
OSSL_VER=""; OSSL_MAJOR=0; LEGACY_AVAILABLE=0; LEGACY_LOADED=0
h1 "Crypto environment"
if [ -n "$OPENSSL" ]; then
  OSSL_VER="$("$OPENSSL" version 2>/dev/null)"
  OSSL_MAJOR="$(printf '%s' "$OSSL_VER" | sed -n 's/^OpenSSL \([0-9]\).*/\1/p')"
  OSSL_MAJOR="${OSSL_MAJOR:-0}"
  kv "openssl" "$OSSL_VER"
  if [ "$OSSL_MAJOR" -ge 3 ]; then
    provs="$("$OPENSSL" list -providers 2>/dev/null)"
    printf '%s' "$provs" | grep -qi 'legacy' && LEGACY_LOADED=1
    # Is the legacy provider available to be loaded, even if not active now?
    if "$OPENSSL" list -providers -provider legacy >/dev/null 2>&1; then LEGACY_AVAILABLE=1; fi
    kv "legacy provider" "$([ "$LEGACY_LOADED" = 1 ] && echo 'loaded by default' || { [ "$LEGACY_AVAILABLE" = 1 ] && echo 'available (not default)' || echo 'NOT available'; })"
    kv "default cnf" "${OPENSSL_CONF:-$("$OPENSSL" version -d 2>/dev/null | sed 's/OPENSSLDIR: //; s/"//g')/openssl.cnf}"
  fi
else
  warn "openssl not found on PATH — cert/probe inspection will be limited. Install it: apt install openssl / yum install openssl"
fi
have java && kv "java" "$(java -version 2>&1 | head -1)"

# ----------------------------------------------------------------------------
# 2. Detect the web/proxy server + pull client-cert-relevant config
# ----------------------------------------------------------------------------
detect_server() {
  [ "$SERVER" != "auto" ] && { echo "$SERVER"; return; }
  if pgrep -x nginx >/dev/null 2>&1 || have nginx; then echo nginx; return; fi
  if pgrep -x httpd >/dev/null 2>&1 || pgrep -x apache2 >/dev/null 2>&1 || have apache2 || have httpd; then echo apache; return; fi
  if pgrep -x haproxy >/dev/null 2>&1 || have haproxy; then echo haproxy; return; fi
  echo unknown
}

# grep helper that is quiet about missing dirs
cfgrep() { grep -RInE "$1" $2 2>/dev/null; }

inspect_nginx() {
  h1 "nginx client-certificate configuration"
  local files="/etc/nginx"
  have nginx && info "version: $(nginx -v 2>&1 | sed 's/.*: //')"
  local vc cc tc vd proto
  vc="$(cfgrep '^\s*ssl_verify_client' "$files")"
  cc="$(cfgrep '^\s*ssl_client_certificate' "$files")"
  tc="$(cfgrep '^\s*ssl_trusted_certificate' "$files")"
  vd="$(cfgrep '^\s*ssl_verify_depth' "$files")"
  proto="$(cfgrep '^\s*ssl_protocols' "$files")"
  printf '%s\n' "  ssl_verify_client:"      ; [ -n "$vc" ] && printf '    %s\n' $vc || info "    (not set — default 'off': NO client cert is requested)"
  printf '%s\n' "  ssl_client_certificate (advertised to client as acceptable CA):"; [ -n "$cc" ] && printf '    %s\n' "$cc" || warn "  (not set — nginx advertises NO acceptable CA names; browsers may offer nothing)"
  printf '%s\n' "  ssl_trusted_certificate (verifies but NOT advertised):"; [ -n "$tc" ] && printf '    %s\n' "$tc" || info "    (not set)"
  [ -n "$vd" ] && { printf '%s\n' "  ssl_verify_depth:"; printf '    %s\n' "$vd"; }
  [ -n "$proto" ] && { printf '%s\n' "  ssl_protocols:"; printf '    %s\n' "$proto"; }

  # The signature regression: CA present only in trusted_certificate, not client_certificate
  if [ -z "$cc" ] && [ -n "$tc" ]; then
    add_finding 1 "CA is in ssl_trusted_certificate but not ssl_client_certificate" \
      "nginx advertises acceptable client-CA names ONLY from ssl_client_certificate. Yours is set only via ssl_trusted_certificate, so certs verify but are never OFFERED — exactly matching 'not in the picker'." \
      "Point ssl_client_certificate at the issuing CA (chain) file, e.g. 'ssl_client_certificate /etc/nginx/soft-ca.pem;'. Keep ssl_verify_client on|optional. Reload nginx."
  fi
  if printf '%s' "$vc" | grep -qiE 'off|optional_no_ca'; then
    add_finding 2 "ssl_verify_client is off / optional_no_ca" \
      "$vc" \
      "'off' sends no CertificateRequest (no picker at all). 'optional_no_ca' does not advertise CA names. Set 'ssl_verify_client optional;' (or 'on') WITH ssl_client_certificate pointing at the issuing CA."
  fi
  if [ -z "$vc" ]; then
    add_finding 2 "ssl_verify_client not found in config" \
      "No ssl_verify_client directive detected under $files." \
      "Without it nginx defaults to 'off' and never requests a client cert. Add 'ssl_verify_client optional;' + 'ssl_client_certificate <issuing-CA>;' to the relevant server{} block."
  fi
}

inspect_apache() {
  h1 "Apache httpd client-certificate configuration"
  local files="/etc/httpd /etc/apache2"
  local vc caf cap dnf dnp vd proto
  vc="$(cfgrep '^\s*SSLVerifyClient' "$files")"
  caf="$(cfgrep '^\s*SSLCACertificateFile' "$files")"
  cap="$(cfgrep '^\s*SSLCACertificatePath' "$files")"
  dnf="$(cfgrep '^\s*SSLCADNRequestFile' "$files")"
  dnp="$(cfgrep '^\s*SSLCADNRequestPath' "$files")"
  vd="$(cfgrep '^\s*SSLVerifyDepth' "$files")"
  proto="$(cfgrep '^\s*SSLProtocol' "$files")"
  printf '%s\n' "  SSLVerifyClient:"; [ -n "$vc" ] && printf '    %s\n' "$vc" || info "    (not set)"
  printf '%s\n' "  SSLCACertificateFile/Path (verifies; also advertised UNLESS SSLCADNRequest* is set):"
  { [ -n "$caf" ] && printf '    %s\n' "$caf"; [ -n "$cap" ] && printf '    %s\n' "$cap"; } || info "    (not set)"
  printf '%s\n' "  SSLCADNRequestFile/Path (OVERRIDES which CA names are advertised):"
  if [ -n "$dnf$dnp" ]; then
    { [ -n "$dnf" ] && printf '    %s\n' "$dnf"; [ -n "$dnp" ] && printf '    %s\n' "$dnp"; }
    add_finding 1 "SSLCADNRequestFile/Path overrides the advertised CA names" \
      "When SSLCADNRequest* is set, Apache advertises ONLY those DNs (not SSLCACertificateFile). If your issuing CA is not in that file, the cert is never offered — matching 'not in the picker'." \
      "Ensure the SSLCADNRequest* file contains your issuing CA's certificate/DN, or remove the directive so Apache advertises from SSLCACertificateFile."
  else
    info "    (not set — CA names advertised from SSLCACertificateFile)"
  fi
  [ -n "$vd" ] && { printf '%s\n' "  SSLVerifyDepth:"; printf '    %s\n' "$vd"; }
  [ -n "$proto" ] && { printf '%s\n' "  SSLProtocol:"; printf '    %s\n' "$proto"; }
  if printf '%s' "$vc" | grep -qi 'none'; then
    add_finding 2 "SSLVerifyClient none" "$vc" \
      "'none' requests no client cert. Use 'optional' or 'require' on the vhost/location that needs mutual TLS."
  fi
}

inspect_haproxy() {
  h1 "HAProxy client-certificate configuration"
  local files="/etc/haproxy"
  local binds cav
  binds="$(cfgrep 'ca-file|verify\s+(optional|required)|ca-verify-file|crt\s' "$files")"
  [ -n "$binds" ] && printf '    %s\n' "$binds" || info "    (no ssl bind client-CA directives found under $files)"
  add_finding 3 "Confirm HAProxy 'ca-file' vs 'ca-verify-file'" \
    "'ca-file' both verifies AND advertises the CA names to the client; 'ca-verify-file' verifies without advertising. If the issuing CA moved to ca-verify-file, certs stop being offered." \
    "Ensure the issuing CA is in the 'ca-file' of the relevant 'bind ... ssl ... verify optional|required' line."
}

DETECTED="$(detect_server)"
case "$DETECTED" in
  nginx)  inspect_nginx ;;
  apache) inspect_apache ;;
  haproxy) inspect_haproxy ;;
  *) h1 "Server config"; warn "Could not auto-detect nginx/apache/haproxy. Re-run with --server <name>, or the endpoint probe below is still authoritative." ;;
esac

# ----------------------------------------------------------------------------
# 3. Live endpoint probe — the authoritative acceptable-CA list
# ----------------------------------------------------------------------------
ADVERTISED_CAS=""; NEG_PROTO=""; REQUESTED_CERT=0
if [ "$DO_PROBE" = 1 ] && [ -n "$OPENSSL" ]; then
  h1 "Live handshake probe: $CONNECT"
  host="${CONNECT%%:*}"; sni="${SERVERNAME:-$host}"
  probe="$(printf 'Q\n' | "$OPENSSL" s_client -connect "$CONNECT" -servername "$sni" -prexit 2>&1)"
  NEG_PROTO="$(printf '%s' "$probe" | sed -n 's/^\s*Protocol\s*:\s*//p' | head -1)"
  [ -z "$NEG_PROTO" ] && NEG_PROTO="$(printf '%s' "$probe" | grep -oE 'TLSv1\.[0-3]' | tail -1)"
  kv "negotiated protocol" "${NEG_PROTO:-unknown}"

  if printf '%s' "$probe" | grep -q 'Acceptable client certificate CA names'; then
    REQUESTED_CERT=1
    ADVERTISED_CAS="$(printf '%s' "$probe" | awk '/Acceptable client certificate CA names/{f=1;next} /^---/{f=0} /Client Certificate Types|Requested Signature|Server Temp Key|Peer signature/{f=0} f' | awk 'NF && !seen[$0]++')"
    printf '%s\n' "  ${B}Acceptable client-CA names the server advertises:${Z}"
    if [ -n "$ADVERTISED_CAS" ]; then printf '%s\n' "$ADVERTISED_CAS" | sed 's/^/    /'; else info "    (list is EMPTY)"; fi
  elif printf '%s' "$probe" | grep -qiE 'certificate request|Client Certificate Types'; then
    REQUESTED_CERT=1
    warn "Server requests a client cert but advertised an EMPTY CA-name list."
    add_finding 1 "Server requests a client cert but advertises NO acceptable CA names" \
      "The CertificateRequest carried an empty CA list. Browsers then offer nothing (or everything, depending on client). This matches 'not in the picker'." \
      "Configure the server to advertise the issuing CA (nginx ssl_client_certificate / Apache SSLCACertificateFile without a narrowing SSLCADNRequestFile)."
  else
    add_finding 1 "Server does NOT request a client certificate" \
      "No CertificateRequest seen in the handshake to $CONNECT. With no request, the browser never shows a picker." \
      "Enable client-cert auth on this vhost/port (nginx 'ssl_verify_client optional|on'; Apache 'SSLVerifyClient optional|require'). Verify you probed the same host/port/SNI the users hit."
  fi
  # TLS 1.3 + legacy signature interaction
  if [ "$NEG_PROTO" = "TLSv1.3" ]; then
    add_finding 3 "Endpoint negotiated TLS 1.3" \
      "Under TLS 1.3, clients will not offer a cert whose signature algorithm the server did not advertise (e.g. SHA-1/RSA-PKCS1 legacy certs)." \
      "If your cert is SHA-1 signed, either re-issue it with SHA-256, or (stopgap) allow TLS 1.2 on the vhost so the older cert is offered."
  fi
elif [ -n "$CONNECT" ] && [ -z "$OPENSSL" ]; then
  warn "Cannot probe $CONNECT: openssl missing."
fi

# ----------------------------------------------------------------------------
# 4. Inspect the soft cert(s)
# ----------------------------------------------------------------------------
read_pass() {
  if [ -n "$P12_PASS_ENV" ]; then printf '%s' "${!P12_PASS_ENV:-}"; return; fi
  local p; printf 'Enter password for %s (blank if none): ' "$1" >&2; read -rs p </dev/tty 2>/dev/null; printf '\n' >&2; printf '%s' "$p"
}

inspect_one_p12() {
  local f="$1"; h1 "Soft cert: $f"
  [ -n "$OPENSSL" ] || { warn "openssl missing; cannot inspect."; return; }
  local pass loaded_with="" out
  pass="$(read_pass "$f")"
  # Try default (OpenSSL 3 modern) first
  out="$("$OPENSSL" pkcs12 -in "$f" -nokeys -clcerts -passin "pass:$pass" 2>/tmp/cad.err)"
  if [ -n "$out" ]; then loaded_with="default";
  elif [ "$OSSL_MAJOR" -ge 3 ]; then
    out="$("$OPENSSL" pkcs12 -in "$f" -nokeys -clcerts -legacy -passin "pass:$pass" 2>>/tmp/cad.err)"
    [ -n "$out" ] && loaded_with="legacy"
  fi
  if [ -z "$out" ]; then
    warn "Could not load this .p12 (see reason below). Wrong password is the most common cause."
    sed 's/^/    /' /tmp/cad.err 2>/dev/null | tail -4
    if grep -qiE 'unsupported|decrypt|algorithm|RC2|provider' /tmp/cad.err 2>/dev/null; then
      add_finding 2 "PKCS#12 file uses legacy encryption OpenSSL 3 won't read by default" \
        "$f failed under the modern provider; error mentions unsupported/legacy algorithm." \
        "This affects LOADING, not the picker. Re-export the p12 with modern crypto (openssl pkcs12 -export ... -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg SHA256), or enable the legacy provider in openssl.cnf. But note: a load failure would not explain 'missing from picker' unless the client itself can't load it."
    fi
    rm -f /tmp/cad.err; return
  fi
  [ "$loaded_with" = "legacy" ] && add_finding 3 "This .p12 only loaded with the -legacy provider" \
    "$f" "The container uses old encryption. Clients on OpenSSL 3 / modern crypto stacks may fail to load it, which can remove it from their picker. Re-export with AES-based PBE."
  rm -f /tmp/cad.err

  local x; x="$(printf '%s' "$out" | "$OPENSSL" x509 -noout -subject -issuer -serial -dates -fingerprint 2>/dev/null)"
  printf '%s\n' "$x" | sed 's/^/    /'
  local sigalg keyinfo eku notafter
  sigalg="$(printf '%s' "$out" | "$OPENSSL" x509 -noout -text 2>/dev/null | grep -m1 'Signature Algorithm' | sed 's/^ *//')"
  keyinfo="$(printf '%s' "$out" | "$OPENSSL" x509 -noout -text 2>/dev/null | grep -m1 'Public-Key:' | sed 's/^ *//')"
  eku="$(printf '%s' "$out" | "$OPENSSL" x509 -noout -ext extendedKeyUsage 2>/dev/null | grep -iv 'X509v3' | sed 's/^ *//')"
  kv "signature" "${sigalg#Signature Algorithm: }"
  kv "public key" "$keyinfo"
  kv "ext key usage" "${eku:-<none>}"

  # Expiry
  if printf '%s' "$out" | "$OPENSSL" x509 -checkend 0 >/dev/null 2>&1; then :; else
    add_finding 1 "Client certificate is EXPIRED (or not yet valid)" \
      "$("$OPENSSL" x509 -noout -dates <<<"$out" 2>/dev/null | tr '\n' ' ')" \
      "Re-issue/renew the certificate. Expired certs are dropped from the picker by most clients."
  fi
  # clientAuth EKU
  if [ -n "$eku" ] && ! printf '%s' "$eku" | grep -qi 'TLS Web Client Authentication'; then
    add_finding 2 "Certificate lacks the clientAuth EKU" \
      "extendedKeyUsage = $eku" \
      "A cert without 'TLS Web Client Authentication' EKU is filtered out by many clients (and rejected by strict servers). Re-issue with clientAuth EKU."
  fi
  # SHA-1
  if printf '%s' "$sigalg" | grep -qi 'sha1'; then
    add_finding 2 "Certificate is signed with SHA-1" \
      "$sigalg" \
      "Modern stacks (OpenSSL 3 default SECLEVEL 2, TLS 1.3) reject/hide SHA-1-signed certs. Re-issue with SHA-256. As a stopgap, lower SECLEVEL or allow TLS 1.2 — but re-issuing is the real fix."
  fi
  # Issuer vs advertised list (the crux)
  local issuer_cn
  issuer_cn="$(printf '%s' "$out" | "$OPENSSL" x509 -noout -issuer 2>/dev/null | grep -oiE 'CN\s*=\s*[^,/]+' | head -1 | sed 's/.*=\s*//')"
  if [ "$REQUESTED_CERT" = 1 ] && [ -n "$ADVERTISED_CAS" ] && [ -n "$issuer_cn" ]; then
    if printf '%s' "$ADVERTISED_CAS" | grep -qiF "$issuer_cn"; then
      info "${G}MATCH:${Z} issuer CN '$issuer_cn' IS in the server's advertised acceptable-CA list."
    else
      add_finding 1 "Cert issuer is NOT in the server's advertised acceptable-CA list" \
        "Cert issuer CN='$issuer_cn' was not found in the acceptable-CA names advertised by $CONNECT. This is the direct reason the browser omits it from the picker." \
        "Add the issuing CA (full chain) to what the server advertises: nginx ssl_client_certificate, Apache SSLCACertificateFile (with no narrowing SSLCADNRequestFile). Then reload and re-run this probe."
    fi
  fi
}

if [ -n "$P12_PATH" ]; then
  if [ -d "$P12_PATH" ]; then
    found=0
    while IFS= read -r f; do found=1; inspect_one_p12 "$f"; done < <(find "$P12_PATH" -maxdepth 2 -type f \( -iname '*.p12' -o -iname '*.pfx' \) 2>/dev/null)
    [ "$found" = 0 ] && warn "No .p12/.pfx files found under $P12_PATH"
  elif [ -f "$P12_PATH" ]; then
    inspect_one_p12 "$P12_PATH"
  else
    warn "--p12 path not found: $P12_PATH"
  fi
fi

# ----------------------------------------------------------------------------
# 5. Ranked findings
# ----------------------------------------------------------------------------
h1 "Findings (most likely cause first)"
if [ "${#FINDINGS[@]}" -eq 0 ]; then
  info "No specific issue was pinpointed from the inputs given."
  info "Re-run WITH both --connect HOST:PORT and --p12 FILE so the issuer↔advertised-CA cross-check can run — that check is what usually nails 'not in the picker'."
else
  IFS=$'\n' sorted=($(printf '%s\n' "${FINDINGS[@]}" | sort -t'|' -k1,1n)); unset IFS
  n=0
  for entry in "${sorted[@]}"; do
    n=$((n+1)); sev="${entry%%|*}"; rest="${entry#*|}"
    title="${rest%%|*}"; rest="${rest#*|}"; evidence="${rest%%|*}"; mitigation="${rest#*|}"
    case "$sev" in 1) tag="${R}CRITICAL${Z}";; 2) tag="${Y}LIKELY${Z}";; 3) tag="${C}CHECK${Z}";; *) tag="INFO";; esac
    printf '\n%s%d. [%s] %s%s\n' "$B" "$n" "$tag" "$title" "$Z"
    printf '   why: %s\n' "$evidence"
    printf '   fix: %s\n' "$mitigation"
  done
fi
hr
printf '%sReminder:%s this tool changed nothing. Apply fixes yourself, then re-run to confirm.\n' "$B" "$Z"
