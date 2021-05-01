#!/bin/bash
set -o pipefail

########################################################################
#
#   Project page: https://github.com/auanasgheps/snapraid-aio-script
#
########################################################################

######################
#   CONFIG VARIABLES #
######################
SNAPSCRIPTVERSION="2.9.0.DEV2"
SNAPRAIDVERSION="$(snapraid -V | sed 's/snapraid v\(.*\)by.*/\1/')"

CURRENT_DIR=$(dirname "${0}")
CONFIG_FILE=$CURRENT_DIR/script-config.sh
# shellcheck source=script-config.sh
source "$CONFIG_FILE"

# Array of snapraid commands completed by the the script.
JOBS=()
SYNC_ERR="UNK"
SCRUB_ERR="UNK"

######################
#   MAIN SCRIPT      #
######################

function main(){
  # create tmp file for output
  true > "$TMP_OUTPUT"

  # Redirect all output to file and screen. Starts a tee process
  output_to_file_screen

  # timestamp the job
  elog INFO "SnapRAID Script Job started."
  elog INFO "Running SnapRAID version $SNAPRAIDVERSION"
  elog INFO "SnapRAID AIO Script version $SNAPSCRIPTVERSION"

  mkdwn_ruler
  mkdwn_h2 "Preprocessing"

  find_config
  install_markdown
  sanity_check

  mkdwn_ruler
  mkdwn_h2 "Processing"

  run_diff

  mkdwn_h3 "SnapRAID SYNC"
  if is_sync_needed; then
    run_sync
  fi

  mkdwn_h3 "SnapRAID SCRUB"
  if is_scrub_needed; then
    run_delayed_scrub
  fi

  mkdwn_ruler
  mkdwn_h2 "Postprocessing"
  run_touch
  if ((SMART_LOG)); then run_smart; fi
  if ((SMART_STATUS)); then run_status; fi
  if ((SMART_SPINDDOWN)); then run_spindown; fi
  elog INFO "All jobs ended."
  mkdwn_ruler
  mkdwn_h2 "Total time elapsed for SnapRAID: $(elapsed)"

  if [[ -z "$EMAIL_ADDRESS" ]]; then
    exit
  fi
  echo -e "Email address is set. Sending email report to **$EMAIL_ADDRESS**"
  # check if deleted count exceeded threshold
  prepare_mail
  # Add a topline to email body
  sed_me "1s:^:##$SUBJECT \n:" "${TMP_OUTPUT}"
  if ((VERBOSITY)); then
    send_mail < "$TMP_OUTPUT"
  else
    trim_log < "$TMP_OUTPUT" | send_mail
  fi
}

#######################
# FUNCTIONS & METHODS #
#######################

function find_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    elog WARN "Script configuration file not found! The script cannot be run!"\
        "Please check and try again!"
    exit 1;
  fi
  elog INFO "Configuration file found! Proceeding."
}

function install_markdown() {
  if ! (dpkg-query -W -f='${Status}' python-markdown | grep -q "ok installed") 2>/dev/null
  then
    elog WARN "**Markdown has not been found and will be installed.**"
    # super silent and secret install command
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -qq -o=Dpkg::Use-Pty=0 python-markdown;
  fi
}

# Sanity check first to make sure we can access the content and parity files.
function sanity_check() {
  elog INFO "Checking SnapRAID disks."
  if [[ ! -e "$CONTENT_FILE" ]]; then
    elog ERROR "**ERROR** Content file ($CONTENT_FILE) not found!"
    elog ERROR "**ERROR** Please check the status of your disks!"\
        "The script exits here due to missing file or disk..."
    prepare_mail
    # Add a topline to email body
    sed_me "1s:^:##$SUBJECT \n:" "${TMP_OUTPUT}"
    trim_log < "$TMP_OUTPUT" | send_mail
    exit 1;
  fi
  elog INFO "Testing that all parity files are present."
  for i in "${PARITY_FILES[@]}"; do
    if [[ ! -e "$i" ]]; then
      elog ERROR "**ERROR** Parity file ($i) not found!"
      elog ERROR "**ERROR** Please check the status of your disks!"\
          "The script exits here due to missing file or disk..."
      prepare_mail
      # Add a topline to email body
      sed_me "1s:^:##$SUBJECT \n:" "${TMP_OUTPUT}"
      trim_log < "$TMP_OUTPUT" | send_mail
      exit;
    fi
  done
  echo "All parity files found. Continuing..."
}

function run_diff(){
  JOBS+=("DIFF")
  mkdwn_h3 "SnapRAID DIFF"
  elog INFO "DIFF Job started."
  snapraid_cmd diff
  elog INFO "DIFF finished."
}

function is_sync_needed() {
  local del_count; del_count=$(get_diff_count "removed")
  local update_count; update_count=$(get_diff_count "updated")
  local add_count; add_count=$(get_diff_count "added")
  local move_count; move_count=$(get_diff_count "moved")
  local copy_count; copy_count=$(get_diff_count "copied")

  # Sanity check to all counts from the output of the DIFF job.
  if [[ -z "$del_count" || -z "$add_count" || -z "$move_count" ||
        -z "$copy_count" || -z "$update_count" ]]; then
    # Failed to get one or more of the count values, report to user and exit
    # with error code.
    elog ERROR "**ERROR** Failed to get one or more count values. Unable to proceed."
    SUBJECT="$EMAIL_SUBJECT_PREFIX WARNING - Unable to proceed with"\
        "SYNC/SCRUB job(s). Check DIFF job output."
    send_mail < "$TMP_OUTPUT"
    exit 1;
  fi
  elog INFO "**SUMMARY of changes - Added [$add_count] - Deleted [$del_count]"\
      "- Moved [$move_count] - Copied [$copy_count] - Updated [$update_count]**"

  # With no recent changes, the SYNC can be skipped.
  if (((del_count + add_count + move_count + copy_count + update_count) == 0)); then
    elog INFO "No change detected. Not running SYNC job."
    false
    return
  fi
  # Before sync, check if thresholds were reached and prepare email $SUBJECT
  local do_sync;
  if is_del_threshld "$del_count" || is_updated_threshld "$update_count"; then
    do_sync=$(is_force_sync_due_to_warn_threshld; echo $?)
    SUBJECT=$(gen_email_warning_subject "$del_count" "$update_count" "$do_sync")
  else
    do_sync=$(true; echo $?)
  fi
  return "$do_sync"
}

function get_diff_count(){
  local count_name=$1
  grep -w '^ \{1,\}[0-9]* '"$count_name" "$TMP_OUTPUT" |
    sed 's/^ *//g' | cut -d ' ' -f1
}

function is_del_threshld(){
  local del_count=$1
  if ((del_count >= DEL_THRESHOLD)); then
    elog WARN "**WARNING** Deleted files ($del_count)"\
        "reached/exceeded threshold ($DEL_THRESHOLD)."
    return
  elif ((del_count == 0)); then
    echo "There are no deleted files, that's fine."
  else
    echo "There are deleted files. The number of deleted files"\
        "($del_count) is below the threshold of ($DEL_THRESHOLD)."
  fi
  false
}

function is_updated_threshld(){
  local update_count=$1
  if ((update_count >= UP_THRESHOLD)); then
    elog WARN "**WARNING** Updated files ($update_count)"\
        "reached/exceeded threshold ($UP_THRESHOLD)."
    return
  elif ((update_count == 0)); then
    echo "There are no updated files, that's fine."
  else
    echo "There are updated files. The number of updated files"\
        "($update_count) is below the threshold of ($UP_THRESHOLD)."
  fi
  false
}

# After a number of sequential warnings, it's possible to allow a sync anyway
# if the config SYNC_WARN_THRESHOLD is >= 0.
function is_force_sync_due_to_warn_threshld(){
  local sync_warn_count
  if ((SYNC_WARN_THRESHOLD < 0)); then
    # Safest option, never force a sync.
    elog INFO "Forced sync is not enabled. Check $TMP_OUTPUT for details."\
        "**NOT** proceeding with SYNC job."
    false
    return
  fi

  if ((SYNC_WARN_THRESHOLD == 0)); then
    elog INFO "Forced sync is enabled."
    return
  fi

  elog INFO "Sync after threshold warning(s) is enabled."
  sync_warn_count=$(sed '/^[0-9]*$/!d' "$SYNC_WARN_FILE" 2>/dev/null)
  # Zero if file does not exist or did not contain a number.
  : "${sync_warn_count:=0}"
  if ((sync_warn_count >= SYNC_WARN_THRESHOLD)); then
    # Output a message and force a sync job.  Do not need to remove warning
    # counter here as it is automatically removed when the sync job is run by
    # this script.
    elog INFO \
        "Number of threshold warning(s) ($sync_warn_count) has reached/exceeded"\
        "threshold ($SYNC_WARN_THRESHOLD). Forcing a SYNC job to run."
    return
  fi

  # Increment the warning counter and skip the sync job.
  ((sync_warn_count += 1))
  echo "$sync_warn_count" > "$SYNC_WARN_FILE"
  if ((sync_warn_count == SYNC_WARN_THRESHOLD)); then
    elog INFO "This is the **last** warning left. **NOT** proceeding with SYNC job."
  else
    elog INFO "$((SYNC_WARN_THRESHOLD - sync_warn_count)) threshold"\
        "warning(s) until the next forced sync. **NOT** proceeding with SYNC job."
  fi
  false
}

function gen_email_warning_subject(){
  local del_count=$1 update_count=$2 force_sync=$3
  local msg
  if (exit "$force_sync"); then
    if ((del_count >= DEL_THRESHOLD)); then
      msg="Forced sync with deleted files ($del_count) / ($DEL_THRESHOLD) violation"
    fi
    if ((update_count >= UP_THRESHOLD)); then
      msg="Forced sync with changed files ($update_count) / ($UP_THRESHOLD) violation"
    fi
    if ((del_count >= DEL_THRESHOLD && update_count >= UP_THRESHOLD)); then
      msg="Sync forced with multiple violations - Deleted files"\
          " ($del_count) / ($DEL_THRESHOLD) and changed files"\
          " ($update_count) / ($UP_THRESHOLD)"
    fi
  else
    if ((del_count >= DEL_THRESHOLD)); then
      msg="Deleted files ($del_count) / ($DEL_THRESHOLD) violation"
    fi
    if ((update_count >= UP_THRESHOLD)); then
      msg="Changed files ($update_count) / ($UP_THRESHOLD) violation"
    fi
    if ((del_count >= DEL_THRESHOLD && update_count >= UP_THRESHOLD)); then
      msg="Multiple violations - Deleted files ($del_count) /"\
          " ($DEL_THRESHOLD) and changed files ($update_count) / ($UP_THRESHOLD)"
    fi
  fi
  echo "[WARNING] $msg $EMAIL_SUBJECT_PREFIX"
}

function run_sync(){
  local hash_arg; hash_arg=$( ((PREHASH)) && echo "-h")
  JOBS+=("SYNC")
  elog INFO "SYNC Job started."
  snapraid_cmd sync -q "$hash_arg"
  SYNC_ERR=$?
  rm -f "$SYNC_WARN_FILE" # Clear warning counter if set previously.
}

function is_scrub_needed(){
  if ((SCRUB_PERCENT == 0)); then
    elog INFO "Scrub job is not enabled. Not running SCRUB job."
    false
    return
  elif ! contains SYNC "${JOBS[@]}" && ((THRESH_WARNING)); then
    elog INFO "Scrub job is cancelled as parity info is out of sync"\
        "(deleted or changed files threshold has been breached)."
    false
    return
  elif ((SYNC_ERR)); then
    elog WARN "**WARNING** - check output of SYNC job. Failure detected."\
        "Not proceeding with SCRUB job."
    false
    return
  fi
  ! is_scrub_delayed
}

# Check if scrub delayed run is enabled and return True if the scrub should be
# skipped.
function is_scrub_delayed(){
	local scrub_count
	((SCRUB_DELAYED_RUN)) && elog INFO "Delayed scrub is enabled."
  scrub_count=$(sed '/^[0-9]*$/!d' "$SCRUB_COUNT_FILE" 2>/dev/null)
  # zero count if file does not exist or did not contain a number
  : "${scrub_count:=0}"
	if ((scrub_count < SCRUB_DELAYED_RUN)); then
    # YES, so let's increment the warning count and skip the scrub job.
    ((scrub_count += 1))
    echo "$scrub_count" > "$SCRUB_COUNT_FILE"
    if ((scrub_count == SCRUB_DELAYED_RUN)); then
      elog INFO "This is the **last** run left before running scrub job next time."
    else
      elog INFO "$((SCRUB_DELAYED_RUN - scrub_count)) runs until the next"\
          "scrub. **NOT** proceeding with SCRUB job."
    fi
    return
  fi
  # NO, run a scrub job.
  if ((scrub_count > 0)); then
    # If there is at least one warn count, output a message.  Do not need to
    # remove warning marker here as it is automatically removed when the scrub
    # job is run by this script.
    elog INFO "Number of delayed runs has reached/exceeded threshold"\
        "($SCRUB_DELAYED_RUN). A SCRUB job will run."
  fi
  false
}

function run_scrub(){
  JOBS+=("SCRUB")
  elog INFO "SCRUB Job started."
  snapraid_cmd scrub -p $SCRUB_PERCENT -o $SCRUB_AGE -q
  SCRUB_ERR=$?
  rm -f "$SCRUB_COUNT_FILE" # Clear warning counter if set previously.
}

function run_touch(){
  mkdwn_h3 "SnapRAID TOUCH"
  elog INFO "TOUCH started."
  echo "Checking for zero sub-second files."
  TIMESTATUS=$($SNAPRAID_BIN status |
      grep 'You have [1-9][0-9]* files with zero sub-second timestamp\.' |
      sed 's/^You have/Found/g')
  if [[ -n "$TIMESTATUS" ]]; then
    echo "$TIMESTATUS"
    echo "Running TOUCH job to timestamp."
    snapraid_cmd touch
  else
    echo "No zero sub-second timestamp files found."
  fi
  elog INFO "TOUCH finished."
}

function run_smart() {
  mkdwn_h3 "SnapRAID SMART"
  snapraid_cmd smart
}

function run_status() {
  mkdwn_h3 "SnapRAID STATUS"
  snapraid_cmd status
}

function run_spindown() {
  mkdwn_h3 "SnapRAID SPINDOWN"
  snapraid_cmd down

  # Spinning down disks (Method 2: hdparm - spins down all rotational devices)
  # if [ $SPINDOWN -eq 1 ]; then
  # for DRIVE in `lsblk -d -o name | tail -n +2`
  #   do
  #     if [[ `smartctl -a /dev/$DRIVE | grep 'Rotation Rate' | grep rpm` ]]; then
  #       hdparm -Y /dev/$DRIVE
  #     fi
  #   done
  # fi

  # Spinning down disks (Method 3: hd-idle - spins down all rotational devices)
  # if [ $SPINDOWN -eq 1 ]; then
  # for DRIVE in `lsblk -d -o name | tail -n +2`
  #   do
  #     if [[ `smartctl -a /dev/$DRIVE | grep 'Rotation Rate' | grep rpm` ]]; then
  #       echo "spinning down /dev/$DRIVE"
  #       hd-idle -t /dev/$DRIVE
  #     fi
  #   done
  # fi
}

function prepare_mail() {
  if (contains SYNC "${JOBS[@]}" ) && ((SYNC_ERR)); then
    # Sync ran but did not complete successfully so lets warn the user
    SUBJECT="[WARNING] SYNC job ran but did not complete successfully"
  elif (contains SCRUB "${JOBS[@]}" ) && ((SCRUB_ERR)); then
    # Scrub ran but did not complete successfully so lets warn the user
    SUBJECT="[WARNING] SCRUB job ran but did not complete successfully"
  else
    SUBJECT="[COMPLETED] $(joinby '+' "${JOBS[@]}") Jobs"
  fi
  SUBJECT+=" $EMAIL_SUBJECT_PREFIX"
}

# Remove the verbose output of TOUCH and DIFF commands to make the email more
# concise.
function trim_log(){
  sed '
    /^### SnapRAID TOUCH/,/^\TOUCH finished/{
      /^### SnapRAID TOUCH/!{/^TOUCH finished/!d}
    };
    /^### SnapRAID DIFF/,/^\DIFF finished/{
      /^### SnapRAID DIFF/!{/^DIFF finished/!d}
    }'
}

# Process and mail the email body read from stdin.
function send_mail(){
  if [[ -z "$EMAIL_ADDRESS" ]]; then
    return
  fi
  local body; body=$(cat)
  # Send the raw $body and append the HTML.
  # Try to workaround py markdown 2.6.8 issues:
  # 1. Will not format code blocks with empty lines, so just remove
  #    them.
  # 2. A dash line inside of code block brekas it, so remove it.
  # 3. Add trailing double-spaces ensures the line endings are
  #    maintained.
  # 4. The HTML code blocks need to be modified to use <pre></pre> to display
  #    correctly.
  $MAIL_BIN -a 'Content-Type: text/html' -s "$SUBJECT" "$EMAIL_ADDRESS" \
    < <(echo "$body" | sed '/^[[:space:]]*$/d; /^ -*$/d; s/$/  /' |
      python -m markdown |
      sed 's/<code>/<pre>/;s%</code>%</pre>%')
}

# Run a snapraid command; manage output redirection.
function snapraid_cmd() {
  local start=$SECONDS
  mkdwn_codeblk
  $SNAPRAID_BIN "$@"
  local status=$?
  close_output_and_wait
  output_to_file_screen
  mkdwn_codeblk
  echo "Waited for $(elapsed $start)."
  (exit $status)
}

# Due to how process substitution and newer bash versions work, this function
# stops the output stream which allows wait stops wait from hanging on the tee
# process. If we do not do this and use normal 'wait' the processes will wait
# forever as newer bash version will wait for the process substitution to
# finish. Probably not the best way of 'fixing' this issue. Someone with more
# knowledge can provide better insight.
function close_output_and_wait(){
  local pid
  exec >& "$OUT" 2>& "$ERROR"
  for pid in $(pgrep -P $$); do
    wait "$pid"
  done
}

# Redirects output to file and screen. Open a new tee process.
function output_to_file_screen(){
  # redirect all output to screen and file
  exec {OUT}>&1 {ERROR}>&2
  # NOTE: Not preferred format but valid: exec &> >(tee -ia "${TMP_OUTPUT}" )
  exec > >(tee -a "${TMP_OUTPUT}") 2>&1
}

function sed_me(){
  # Close the open output stream first, then perform sed and open a new tee
  # process and redirect output. We close stream because of the calls to new
  # wait function in between sed_me calls. If we do not do this we try to close
  # Processes which are not parents of the shell.
  exec >& "$OUT" 2>& "$ERROR"
  sed -i "$1" "$2"
  output_to_file_screen
}

# "echo and log"; send messages to STDOUT and /var/log/, where $1 is the
# log level and $2 is the message.
function elog() {
  local priority=$1 message=$2
  echo "$message"
  echo "$(date '+[%Y-%m-%d %H:%M:%S]') $priority: $message" >> "$SNAPRAID_LOG"
}

# Print the elapsed time since $start (default 0)
function elapsed() {
  local start=${1:-0}
  local elapsed=$((SECONDS - start))
  if ((elapsed > 0)); then
    echo "$((elapsed / 3600))hrs $(((elapsed / 60) % 60))min $((elapsed % 60))sec"
  else
    echo "a jiffy"
  fi
}

function contains(){
  local x match=$1; shift
  for x; do [[ "$x" == "$match" ]] && return; done
  false
}

function joinby(){
  local sep=$1; shift
  out=$(printf "$sep"'%s' "$@")
  echo "${out:1}" # Remove leading seperator.
}

# Common markdown formatting features.
function mkdwn_ruler() { echo "----"; }
function mkdwn_codeblk() { echo "\`\`\`"; }
function mkdwn_h2() { echo "## $*"; }
function mkdwn_h3() { echo "### $*"; }

main "$@"
