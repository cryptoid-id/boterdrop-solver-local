# boterdrop-solver-local

A local, self-hosted REST API solver for web verification challenges —
Cloudflare Turnstile, Cloudflare `cf_clearance`, reCAPTCHA v3, and AWS WAF —
driven by [Camoufox](https://github.com/daijro/camoufox) (a hardened,
anti-detect Firefox build) through Playwright. One Python file
(`api_server.py`), one local HTTP API, no external solver service and no
per-solve fees.

## Origin and attribution

This repository is an adaptation of
**[najibyahya/Boterdrop-Solver](https://github.com/najibyahya/Boterdrop-Solver)**,
released under the MIT License (see `LICENSE`, kept intact, including the
original copyright holder).

`api_server.py` in this repository is **byte-for-byte identical to the
upstream file** (SHA-256
`e45e17aab30ddeb19feee9417548d45b6fa3187d0fedca5d431ad45669ecde32`).
We claim no authorship over the upstream solver code. Everything listed
under "What we changed" is configuration, dependency pinning, and
documentation around it.

## What we changed

Compared to upstream defaults, this adaptation:

- **Hardens the example configuration** (`config.example.json`): binds
  `127.0.0.1` instead of `0.0.0.0`, and runs 1 thread × 1 page instead of
  5 × 2. The solver API has no authentication, so localhost-only is the
  safe default (see "Security notes").
- **Pins a tested dependency set** (`requirements.txt`), most importantly
  **Playwright 1.59.0** with **Camoufox build 142.0.1-fork.26**
  (the `camoufox` Python package 0.5.9). Newer Playwright (≥ 1.61) sends
  viewport fields this Camoufox fork build rejects (protocol errors such
  as `Browser.setDefaultViewport` / "isMobile") and its Firefox driver
  can crash on uncaught page errors from challenge pages. The pinned
  pair starts cleanly and solves reliably.
- **Documents a fix for TLS-intercepting egress proxies** (next section):
  when the solver runs behind a corporate/sandbox proxy that intercepts
  TLS, Camoufox rejects every certificate with
  `SEC_ERROR_UNKNOWN_ISSUER` until the proxy's CA is installed through
  the Firefox enterprise policy mechanism. A generic helper is included
  at `scripts/install-egress-ca.sh`.
- Ships an empty `proxies.example.txt` instead of a real proxy list, and
  a `.gitignore` that keeps local state (real `config.json`,
  `proxies.txt`, `debug_logs/`, logs, CA files) out of the repository.

## Requirements

- Python 3.10+ and a virtual environment.
- The pinned packages in `requirements.txt`.
- The Camoufox browser build (fetched by the `camoufox` package; if the
  main Camoufox repository is unreachable from your network, the
  project's official backup repository `coryking/camoufox` carries the
  same builds — 142.0.1-fork.26 is the one tested here).
- Enough free disk for the browser download: point `TMPDIR` at a disk
  with several GB free if your `/tmp` is a small tmpfs.

## Setup

```sh
python3 -m venv venv
. venv/bin/activate
pip install -r requirements.txt   # install manually BEFORE first run (see below)
python -m camoufox fetch          # download the Camoufox build

cp config.example.json config.json
cp proxies.example.txt proxies.txt   # only if you use proxies; may stay empty
python api_server.py
```

Install the dependencies manually before the first run: the upstream
server contains an aggressive built-in auto-installer that runs on
startup when packages are missing, with unpinned versions. Pre-installing
the pinned set turns it into a no-op.

## Fix: running behind a TLS-intercepting proxy

Symptom: system tools (`curl`, `pip`) reach HTTPS sites fine, but every
solve inside Camoufox fails, and the browser reports
`SEC_ERROR_UNKNOWN_ISSUER`. The proxy intercepts TLS and re-signs pages
with its own CA. That CA is usually already in the system trust store,
but Firefox/Camoufox keeps its own store, so the browser rejects it.

Procedure (generic; no environment-specific files are included here):

1. Identify the intercepting CA. Compare the certificate chain a site
   presents *through the proxy* (for example with
   `openssl s_client -connect host:443 -showcerts`) against your system
   trust bundle (on Debian/Ubuntu: `/etc/ssl/certs/ca-certificates.crt`).
   The CA whose fingerprint matches the issuer of the presented chain is
   the one to extract, as a PEM file.
2. Install that PEM into Camoufox through the Firefox **enterprise
   policy** mechanism: a `Certificates.Install` entry in
   `distribution/policies.json` inside the Camoufox installation
   directory. (Importing into a browser profile's `cert9.db` does not
   survive Playwright, which creates a fresh temporary profile on every
   run — the policy file is read at every browser start.)
   The helper script does exactly this, with a backup of any existing
   `policies.json`:

   ```sh
   scripts/install-egress-ca.sh /path/to/egress-ca.pem /path/to/camoufox-install-dir
   ```

3. Restart the solver server and re-test. Do **not** work around this
   with `ignore_https_errors`-style patches: with the CA installed, TLS
   validation stays fully on.

## Usage

Start the server (it reads `config.json` in the working directory), then:

```sh
# Create a Turnstile task
curl "http://127.0.0.1:8000/turnstile?url=https://example.com/&sitekey=<SITEKEY>"
# -> {"id": "<task_id>", ...}

# Poll for the result (note: the parameter is "id", not "task_id")
curl "http://127.0.0.1:8000/result?id=<task_id>"
# -> {"status": "success", "value": "<token>", "elapsed_time": ...}
```

Other endpoints, as in upstream: `/clearance` (cf_clearance),
`/recaptchaV3` (GET or POST), `/aws-token` (AWS WAF).

Tokens are short-lived (about 300 seconds) and single-use: request one
only when the rest of your flow is ready to submit it immediately.
A token is bound to the hostname and sitekey it was minted for; it is
not bound to any login session.

### Safe verification

Verify your setup without touching a real site, using Cloudflare's
official always-pass test sitekey on `example.com`:

```sh
curl "http://127.0.0.1:8000/turnstile?url=https://example.com/&sitekey=1x00000000000000000000AA"
```

On the tested configuration (with the egress-CA fix applied where
needed), this issued tokens in 4.8 s and 4.0 s on consecutive runs,
and in 3.8 s / 2.9 s with the Playwright 1.59.0 pin.

## Known limitations

- **Passing the test sitekey proves your tooling, not a target site.**
  Challenge providers decide per domain, per sitekey, and per source
  IP. On some production domains the widget itself can render in an
  error state for a shared/datacenter egress IP — the solve then fails
  with no token and no numeric error code — while the identical stack
  passes `example.com` in seconds. That is a provider-side decision,
  not something a solver configuration can override; the remaining held
  claims or actions on such a domain stay held.
- **Version pairing is fragile.** Camoufox fork builds and Playwright
  releases move independently; a Playwright upgrade can silently break
  browser startup or crash the driver on challenge pages. Treat
  `requirements.txt` as a tested pair, and re-run the safe verification
  above after any change.
- One server instance drives one browser pool: the conservative
  1 thread × 1 page configuration favours stability over throughput.

## Security notes

- **The API has no authentication.** Anyone who can reach the port can
  mint tokens with your browser and your IP. Bind `127.0.0.1` only (the
  shipped example config does), and never expose the server to a LAN or
  the public internet.
- **Debug mode saves full page HTML and screenshots** under
  `debug_logs/`. Keep `"debug": false` unless you are actively
  diagnosing, and never commit that folder.
- **Never commit real `config.json` or `proxies.txt`** — proxy entries
  can contain credentials. Both are in `.gitignore`.
- Solve responsibly: a locally minted token does not override a site's
  own terms, and challenge providers score IPs — a shared or datacenter
  egress IP may be challenged more strictly on some domains than on
  others, independent of your tooling.

## License

MIT — see `LICENSE`. The solver code is upstream work
(najibyahya/Boterdrop-Solver); the configuration, pinning, helper
script, and documentation in this repository are released under the
same license.
