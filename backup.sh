#!/bin/busybox ash
#
# Main backup script.

test -z "$BACKUP_BIN" && BACKUP_BIN="${0%/*}"
. "$BACKUP_BIN/common.sh"
acquire_lock

### RSYNC ###

# run rsync to backup every $1 from $2 to $3, with $3 extra arguments
run_rsync()
{
	when="$1"
	to="$2"
	from="$3"
	shift 3
	if test -z "$BACKUP_LOCAL_LOGS" ; then
		logfile="$BACKUP_RSYNC_LOGS/$to.log"
	else
		logfile="$BACKUP_CURRENT/$to/$BACKUP_LOCAL_LOGS"
		rsync_logfile_exclude="--exclude=$BACKUP_LOCAL_LOGS"
	fi
	statsfile="$BACKUP_RSYNC_STATS/$to.log"
	case "$when" in
		( hourly )	date_fmt="%F %H" ;;
		( daily )	date_fmt="%F" ;;
		( weekly )	date_fmt="%Y %W" ;;
		( monthly )	date_fmt="%Y-%m" ;;
		( * )    	date_fmt="%F %T" ;;
	esac
	# test if we need to run it at all - or not enough time had passed
	test "$(date -r "$logfile" +"$date_fmt" 2>/dev/null)" = "$(date -d "$BACKUP_TIME" +"$date_fmt")" && return 0
	# test if we can connect
	test -d "$from" || timeout $TIMEOUT_ARG "$BACKUP_SCAN_TIMEOUT" rsync "$@" $RSYNC_EXTRA "$from" >/dev/null 2>&1 || return 0
	if test -n "$BACKUP_LOCAL_LOGS"; then
		# ensure that logfile inode changes
		mv "$logfile" "$BACKUP_RSYNC_LOGS"
	fi
	# sync files
	timeout $TIMEOUT_ARG "$BACKUP_TIMEOUT" rsync -a --itemize-changes --human-readable --stats --delete --partial-dir="$PARTIAL_DIR/$to" $rsync_logfile_exclude "$@" $RSYNC_EXTRA "$from" "$BACKUP_CURRENT/$to" >"$logfile" 2>&1
	# add them to DB
	compare "$to"
	# create stats file if it doesn't exist
	test -f "$statsfile" || ( echo "date"; sed '/Number of created files/,/^$/!d;s/: .*//' "$logfile" ) | tr '\n' '\t' >"$statsfile"
	# summarise rsync stats
	echo >>"$statsfile"
	( echo "$BACKUP_TIME"; sed '/Number of created files/,/^$/!d;s/[^:]*: //' "$logfile" ) | tr '\n' '\t' >>"$statsfile"
}

### COMPARE ###

compare()
{
	dir="$1" # if arg is passed, we're processing only one dir
	ddir="."
	if test -n "$dir"; then
		ddir="./$dir"
		sql_dir="AND history.dirname LIKE './$dir/%'"
	fi

	# sed expression to convert `find` output into SQL query which imports
	# list of files into temporary DB table. Note that it fails if find
	# prints nothing, but that's unlikely to happen IRL
	sed="s/'/''/g        # duplicate single quotes
		1i BEGIN TRANSACTION;
		1i CREATE TEMPORARY TABLE fs (inode INTEGER, type TEXT, dirname TEXT, filename TEXT);
		s_^([0-9]*) (.) (.*/)([^/]*)/?_	\\
			INSERT INTO fs (inode, type, dirname, filename)	\\
			VALUES ('\\1', '\\2', '\\3', '\\4');_
		\$a END TRANSACTION;"

	# SQL expression to run after above import is complete
	# it compares "real" fs with what's in history:
	# * creates tables for new and old files,
	# updates database:
	# * first updates entries for old files,
	# * then adds new files.
	# Note: order is important, so we could use `WHERE freq=0`. Otherwise,
	# both "old" and "new" files would have freq=0 and we would have to
	# write more complex query.
	sql=".timeout 10000
		PRAGMA case_sensitive_like = ON;
		-- STEP 1: Create temporary tables
		-- Lines from current fs which don't have corresponding entry in
		-- 'history' table - in form ready to be inserted into 'history'
		-- table.  The 'history.freq = 0' part is here both for
		-- performance reasons and to ensure that long-deleted files do
		-- not affect the result in case of inode reuse
		CREATE TEMPORARY TABLE new_files AS
			SELECT fs.inode, fs.type, fs.dirname, fs.filename, '$BACKUP_TIME', '$BACKUP_TIME_NOW'
			FROM fs LEFT JOIN history INDEXED BY history_update
			ON  fs.inode = history.inode
			AND fs.type = history.type
			AND fs.dirname = history.dirname
			AND fs.filename = history.filename
			AND history.freq = 0 -- to make history INDEXED BY history_update
			WHERE history.inode IS NULL;
		-- Lines from history which don't have corresponding entry in
		-- 'fs' table. The 'history.freq = 0' part is there both for
		-- performance reasons and so we skip entries in 'history' table
		-- which correspond to files deleted long time ago.
		CREATE TEMPORARY TABLE old_files AS
			SELECT history.type, history.dirname, history.filename, history.created
			FROM history INDEXED BY history_update LEFT JOIN fs
			USING (inode, type, dirname, filename)
			WHERE fs.inode IS NULL
			   AND history.freq = 0 -- to make history INDEXED BY history_update
			   $sql_dir;
		-- STEP 2: Update 'history' table.
		-- First, update deleted entries - that will also update 'freq'
		UPDATE history SET deleted = '$BACKUP_TIME'
		WHERE
		(dirname, filename) IN (
			SELECT dirname, filename
			FROM old_files
			)
		  AND freq = 0;
		-- Now, add new entries
		INSERT INTO history (inode, type, dirname, filename, created, deleted) SELECT * FROM new_files;
		PRAGMA optimize;
		-- STEP 3: Print out lists of new and deleted files.
		SELECT 'first line';
		-- List of new files
		SELECT dirname || filename
		FROM new_files
		WHERE type != 'd';
		SELECT 'separator';
		-- List of old files
		-- Note that we print with partial filename in data dir
		SELECT dirname || filename || '/' || created
		FROM old_files
		WHERE type != 'd';
		"

	# List all files and build SQL query
	my_find "$BACKUP_CURRENT" "$ddir" $BACKUP_FIND_FILTER | ( sed -r "$sed"; echo "$sql" ) >"$BACKUP_TMP".sql

	# Exit if there's no DB
	check_db

	# run SQL query
	<"$BACKUP_TMP".sql $SQLITE >"$BACKUP_TMP".files

	# Operate on new files
	sed '1d;/^separator$/,$d' "$BACKUP_TMP".files | while IFS="$NL" read -r f; do
		mkdir -p "$BACKUP_MAIN/$f"
		ln "$BACKUP_CURRENT/$f" "$BACKUP_MAIN/$f/$BACKUP_TIME$BACKUP_TIME_SEP$BACKUP_TIME_NOW"
	done &

	# Operate on old files
	sed '1,/^separator$/d' "$BACKUP_TMP".files | while IFS="$NL" read -r f; do
		mv "$BACKUP_MAIN/$f$BACKUP_TIME_SEP$BACKUP_TIME_NOW" "$BACKUP_MAIN/$f$BACKUP_TIME_SEP$BACKUP_TIME"
	done &

	# wait for background jobs to finish
	wait

	# clean up
	rm "$BACKUP_TMP".sql "$BACKUP_TMP".files
}

### RUN ###

check_db

test "$BACKUP_CLEAN_ON" == 'pre' && . $BACKUP_BIN/clean.sh

if type run_this >/dev/null; then
	run_this
else
	compare
fi

test "$BACKUP_CLEAN_ON" == 'post' && . $BACKUP_BIN/clean.sh

. $BACKUP_BIN/hardlink.sh

# release the lock
rm "$BACKUP_FLOCK"
