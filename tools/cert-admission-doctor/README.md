# cert-admission-doctor

Read-only diagnostic for: *"my soft (PKCS#12) client certificate used to work, but
after a server/app upgrade it is no longer accepted — or no longer shows up in the
browser's certificate picker."*

It inspects every layer that decides whether a client cert is **offered** and
**accepted**, then prints a ranked list of likely causes with concrete fixes.
It changes **nothing**: no config edits, no restarts, no key material written.

## The key insight it's built around
A browser only offers a client certificate whose **issuer is in the acceptable-CA
list the *server* advertises** during the TLS handshake (the `CertificateRequest`).
When a **server upgrade** makes a cert vanish from the picker, the cert is usually
fine — the server just stopped advertising that CA. This tool proves that directly
by probing the live endpoint and cross-checking your cert's issuer against the
advertised list.

## What it checks
1. **Crypto environment** — OpenSSL version, whether the legacy provider is loaded/available, Java.
2. **Server config** (auto-detects nginx / Apache / HAProxy) — the client-cert directives, including the classic regressions:
   - nginx: CA in `ssl_trusted_certificate` (verifies, **not advertised**) instead of `ssl_client_certificate` (advertised).
   - Apache: `SSLCADNRequestFile`/`Path` narrowing the advertised DNs away from `SSLCACertificateFile`.
   - `ssl_verify_client off` / `SSLVerifyClient none` → no cert requested at all.
3. **Live handshake probe** (`--connect`) — the authoritative acceptable-CA list the server advertises, whether it requests a client cert, and the negotiated TLS version.
4. **Soft cert inspection** (`--p12`) — issuer chain, expiry, signature algorithm (SHA-1?), `clientAuth` EKU, key size, and whether it loads under OpenSSL 3 without the legacy provider.
5. **Cross-check** — is your cert's issuer actually in what the server advertises? (This is what nails "not in the picker".)

## Usage
```bash
# Full run: probe the live endpoint AND inspect a soft cert (best diagnosis)
./cert-admission-doctor.sh --connect app.example.com:443 --p12 /path/to/mycert.p12

# Just see what the server advertises (no cert on hand)
./cert-admission-doctor.sh --connect app.example.com:443

# Inspect config + a directory of certs, no network
./cert-admission-doctor.sh --p12 /etc/pki/soft-certs --no-probe
```

### Options
| Flag | Meaning |
|------|---------|
| `--connect HOST:PORT` | Probe this live endpoint for the advertised acceptable-CA list. |
| `--p12 FILE\|DIR` | Inspect a `.p12`/`.pfx` file, or every one under a directory. |
| `--p12-pass-env VAR` | Read the p12 password from env var `VAR` (avoids an interactive prompt / shell history). |
| `--server auto\|nginx\|apache\|haproxy` | Override server auto-detection. |
| `--servername NAME` | SNI to send on the probe (defaults to the host in `--connect`). |
| `--no-probe` | Skip the network probe; inspect local config + certs only. |

The password is read from an env var or a hidden prompt — never passed on the
command line and never logged.

## Requirements
`openssl` (v3 recommended; v1.1 works with reduced legacy-provider detection),
plus read access to the server config for the config-inspection section. The probe
needs network reachability to the endpoint.

## Interpreting the output
Findings are ranked: **CRITICAL** (best explanation) → **LIKELY** → **CHECK** → **INFO**.
Each shows *why* (the evidence) and *fix* (the concrete remediation). Apply a fix,
then re-run to confirm the cert now appears / is accepted.
