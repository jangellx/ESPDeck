#!/bin/bash
# Builds crypto_test.cpp with src/Crypto.cpp against ESP-IDF's mbedTLS sources, and
# crypto_test.swift with ESPDeck Bridge's DeckCrypto.swift (CryptoKit), runs both, and checks
# both against vectors.txt.
set -euo pipefail
cd "$( dirname "$0" )"
MBEDTLS="${MBEDTLS:-$HOME/.platformio/packages/framework-espidf/components/mbedtls/mbedtls}"
BRIDGE="../../../ESPDeck Bridge/ESPDeck Bridge/Security"
WORK="$( mktemp -d )"
trap 'rm -rf "$WORK"' EXIT

for source in "$MBEDTLS"/library/*.c; do
	clang -c -O1 -w -I"$MBEDTLS/include" -I"$MBEDTLS/library" "$source" -o "$WORK/$( basename "$source" .c ).o"
done
clang++ -std=c++17 -Wall -Wextra -I../../src -I"$MBEDTLS/include" crypto_test.cpp ../../src/Crypto.cpp "$WORK"/*.o -o "$WORK/crypto_test"

# Top-level code has to be in main.swift when several files are compiled together.
cp crypto_test.swift "$WORK/main.swift"
swiftc -O -o "$WORK/crypto_test_swift" "$WORK/main.swift" "$BRIDGE/DeckCrypto.swift" "$BRIDGE/DevOTAPassword.swift"

grep -v '^#' vectors.txt > "$WORK/expected.txt"
"$WORK/crypto_test" > "$WORK/mbedtls.txt"
"$WORK/crypto_test_swift" > "$WORK/cryptokit.txt"
diff "$WORK/expected.txt" "$WORK/mbedtls.txt"
diff "$WORK/expected.txt" "$WORK/cryptokit.txt"
echo "mbedTLS and CryptoKit both match vectors.txt"
