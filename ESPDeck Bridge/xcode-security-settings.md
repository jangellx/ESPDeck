# Xcode Security Settings

Security build settings decisions for ESPDeck Bridge. Last audited 2026-10-08 (three targets, Swift only).

This file is deliberately not a member of the Xcode project: a Markdown file added to the project becomes a resource of the app and the menu bar bundle.

## Enabled settings

- `ENABLE_ENHANCED_SECURITY`: set in `Config/Signing.xcconfig`, the project's base configuration, so every target inherits it. It brings pointer authentication with it (`ENABLE_POINTER_AUTHENTICATION`, an `arm64e` slice beside `arm64`). ESPDeckMenuBar has to be built the same way as the app that loads it, which the project-level setting takes care of. Adding the entitlements also set it on the ESPDeck Bridge target itself.
- `ENABLE_HARDENED_RUNTIME`: already on for ESPDeck Bridge and ESPDeckMenuBar before this audit.
- Entitlements on ESPDeck Bridge (`Support/ESPDeck Bridge Catalyst.entitlements`):
  - `com.apple.security.hardened-process`
  - `com.apple.security.hardened-process.enhanced-security-version-string` to `2`
  - `com.apple.security.hardened-process.hardened-heap`
  - `com.apple.security.hardened-process.dyld-ro`
  - `com.apple.security.hardened-process.platform-restrictions-string` to `2`
  - `com.apple.security.hardened-process.checked-allocations`: hardware memory tagging, which acts on Macs with an M5 chip or later.
  - `com.apple.security.hardened-process.checked-allocations.soft-mode`: a memory fault produces a crash report without ending the app. Remove this key to enforce, once the app has run on an M5 Mac without reports.
- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`, `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`, `GCC_WARN_64_TO_32_BIT_CONVERSION`: already set at the project level. They check C and Objective-C, which the project doesn't have today.

## Disabled settings

None. Nothing security-related is deliberately turned off.

## Deferred

Settings considered but not yet enabled. Revisit them later.

- `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` and `com.apple.security.hardened-process.checked-allocations.enforce-checked-pointer-arithmetic-overflow`: checked pointer arithmetic applies to iOS and watchOS devices only, and the app is Mac only.
- `CLANG_WARN_IMPLICIT_FALLTHROUGH`, `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS`, `CLANG_ANALYZER_SECURITY_FLOATLOOPCOUNTER`, `CLANG_ANALYZER_SECURITY_INSECUREAPI_RAND`, `CLANG_ANALYZER_SECURITY_INSECUREAPI_STRCPY`, `CLANG_TIDY_BUGPRONE_REDUNDANT_BRANCH_CONDITION`: these check C, C++ and Objective-C. Enable them if such code is ever added.
- The additional diagnostic settings (for example `CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`, `GCC_WARN_SIGN_COMPARE`, `CLANG_WARN_ASSIGN_ENUM`): the same reason, and they are noisier.
- `ENABLE_C_BOUNDS_SAFETY`, `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS`: no C or C++ code.
