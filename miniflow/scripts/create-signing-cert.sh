#!/bin/zsh
# OPTIONAL. Creates a local code-signing certificate ("Mini Flow Local Signing") in your login keychain so that
# macOS keeps Mini Flow's permissions (Microphone, Accessibility, Input Monitoring) when you rebuild the app.
# Without it the app is ad-hoc signed and you must re-grant those permissions after every rebuild.
# Local only: nothing is uploaded, no Apple account needed. Remove it any time in Keychain Access.
set -e
NAME="Mini Flow Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Already exists: $NAME"; exit 0; fi
read "reply?Create a local code-signing certificate '$NAME' in your login keychain? [y/N] "
[[ "$reply" == [yY]* ]] || exit 0
W=$(mktemp -d); chmod 700 "$W"; trap 'rm -rf "$W"' EXIT
cat > "$W/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$W/cfg" -keyout "$W/key.pem" -out "$W/cert.pem" 2>/dev/null
P=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$W/key.pem" -in "$W/cert.pem" -name "$NAME" -out "$W/id.p12" -passout "pass:$P" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$W/key.pem" -in "$W/cert.pem" -name "$NAME" -out "$W/id.p12" -passout "pass:$P"
security import "$W/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P" -T /usr/bin/codesign
echo "Created. Rebuild with ./build.sh — then grant Mini Flow's permissions one last time."
