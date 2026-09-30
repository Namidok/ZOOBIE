#!/bin/zsh
# Creates a local, self-signed code-signing identity ("Companion Local Signing") in the login keychain.
# macOS ties privacy permissions (Accessibility, Screen Recording, Automation) to the app's signature;
# the default ad-hoc signature changes on every build, which silently revokes them. Signing with this
# stable identity keeps permissions across rebuilds. Remove it any time in Keychain Access.
set -euo pipefail

name="Companion Local Signing"
if security find-certificate -c "$name" >/dev/null 2>&1; then
  echo "\"$name\" already exists."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
# A throwaway password: the .p12 only exists inside $tmp for the import.
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$name" \
  -out "$tmp/identity.p12" -passout pass:companion 2>/dev/null
security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P companion -T /usr/bin/codesign >/dev/null

echo "Created \"$name\". If macOS asks whether codesign may use the key, choose Always Allow."
