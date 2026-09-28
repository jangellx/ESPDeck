#!/bin/bash
# Builds text_test.cpp with src/Text.cpp on the Mac and runs it.
set -euo pipefail
cd "$( dirname "$0" )"
WORK="$( mktemp -d )"
trap 'rm -rf "$WORK"' EXIT
clang++ -std=c++17 -Wall -Wextra -Wshadow -fsanitize=address,undefined -I../../src text_test.cpp ../../src/Text.cpp -o "$WORK/text_test"
"$WORK/text_test"
