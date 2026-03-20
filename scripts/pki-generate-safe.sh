#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKI_DIR="$PROJECT_DIR/pki"
ZITI="$PROJECT_DIR/bin/ziti"

echo "=== Safe PKI Generation ==="

# Create structure
mkdir -p "$PKI_DIR"

# Helper function to verify a cert/key pair
verify_cert_key_pair() {
    local cert_file=$1
    local key_file=$2
    local name=$3
    local cert_pub
    local key_pub

    cert_pub="$(mktemp /tmp/verify-cert.XXXXXX.pub)"
    key_pub="$(mktemp /tmp/verify-key.XXXXXX.pub)"

    openssl x509 -in "$cert_file" -pubkey -noout > "$cert_pub" 2>/dev/null
    openssl pkey -in "$key_file" -pubout > "$key_pub" 2>/dev/null
    
    if diff -q "$cert_pub" "$key_pub" >/dev/null 2>&1; then
        echo "  ✓ $name: MATCH"
        rm -f "$cert_pub" "$key_pub"
        return 0
    else
        echo "  ✗ $name: MISMATCH - regenerating..."
        rm -f "$cert_pub" "$key_pub"
        return 1
    fi
}

# Generate Root CA with verification loop
echo ">>> Generating Root CA..."
max_attempts=3
attempt=1
while [ $attempt -le $max_attempts ]; do
    echo "  Attempt $attempt/$max_attempts"
    "$ZITI" pki create ca \
        --pki-root "$PKI_DIR" \
        --ca-file ca \
        --ca-name "5GC-Ziti-Root-CA" 2>/dev/null || true
    
    if verify_cert_key_pair "$PKI_DIR/ca/certs/ca.cert" "$PKI_DIR/ca/keys/ca.key" "Root CA"; then
        break
    fi
    attempt=$((attempt + 1))
    if [ $attempt -le $max_attempts ]; then
        rm -f "$PKI_DIR/ca/certs/ca.cert" "$PKI_DIR/ca/keys/ca.key"
    fi
done

if [ $attempt -gt $max_attempts ]; then
    echo "✗ FATAL: Root CA generation failed after $max_attempts attempts"
    exit 1
fi

# Generate Controller Intermediate CA
echo ">>> Generating Controller Intermediate CA..."
"$ZITI" pki create intermediate \
    --pki-root "$PKI_DIR" \
    --ca-name ca \
    --intermediate-file ctrl-intermediate \
    --intermediate-name "Controller Signing CA"

# Generate Controller Server Cert
echo ">>> Generating Controller Server Certificate..."
"$ZITI" pki create server \
    --pki-root "$PKI_DIR" \
    --ca-name ca \
    --server-file ctrl-server \
    --dns "localhost,ziti-controller" \
    --ip "127.0.0.1,10.10.1.1,10.10.2.1,10.10.3.1"
verify_cert_key_pair "$PKI_DIR/ca/certs/ctrl-server.cert" "$PKI_DIR/ca/keys/ctrl-server.key" "Ctrl Server"

# Generate Controller Client Cert
echo ">>> Generating Controller Client Certificate..."
"$ZITI" pki create client \
    --pki-root "$PKI_DIR" \
    --ca-name ca \
    --client-file ctrl-client \
    --client-name "Controller Client"
verify_cert_key_pair "$PKI_DIR/ca/certs/ctrl-client.cert" "$PKI_DIR/ca/keys/ctrl-client.key" "Ctrl Client"

# Generate Router Server Cert with retry
echo ">>> Generating Router Server Certificate (with validation)..."
attempt=1
while [ $attempt -le $max_attempts ]; do
    echo "  Attempt $attempt/$max_attempts"
    "$ZITI" pki create server \
        --pki-root "$PKI_DIR" \
        --ca-name ca \
        --server-file "router-server-attempt$attempt" \
        --dns "localhost,ziti-router" \
        --ip "127.0.0.1,10.10.1.1,10.10.2.1,10.10.3.1" 2>/dev/null || true
    
    if verify_cert_key_pair "$PKI_DIR/ca/certs/router-server-attempt$attempt.cert" "$PKI_DIR/ca/keys/router-server-attempt$attempt.key" "Router Server Attempt $attempt"; then
        # Use this one
        cp "$PKI_DIR/ca/certs/router-server-attempt$attempt.cert" "$PKI_DIR/ca/certs/router-server.cert"
        cp "$PKI_DIR/ca/keys/router-server-attempt$attempt.key" "$PKI_DIR/ca/keys/router-server.key"
        break
    fi
    attempt=$((attempt + 1))
done

if [ $attempt -gt $max_attempts ]; then
    echo "✗ FATAL: Router Server cert generation failed after $max_attempts attempts"
    exit 1
fi

# Generate Router Client Cert
echo ">>> Generating Router Client Certificate..."
"$ZITI" pki create client \
    --pki-root "$PKI_DIR" \
    --ca-name ca \
    --client-file router-client \
    --client-name "Router Client"
verify_cert_key_pair "$PKI_DIR/ca/certs/router-client.cert" "$PKI_DIR/ca/keys/router-client.key" "Router Client"

echo ""
echo "✓ All PKI certificates generated and verified successfully!"
