######################
#   USER VARIABLES   #
######################

####################### USER CONFIGURATION START #######################

# address where the output of the jobs will be emailed to.
EMAIL_ADDRESS="youremailgoeshere"

# Set the threshold of deleted files to stop the sync job from running. NOTE
# that depending on how active your filesystem is being used, a low number here
# may result in your parity info being out of sync often and/or you having to
# do lots of manual syncing.
DEL_THRESHOLD=500
UP_THRESHOLD=500

# Set number of warnings before we force a sync job. This option comes in handy
# when you cannot be bothered to manually start a sync job when DEL_THRESHOLD
# is breached due to false alarm. Set to 0 to ALWAYS force a sync (i.e. ignore
# the delete threshold above) Set to -1 to NEVER force a sync (i.e. need to
# manual sync if delete threshold is breached).
SYNC_WARN_THRESHOLD=-1

# Set percentage of array to scrub if it is in sync. i.e. 0 to disable and 100
# to scrub the full array in one go WARNING - depending on size of your array,
# setting to 100 will take a very long time!
SCRUB_PERCENT=5
SCRUB_AGE=10

# Set number of script runs before running a scrub. Use this option if you
# don't want to scrub the array every time.
# Set to 0 to disable this option and run scrub every time.
SCRUB_DELAYED_RUN=0

# List of external scripts or commands to run before a sync job. The scripts
# will only run if a sync job is allowed. If any script is not found or
# returns an error, the sync iob will not proceed.
PRE_SYNC_COMMAND_LIST=()

# Prehash Data To avoid the risk of a latent hardware issue, you can enable the
# "pre-hash" mode and have all the data read two times to ensure its integrity.
# This option also verifies the files moved inside the array, to ensure that
# the move operation went successfully, and in case to block the sync and to
# allow to run a fix operation. 1 to enable, any other values to disable.
PREHASH=1

# Set the option to log SMART info. 1 to enable, any other value to disable.
SMART_LOG=1

# Set verbosity of the email output. TOUCH and DIFF outputs will be kept in the
# email, producing a potentially huge email. Keep this disabled for optimal
# reading You can always check TOUCH and DIFF outputs using the TMP file. 1 to
# enable, any other values to disable.
VERBOSITY=0

# Set if disk spindown should be performed. Depending on your system, this may
# not work. 1 to enable, any other values to disable.
SPINDOWN=0

# Run snapraid status command to show array general information.
SNAP_STATUS=0

# location of the snapraid binary
SNAPRAID_BIN="/usr/bin/snapraid"

# location of the mail program binary
MAIL_BIN="/usr/bin/mailx"

####################### USER CONFIGURATION END #######################

####################### SYSTEM CONFIGURATION #######################
# Make changes only if you know what you're doing

# Init variables
EMAIL_SUBJECT_PREFIX="(SnapRAID on $(hostname))"
SYNC_WARN_FILE="$CURRENT_DIR/snapRAID.warnCount"
SCRUB_COUNT_FILE="$CURRENT_DIR/snapRAID.scrubCount"
TMP_OUTPUT="/tmp/snapRAID.out"
SNAPRAID_LOG="/var/log/snapraid.log"
SNAPRAID_CONF="/etc/snapraid.conf"

# Determine names of first content file...
SNAPRAID_CONF_LINES=$(grep -E '^[^#;]' $SNAPRAID_CONF)
CONTENT_FILE=$(echo "$SNAPRAID_CONF_LINES" | grep snapraid.content | head -n 1 | cut -d ' ' -f2)

# Build an array of parity all files...
PARITY_FILES=(
  $(echo "$SNAPRAID_CONF_LINES" | grep -E '^([2-6z]-)*parity' | cut -d ' ' -f2- | tr ',' '\n')
)
