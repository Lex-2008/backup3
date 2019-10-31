#!/bin/busybox ash
#
# Main backup script.

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_FIFO"    && BACKUP_FIFO=$BACKUP_ROOT/fifo
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_RSYNC_LOGS" && BACKUP_RSYNC_LOGS=$BACKUP_ROOT/rsync.logs
test -z "$BACKUP_FIND_FILTER" # this is fine
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME_FORMAT" && BACKUP_TIME_FORMAT="%F %H:%M"
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"$BACKUP_TIME_FORMAT")"
test -z "$BACKUP_TIMEOUT" && BACKUP_TIMEOUT="3600" # 1h
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~" # must be regexp-safe
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now # must be 'now' or valid date in future
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640

SQLITE="sqlite3 $BACKUP_DB"

# exit if there is another copy of this script running
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

### RSYNC ###

# run rsync to backup every $1 from $2 to $3, with $3 extra arguments
run_rsync()
{
	when="$1"
	to="$2"
	from="$3"
	shift 3
	logfile="$BACKUP_RSYNC_LOGS/$to"
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
	timeout rsync "$@" "$from" >/dev/null 2>&1 || return 0
	# sync files
	timeout -t "$BACKUP_TIMEOUT" rsync -a --itemize-changes --human-readable --stats --fake-super --delete --one-file-system "$@" "$from" "$BACKUP_CURRENT/$to" >"$logfile"
	# add them to DB
	compare "$to"
}

### COMPARE ###

compare()
{
	dir="$1" # if arg is passed, we're processing only one dir
	if test -n "$dir"; then
		ddir="$dir/"
		sql_dir="AND ( history.dirname = '$dir' OR history.dirname LIKE '$dir/%' )"
	fi

	# sed expression to convert `find` output into SQL query which imports
	# list of files into temporary DB table. Note that it fails if find
	# prints nothing, but that's unlikely to happen IRL
	sed="s/'/''/g        # duplicate single quotes
		1i BEGIN TRANSACTION;
		1i CREATE TEMPORARY TABLE fs (inode INTEGER, dirname TEXT, filename TEXT, freq INTEGER);
		s_^([0-9]*) ((.*)/)?(.*)_	\\
			INSERT INTO fs (inode, dirname, filename, freq)	\\
			VALUES ('\\1', '\\3', '\\4', 0);_
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
	# Actually, we don't use it, but thanks to UNIQUE INDEX WHERE freq=0, we
	# can just use `INSERT OR REPLACE` statement, which will replace
	# matching rows with new ones updated data. Note that can't use this
	# trick to update freq column itself - so we'll do it in a separate step
	sql=".timeout 10000
		PRAGMA case_sensitive_like = ON;
		-- STEP 1: Create temporary tables
		-- Lines from current fs which don't have corresponding entry in
		-- 'history' table - in form ready to be inserted into 'history'
		-- table.  The 'history.freq = 0' part is here both for
		-- performance reasons and to ensure that long-deleted files do
		-- not affect the result in case of inode reuse
		CREATE TEMPORARY TABLE new_files AS
			SELECT fs.inode, fs.dirname, fs.filename, '$BACKUP_TIME', '$BACKUP_TIME_NOW', 0
			FROM fs LEFT JOIN history INDEXED BY history_update
			ON  fs.inode = history.inode
			AND fs.dirname = history.dirname
			AND fs.filename = history.filename
			AND history.freq = 0 -- to make history INDEXED BY history_update
			WHERE history.inode IS NULL;
		-- Lines from history which don't have corresponding entry in
		-- 'fs' table with all values unchanged except deleted date.
		-- 'freq' is currently 0, will be updated later - this is done
		-- to use 'UNIQUE INDEX WHERE freq=0' when using 'INSERT OR
		-- REPLACE' statement to bulk update 'history' table. The
		-- 'history.freq = 0' part is there both for performance reasons
		-- and so we skip entries in 'history' table which correspond to
		-- files deleted long time ago.
		CREATE TEMPORARY TABLE old_files AS
			SELECT history.inode, history.dirname, history.filename, history.created, '$BACKUP_TIME', 0
			FROM history INDEXED BY history_update LEFT JOIN fs
			USING (inode, dirname, filename)
			WHERE fs.inode IS NULL
			   AND history.freq = 0 -- to make history INDEXED BY history_update
			   $sql_dir;

		-- STEP 2: Update 'history' table.
		-- Note that all rows in 'old_files' tables have corresponding
		-- lines in 'history' table, so 'UNIQUE INDEX WHERE freq=0'
		-- prevents them to be inserted, so existing lines in 'history'
		-- are deleted. Effectively, the following statement only
		-- changes 'deleted' date - sets it to current. 'freq' is
		-- updated on next step - so we could use 'UNIQUE INDEX WHERE
		-- freq=0' now.
		INSERT OR REPLACE INTO history (inode, dirname, filename, created, deleted, freq) SELECT * FROM old_files;
		-- And now we update 'freq'.
		UPDATE history SET freq = CASE
				WHEN strftime('%Y-%m', created,        '-1 second') !=
				     strftime('%Y-%m', '$BACKUP_TIME', '-1 second')
				     THEN 1 -- different month
				WHEN strftime('%Y %W', created,        '-1 second') !=
				     strftime('%Y %W', '$BACKUP_TIME', '-1 second')
				     THEN 5 -- different week
				WHEN strftime('%Y-%m-%d', created,        '-1 second') !=
				     strftime('%Y-%m-%d', '$BACKUP_TIME', '-1 second')
				     THEN 30 -- different day
				WHEN strftime('%Y-%m-%d %H', created,        '-1 second') !=
				     strftime('%Y-%m-%d %H', '$BACKUP_TIME', '-1 second')
				     THEN 720 -- different hour
				ELSE $BACKUP_MAX_FREQ
			END
		WHERE freq = 0
		  AND deleted = '$BACKUP_TIME';
		-- Now when 'freq' is changed, we can add entries abot new files
		INSERT OR REPLACE INTO history (inode, dirname, filename, created, deleted, freq) SELECT * FROM new_files;
		PRAGMA optimize;
		-- STEP 3: Print out lists of new and deleted files.
		-- List of new files
		select './' || dirname || '/' || filename from new_files;
		select 'separator';
		-- List of old files
		-- Note that we print with partial filename in data dir
		SELECT './' || dirname || '/' || filename || '/' || created FROM old_files;
		"

	# Shell command to operate on new files:
	# * link them from 'current' to 'data' dir
	cmd_new="cd \"$BACKUP_MAIN\"
	mkdir -p \"\$@\"
	while test \$# -ge 1; do
		ln \"$BACKUP_CURRENT/\$1\" \"\$1/$BACKUP_TIME$BACKUP_TIME_SEP$BACKUP_TIME_NOW\"
		shift
	done"

	# Shell command to operate on old files:
	# * change deleted date in filename from '~now' to '~$BACKUP_TIME'
	cmd_old="cd \"$BACKUP_MAIN\"
	while test \$# -ge 1; do
		mv \"\$1$BACKUP_TIME_SEP$BACKUP_TIME_NOW\" \"\$1$BACKUP_TIME_SEP$BACKUP_TIME\"
		shift
	done"

	# Pipes for new and old file pipelines
	mkfifo "$BACKUP_FIFO.new"
	mkfifo "$BACKUP_FIFO.old"

	# Pipelines for new and old files
	sed '/^separator$/,$d' "$BACKUP_FIFO.new" | tr '\n' '\0' | xargs -r -0 sh -c "$cmd_new" x &
	sed '1,/^separator$/d' "$BACKUP_FIFO.old" | tr '\n' '\0' | xargs -r -0 sh -c "$cmd_old" x &

	# Common pipeline
	/usr/bin/find "$BACKUP_CURRENT/$dir" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf "%i $ddir%P\\n" | ( sed -r "$sed"; echo "$sql" ) | $SQLITE | tee "$BACKUP_FIFO.new" >"$BACKUP_FIFO.old"

	rm "$BACKUP_FIFO"*
}

### RUN ###

if command -v run_this >/dev/null; then
	run_this
else
	compare
fi
