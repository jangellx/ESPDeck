FILE(GLOB_RECURSE app_sources ${CMAKE_SOURCE_DIR}/src/*.*)

idf_component_register(SRCS ${app_sources}
                       INCLUDE_DIRS ".")

# Arduino's initArduino() sets NVS up with nvs_flash_init() before setup(); SecureNVS takes
# that call over, so an encrypted device's NVS is opened encrypted (see SecureNVS.h).
target_link_libraries(${COMPONENT_LIB} INTERFACE "-Wl,--wrap=nvs_flash_init")
