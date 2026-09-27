# PlatformIO's ESP-IDF builder drops prebuilt archives that a managed component links with
# target_link_libraries() when the component lives in the project, so esp_new_jpeg's encoder
# library never reaches the linker. Add it by hand.
import os

Import( "env" )

library = os.path.join( env.subst( "$PROJECT_DIR" ), "managed_components", "espressif__esp_new_jpeg",
                        "lib", env.BoardConfig().get( "build.mcu" ), "libesp_new_jpeg.a" )
env.Append( LIBS = [ env.File( library ) ] )
