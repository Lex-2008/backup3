#!/bin/false
# This file should be sourced, not ran!
#
# Common stuff

test -z "$BACKUP_BIN"     && BACKUP_BIN="${0%/*}"
test -z "$BACKUP_CONFIG"  && BACKUP_CONFIG="$BACKUP_BIN/local.sh"
test -f "$BACKUP_CONFIG"  && . "$BACKUP_CONFIG"

test -z "$BACKUP_ROOT"    && exit 2
test -d "$BACKUP_ROOT"    || exit 3

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_WAIT_FLOCK" # this is fine
test -z "$BACKUP_TMP"     && BACKUP_TMP=$BACKUP_ROOT/tmp
test -z "$BACKUP_KEEP_TMP" # this is fine
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$PARTIAL_DIR"    && PARTIAL_DIR=$BACKUP_ROOT/partial
test -z "$BACKUP_RSYNC_LOGS" && BACKUP_RSYNC_LOGS=$BACKUP_ROOT/rsync.logs
test -z "$BACKUP_LOCAL_LOGS" # this is fine, must NOT contain spaces
test -z "$BACKUP_RSYNC_STATS" && BACKUP_RSYNC_STATS=$BACKUP_ROOT/rsync.stats
test -z "$BACKUP_FIND_FILTER" # this is fine
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_FORMAT" && BACKUP_TIME_FORMAT="%F %H:%M"
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"$BACKUP_TIME_FORMAT")"
test -z "$BACKUP_SCAN_TIMEOUT" && BACKUP_SCAN_TIMEOUT="10" # 10 sec
test -z "$BACKUP_TIMEOUT" && BACKUP_TIMEOUT="3600" # 1h
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~" # must be regexp-safe
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now # must be 'now' or valid date in future
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640
test -z "$BACKUP_CLEAN_ON" && BACKUP_CLEAN_ON=post # 'pre', 'post', or 'none'
test -z "$BACKUP_CLEAN_VAL" && BACKUP_CLEAN_VAL="10"
test -z "$BACKUP_CLEAN_VAR" && BACKUP_CLEAN_VAR="%" # '%' or 'G'
test -z "$BACKUP_CLEAN_BY_FREQ" && BACKUP_CLEAN_BY_FREQ=1
test -z "$SQLITE"         && SQLITE="sqlite3 $BACKUP_DB"

test -z "$HARDLINK"       && HARDLINK=none # "strict" or "loose"
test -z "$HARDLINK_DIR"   && HARDLINK_DIR="$BACKUP_ROOT/by-date"
test -z "$HARDLINK_m"     && HARDLINK_m=0 # monthly - 12 for a year
test -z "$HARDLINK_d"     && HARDLINK_d=0 # daily - 7 for 1 week
test -z "$HARDLINK_h"     && HARDLINK_h=0 # hourly - 24 for 1 day

test -z "$CLEAN_BY_FREQ"  && CLEAN_BY_FREQ="1" # set to 0 to ignore freq when cleaning

test -z "$BACKUP_PAR2_SIZELIMIT" && BACKUP_PAR2_SIZELIMIT=300000 # minimum file size to create *.par2 archive, smaller files are copied to *.bak ones as-is
test -z "$BACKUP_PAR2_CPULIMIT" && BACKUP_PAR2_CPULIMIT=0 # limit CPU usage by par2 process
test -z "$BACKUP_PAR2_TIMEOUT" && BACKUP_PAR2_TIMEOUT='30 min'
test -z "$BACKUP_PAR2_LOG" && BACKUP_PAR2_LOG=$BACKUP_ROOT/par2.log

# 2592000 is number of seconds / month
# BACKUP_MAX_FREQ is number of events / month
# hence 2592000/BACKUP_MAX_FREQ is number of seconds / event
# usually 300 seconds for BACKUP_MAX_FREQ=8640 (5 minutes)
BACKUP_MAX_FREQ_SEC="$(( 2592000 / BACKUP_MAX_FREQ ))"

HARDLINK_EXPR="
WHEN 1 THEN strftime('%Y-%m', 'now', 'localtime', 'start of month', '+1 month', '-$HARDLINK_m months')
WHEN 30 THEN strftime('%Y-%m-%d', 'now', 'localtime', '+1 day', '-$HARDLINK_d days')
WHEN 720 THEN strftime('%Y-%m-%d %H', 'now', 'localtime', '+1 hour', '-$HARDLINK_h hours')"

# Figure out `timeout` command
if type timeout >/dev/null; then
    if timeout --help 2>&1 | head -n1 | grep -q 'BusyBox v1.2'; then
        # busybox before 1.30 required -t argument before time
        TIMEOUT='timeout -t'
    else
        # modern implementations of timeout accept seconds as first argument
        TIMEOUT=timeout
    fi
else
    # use shell implementation
    TIMEOUT="$BACKUP_BIN/timeout.sh"
fi

NL="
"
# `find` replacement, which scans a given dir and for each object found it prints:
# * its inode number
# * its type ('f' for file, 'd' for dir, 's' for others)
# * its name
# all in one line
# Arguments:
# * dir to `cd` prior to `find`
# * dirname and other filters to pass to `find`
my_find()
{
	cd "$1"
	shift
	if test -f "$(type -p find)" && "$(type -p find)" --version 2>&1 | grep -q GNU; then
		"$(type -p find)" "$@" -printf '%i %y %h/%f\n'
	else
		sed='s/^([0-9]*) regular( empty)? file /\1 f /
		     s/^([0-9]*) directory /\1 d /
		     s_^([0-9]*) d .$_\1 d ./._
		     t
		     s/^([0-9]*) [^.]* /\1 s /'
		find "$@" | while IFS="$NL" read -r f; do
        # TODO: if neither GNU find, nor `stat` are available, use `ls -li | sed`
        # (assuming ls can inodes)
			stat -c '%i %F %n' "$f"
		done | sed -r "$sed"
	fi
	cd -> /dev/null
}

# check if there is another copy of this script running
lock_available()
{
	test ! -f "$BACKUP_FLOCK" && return 0
	pid="$(cat "$BACKUP_FLOCK")"
	test ! -d "/proc/$pid" && { rm "$BACKUP_FLOCK"; return 0; }
	test ! -f "/proc/$pid/fd/200" && { echo "process $pid does not have FD 200"; rm "$BACKUP_FLOCK"; return 0; }
  expr "$(readlink /proc/$pid/fd/200)" : "$BACKUP_FLOCK" >/dev/null || { echo "$0: process $pid ($(cat /proc/$pid/cmdline)) has FD 200 pointing to [$(readlink /proc/$pid/fd/200)] - expected [$BACKUP_FLOCK]"; rm "$BACKUP_FLOCK"; return 0; }
	return 1
}
acquire_lock()
{
	if ! lock_available; then
		test -z "$BACKUP_WAIT_FLOCK" && exit 200
		while ! lock_available; do sleep 1; done
	fi
	# acquire lock
	exec 200>"$BACKUP_FLOCK"
	echo "$$">&200
	# check that we indeed got the lock
	sleep 1
	if test "$(cat "$BACKUP_FLOCK")" != "$$"; then
		echo "lock was stolen from $$ by $(cat "$BACKUP_FLOCK"), retrying..."
		acquire_lock
	fi
}

check_db()
{
	echo .schema | $SQLITE | grep -q history || exit 1
}
