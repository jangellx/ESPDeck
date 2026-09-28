# Uploads over Wi-Fi (`pio run -t upload --upload-port espdeck-eeff.local`, which PlatformIO
# sends with espota): adds the password the device was given in ESPDeck Bridge (Device ▸
# Developer), read from the git-ignored ota_password.txt next to platformio.ini or from the
# ESPDECK_OTA_PASSWORD environment variable. Builds and USB uploads don't need it.
import os
import sys

Import( "env" )

def password():
	value = os.environ.get( "ESPDECK_OTA_PASSWORD", "" ).strip()
	path  = os.path.join( env.subst( "$PROJECT_DIR" ), "ota_password.txt" )
	if not value and os.path.exists( path ):
		with open( path ) as file:
			value = file.read().strip()
	return value

# espota's flags are set after this script runs, so add the password just before uploading.
def add_password( source, target, env ):
	if "espota" not in env.subst( "$UPLOADER" ):
		return
	value = password()
	if not value:
		sys.stderr.write( "\nError: uploading over Wi-Fi needs the device's upload password. Put it in ota_password.txt "
						  "next to platformio.ini (it's git-ignored), or set ESPDECK_OTA_PASSWORD. Set the same password "
						  "in ESPDeck Bridge: the device's Device page, Developer section.\n\n" )
		env.Exit( 1 )
	env.Append( UPLOADERFLAGS = [ "--auth=" + value ] )

env.AddPreAction( "upload", add_password )
