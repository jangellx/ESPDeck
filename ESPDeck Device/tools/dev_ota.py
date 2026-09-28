# For the espdeck-dev environment only: the ArduinoOTA password, from the git-ignored
# ota_password.txt next to platformio.ini or the ESPDECK_OTA_PASSWORD environment variable.
# It's compiled in (ESPDECK_OTA_PASSWORD) and given to espota for uploads. The build stops
# without one, so a dev build never accepts uploads from anyone on the network.
import os
import sys

Import( "env" )

path     = os.path.join( env.subst( "$PROJECT_DIR" ), "ota_password.txt" )
password = os.environ.get( "ESPDECK_OTA_PASSWORD", "" ).strip()
if not password and os.path.exists( path ):
	with open( path ) as file:
		password = file.read().strip()

if not password:
	sys.stderr.write( "\nError: espdeck-dev needs an OTA password. Put one in ota_password.txt next to platformio.ini "
					  "(it's git-ignored), or set ESPDECK_OTA_PASSWORD.\n\n" )
	env.Exit( 1 )
if len( password ) < 8 or any( c.isspace() or c in "\"'\\$`" for c in password ):
	sys.stderr.write( "\nError: the OTA password needs at least 8 characters, without spaces, quotes, backslashes, $ or `.\n\n" )
	env.Exit( 1 )

env.Append( BUILD_FLAGS = [ '-DESPDECK_OTA_PASSWORD=\\"%s\\"' % password ] )

# The espota uploader's flags are set after this script runs, so add the password just before
# uploading. An upload over USB (a serial port as upload_port) goes through esptool instead.
def add_password( source, target, env ):
	if "espota" in env.subst( "$UPLOADER" ):
		env.Append( UPLOADERFLAGS = [ "--auth=" + password ] )

env.AddPreAction( "upload", add_password )
