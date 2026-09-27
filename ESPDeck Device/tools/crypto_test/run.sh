#!/bin/bash
# Builds crypto_test.cpp with src/Crypto.cpp against ESP-IDF's mbedTLS sources, runs it and
# crypto_test.swift (CryptoKit), and checks both against vectors.txt.
set -euo pipefail
cd "$( dirname "$0" )"
MBEDTLS="${MBEDTLS:-$HOME/.platformio/packages/framework-espidf/components/mbedtls/mbedtls}"
WORK="$( mktemp -d )"
trap 'rm -rf "$WORK"' EXIT

for source in "$MBEDTLS"/library/*.c; do
	clang -c -O1 -w -I"$MBEDTLS/include" -I"$MBEDTLS/library" "$source" -o "$WORK/$( basename "$source" .c ).o"
done
clang++ -std=c++17 -Wall -Wextra -I../../src -I"$MBEDTLS/include" crypto_test.cpp ../../src/Crypto.cpp "$WORK"/*.o -o "$WORK/crypto_test"

grep -v '^#' vectors.txt > "$WORK/expected.txt"
"$WORK/crypto_test" > "$WORK/mbedtls.txt"
swift crypto_test.swift > "$WORK/cryptokit.txt"
diff "$WORK/expected.txt" "$WORK/mbedtls.txt"
diff "$WORK/expected.txt" "$WORK/cryptokit.txt"
echo "mbedTLS and CryptoKit both match vectors.txt"
