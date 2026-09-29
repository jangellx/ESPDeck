#!/usr/bin/env python3
"""Makes the virtual-eFuse test build's project: a copy of ESPDeck Device in ./work with
test hooks added, an `nvstest` PlatformIO environment, virtual eFuses kept in flash
(CONFIG_EFUSE_VIRTUAL, CONFIG_EFUSE_VIRTUAL_KEEP_IN_FLASH) and an efuse_em partition.

The real project is only read. Every hook goes in at an anchor that must appear exactly once,
so a source change that moves an anchor stops here instead of building something untested.

Usage: prepare.py <ESPDeck Device folder> <work folder> <build folder>
"""
import os
import shutil
import sys

KIT = os.path.dirname(os.path.abspath(__file__))


def patch(path, edits):
    with open(path) as f:
        text = f.read()
    for anchor, replacement in edits:
        count = text.count(anchor)
        if count != 1:
            sys.exit(f"prepare: anchor found {count} times in {os.path.basename(path)}:\n{anchor}")
        text = text.replace(anchor, replacement)
    with open(path, "w") as f:
        f.write(text)


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    project, work, build = (os.path.abspath(p) for p in sys.argv[1:])
    if not os.path.isfile(os.path.join(project, "src", "SecureNVS.cpp")):
        sys.exit(f"prepare: {project} isn't the ESPDeck Device folder")

    # A fresh copy each time; managed components copied too, so the component manager can
    # never touch the real project's.
    if os.path.exists(work):
        shutil.rmtree(work)
    os.makedirs(work)
    for name in ("CMakeLists.txt", "dependencies.lock", "partitions.csv", "platformio.ini", "sdkconfig.defaults", "sdkconfig.espdeck"):
        shutil.copy2(os.path.join(project, name), work)
    for name in ("src", "tools"):
        shutil.copytree(os.path.join(project, name), os.path.join(work, name))
    shutil.copytree(os.path.realpath(os.path.join(project, "managed_components")), os.path.join(work, "managed_components"), symlinks=True)
    shutil.copy2(os.path.join(KIT, "partitions_nvstest.csv"), work)

    # The environment, building into the kit's own folder.
    patch(os.path.join(work, "platformio.ini"), [
        ("build_dir = ${sysenv.HOME}/.platformio/build/ESPDeck", f"build_dir = {build}"),
        ("extra_configs = platformio.local*.ini\n", "\n"),
    ])
    with open(os.path.join(work, "platformio.ini"), "a") as f:
        f.write("\n; Virtual eFuses (kept in the efuse_em partition): nothing is burned on the chip.\n"
                "[env:nvstest]\nextends = env:espdeck\nboard_build.partitions = partitions_nvstest.csv\n")

    # sdkconfig.espdeck with virtual eFuses.
    with open(os.path.join(work, "sdkconfig.espdeck")) as f:
        config = f.read()
    off = "# CONFIG_EFUSE_VIRTUAL is not set\n"
    if config.count(off) != 1:
        sys.exit("prepare: sdkconfig.espdeck doesn't have CONFIG_EFUSE_VIRTUAL off where expected")
    config = config.replace(off, "CONFIG_EFUSE_VIRTUAL=y\nCONFIG_EFUSE_VIRTUAL_KEEP_IN_FLASH=y\nCONFIG_EFUSE_VIRTUAL_LOG_ALL_WRITES=y\n")
    with open(os.path.join(work, "sdkconfig.nvstest"), "w") as f:
        f.write(config)
    with open(os.path.join(work, "sdkconfig.defaults"), "a") as f:
        f.write("\n# TEST: virtual eFuses, kept in flash (efuse_em)\nCONFIG_EFUSE_VIRTUAL=y\nCONFIG_EFUSE_VIRTUAL_KEEP_IN_FLASH=y\nCONFIG_EFUSE_VIRTUAL_LOG_ALL_WRITES=y\n")

    src = os.path.join(work, "src")

    # SecureNVS: simulated power cuts (a restart at a chosen step) and a simulated failure,
    # armed over Improv (0xF0) in RTC memory, which survives a restart; each fires once.
    #   1 after the burn   2 after the erase   3 halfway through writing the entries back
    #   4 after a first-setup move, before the credentials are saved   5 the write fails (no cut)
    patch(os.path.join(src, "SecureNVS.cpp"), [
        ('#include "nvs_sec_provider.h"\n',
         '#include "nvs_sec_provider.h"\n#include "esp_attr.h"\n#include "esp_rom_sys.h"\n#include "esp_system.h"\n'),
        ("	bool             needRestart = false;   // see restartWanted()\n",
         "	bool             needRestart = false;   // see restartWanted()\n"
         "\n"
         "	// TEST (virtual-eFuse kit)\n"
         "	RTC_NOINIT_ATTR uint32_t testArmed;\n"
         "	constexpr uint32_t       kTestMagic = 0xC0DE0000;\n"
         "\n"
         "	bool testAt( uint32_t point ) {\n"
         "		if( testArmed != ( kTestMagic | point ) )\n"
         "			return false;\n"
         "		testArmed = 0;\n"
         "		if( point == 5 ) {\n"
         "			ESP_LOGW( TAG, \"TEST: failing the write here\" );\n"
         "			return true;\n"
         "		}\n"
         "		ESP_LOGW( TAG, \"TEST: power cut at point %u\", (unsigned)point );\n"
         "		esp_rom_delay_us( 100000 );\n"
         "		esp_restart();\n"
         "	}\n"),
        ("	bool writeAll( const std::vector<Entry> &entries ) {\n		for( const Entry &entry : entries ) {\n",
         "	bool writeAll( const std::vector<Entry> &entries ) {\n		for( const Entry &entry : entries ) {\n"
         "			if( &entry == &entries[entries.size() / 2] && ( testAt( 3 ) || testAt( 5 ) ) )\n"
         "				return false;\n"),
        ("			ESP_LOGE( TAG, \"Erasing NVS failed: %s\", esp_err_to_name( err ) );\n			return false;\n		}\n",
         "			ESP_LOGE( TAG, \"Erasing NVS failed: %s\", esp_err_to_name( err ) );\n			return false;\n		}\n		testAt( 2 );\n"),
        ("		current = State::Encrypted;\n		if( err != ESP_OK || burned != block )\n",
         "		current = State::Encrypted;\n		testAt( 1 );\n		if( err != ESP_OK || burned != block )\n"),
        ("			return Outcome::Failed;\n		}\n		return Outcome::Encrypted;\n",
         "			return Outcome::Failed;\n		}\n		if( forSetup )\n			testAt( 4 );\n		return Outcome::Encrypted;\n"),
        ("extern \"C\" esp_err_t __wrap_nvs_flash_init( void ) {\n	return SecureNVS::init();\n}\n",
         "#include \"freertos/FreeRTOS.h\"\n#include \"freertos/task.h\"\n"
         "extern \"C\" esp_err_t __wrap_nvs_flash_init( void ) {\n"
         "	esp_err_t err = SecureNVS::init();\n"
         "	ESP_LOGW( TAG, \"TEST: init -> %s, state %s, main task stack left %u\", esp_err_to_name( err ), SecureNVS::stateName(), (unsigned)uxTaskGetStackHighWaterMark( nullptr ) );\n"
         "	return err;\n"
         "}\n"
         "\n"
         "extern \"C\" void nvsTestArm( uint32_t point ) {\n"
         "	testArmed = point ? ( kTestMagic | point ) : 0;\n"
         "	ESP_LOGW( TAG, \"TEST: armed point %u\", (unsigned)point );\n"
         "}\n"),
    ])

    # Improv: test commands 0xF0 to 0xF4.
    patch(os.path.join(src, "Improv.cpp"), [
        ('#include "Text.h"\n',
         '#include "Text.h"\n\n#include "esp_random.h"\n#include "esp_rom_crc.h"\n\n'
         '// TEST (virtual-eFuse kit)\nextern "C" void nvsTestArm( uint32_t point );\nvoid nvsTestMigrate();\nvoid nvsTestFactoryReset();\n'),
        ("		default:\n			sendError( Error::UnknownCommand );\n",
         "		// TEST (virtual-eFuse kit)\n"
         "		case 0xF0:   // arm a simulated power cut (1-4) or failure (5) in SecureNVS; 0 disarms\n"
         "			nvsTestArm( length ? data[0] : 0 );\n"
         "			sendResult( 0xF0, {} );\n"
         "			break;\n"
         "		case 0xF1:   // the bridge's encryptStorage (the device restarts)\n"
         "			sendResult( 0xF1, {} );\n"
         "			nvsTestMigrate();\n"
         "			break;\n"
         "		case 0xF2: {   // what's stored (CRC-32s, not the secrets)\n"
         "			char pw[12], key[12], isNew[2], standard[2], verified[2], paired[2], restart[2];\n"
         "			snprintf( pw, sizeof( pw ), \"%08lx\", (unsigned long)esp_rom_crc32_le( 0, (const uint8_t *)settings_.password(), strlen( settings_.password() ) ) );\n"
         "			snprintf( key, sizeof( key ), \"%08lx\", settings_.isPaired() ? (unsigned long)esp_rom_crc32_le( 0, settings_.pairingKey(), 32 ) : 0ul );\n"
         "			snprintf( isNew, sizeof( isNew ), \"%d\", settings_.isNew() );\n"
         "			snprintf( standard, sizeof( standard ), \"%d\", settings_.standardStorage() );\n"
         "			snprintf( verified, sizeof( verified ), \"%d\", settings_.credentialsWork() );\n"
         "			snprintf( paired, sizeof( paired ), \"%d\", settings_.isPaired() );\n"
         "			snprintf( restart, sizeof( restart ), \"%d\", SecureNVS::restartWanted() );\n"
         "			ESP_LOGW( TAG, \"TEST: dump storage=%s new=%s standard=%s pw=%s verified=%s paired=%s key=%s restart=%s\", SecureNVS::stateName(), isNew, standard, pw, verified, paired, key, restart );\n"
         "			sendResult( 0xF2, { SecureNVS::stateName(), isNew, standard, settings_.ssid(), pw, verified, paired, key, settings_.name(), restart } );\n"
         "			break;\n"
         "		}\n"
         "		case 0xF3: {   // a made-up pairing, so there's a pairing key to move\n"
         "			uint8_t key[32];\n"
         "			esp_fill_random( key, sizeof( key ) );\n"
         "			settings_.setPairing( key, \"nvstest-bridge\" );\n"
         "			memset( key, 0, sizeof( key ) );\n"
         "			sendResult( 0xF3, {} );\n"
         "			break;\n"
         "		}\n"
         "		case 0xF4:   // factory reset (the device restarts)\n"
         "			sendResult( 0xF4, {} );\n"
         "			nvsTestFactoryReset();\n"
         "			break;\n"
         "\n"
         "		default:\n			sendError( Error::UnknownCommand );\n"),
    ])

    with open(os.path.join(src, "main.cpp"), "a") as f:
        f.write("\n// TEST (virtual-eFuse kit)\n"
                "void nvsTestMigrate();\nvoid nvsTestFactoryReset();\n\n"
                "void nvsTestMigrate() {\n\tencryptStorage();\n}\n\n"
                "void nvsTestFactoryReset() {\n\tfactoryReset( \"test\" );\n}\n")

    print(f"prepare: test project ready in {work}")


main()
