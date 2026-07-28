#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Andreas Menzel
# Creates a self-signed code-signing identity ("Shout Dev Signing") in your
# login keychain so every rebuild keeps the SAME signature — and macOS privacy
# permissions survive rebuilds.
#
# Run this yourself in Terminal. macOS will ask for YOUR login password twice:
#   1. when trusting the certificate for code signing,
#   2. on the first build, when codesign uses the key ("Always Allow").
#
# If you have an Apple ID in Xcode, an "Apple Development" certificate
# (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +) is the cleaner
# alternative — bundle.sh auto-detects either.
set -euo pipefail

NAME="Shout Dev Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Identity \"$NAME\" already exists — nothing to do."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Shout Dev Signing
[v3]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

# Random, ephemeral passphrase — the .p12 only exists in $TMP long enough to
# import the key into the keychain, then it's deleted (trap on EXIT).
P12_PASS=$(openssl rand -base64 24)

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -out "$TMP/identity.p12" -inkey "$TMP/key.pem" \
    -in "$TMP/cert.pem" -password "pass:$P12_PASS" -name "$NAME"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

echo "Now trusting the certificate for code signing — macOS will ask for your password:"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
echo "Done. Next steps:"
echo "  1. make run                 (auto-detects the identity; click 'Always Allow' if asked)"
echo "  2. make reset-permissions   (clears the stale permission entries)"
echo "  3. Re-grant the permissions in Shout's Setup window — for the last time."
