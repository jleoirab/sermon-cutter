#!/bin/bash
# Makes the free code-signing certificate "Sermon Cutter Dev" in this Mac's
# login keychain, once. Releases are signed with it, so on the leads' Macs
# each new version is recognised as the same app and keeps the permissions
# given to the last one (the Documents folder). It doesn't replace Apple's
# paid Developer ID: macOS still asks each Mac to allow the app once.
#
# The first build signed with it may ask: "codesign wants to sign using key
# 'Sermon Cutter Dev'". Choose Always Allow.
set -euo pipefail
NAME="Sermon Cutter Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = CCI Sermon Cutter
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASS" 2>/dev/null
security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "made the code-signing certificate \"$NAME\" in the login keychain"
