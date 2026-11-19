#!/bin/sh
# Install a CA certificate into Camoufox via the Firefox enterprise
# policy mechanism (Certificates.Install in distribution/policies.json).
#
# Use this when your network egress is a TLS-intercepting proxy whose CA
# is trusted by the operating system but NOT by Firefox/Camoufox
# (pages fail with SEC_ERROR_UNKNOWN_ISSUER inside the browser only).
#
# Usage:
#   scripts/install-egress-ca.sh /path/to/egress-ca.pem /path/to/camoufox-install-dir
#
# The Camoufox install dir is the directory that contains the camoufox
# binary and the distribution/ folder. The CA file is copied into
# distribution/ and referenced by file name. An existing policies.json
# is backed up to policies.json.bak-egress-ca before being modified.
set -eu

CA_SRC=${1:?usage: install-egress-ca.sh <ca.pem> <camoufox-dir>}
CAM_DIR=${2:?usage: install-egress-ca.sh <ca.pem> <camoufox-dir>}
DIST="$CAM_DIR/distribution"
POL="$DIST/policies.json"
CA_NAME=$(basename "$CA_SRC")

[ -f "$CA_SRC" ] || { echo "CA file not found: $CA_SRC" >&2; exit 1; }
[ -d "$CAM_DIR" ] || { echo "Camoufox dir not found: $CAM_DIR" >&2; exit 1; }

mkdir -p "$DIST"
cp "$CA_SRC" "$DIST/$CA_NAME"
[ -f "$POL" ] && cp "$POL" "$POL.bak-egress-ca"

python3 - "$POL" "$CA_NAME" <<'PYEOF'
import json, sys
path, ca_name = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
pol = data.setdefault("policies", {})
certs = pol.setdefault("Certificates", {})
install = certs.setdefault("Install", [])
if ca_name not in install:
    install.append(ca_name)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
print(f"Certificates.Install now includes: {ca_name}")
PYEOF

echo "Done. Restart the solver server so Camoufox picks up the policy."
