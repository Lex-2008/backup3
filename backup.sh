#!/bin/busybox ash
#
# Main backup script.

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_FIFO"    && BACKUP_FIFO=$BACKUP_ROOT/fifo
test -z "$BACKUP_LOG"     && BACKUP_LOG=$BACKUP_ROOT/log
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_RSYNC_LOGS" && BACKUP_RSYNC_LOGS=$BACKUP_ROOT/rsync.logs
test -z "$BACKUP_FIND_FILTER" # this is fine
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -n "$BACKUP_TIME"    && BACKUP_TIME="$(date -d "$BACKUP_TIME" +"%F %H:%M")"
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"%F %H:%M")"
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
	timeout -t "$BACKUP_TIMEOUT" rsync -a --itemize-changes --human-readable --stats --fake-super --delete --one-file-system "$@" "$from" "$BACKUP_CURRENT/$to" >"$logfile"
}

# run
command -v run_this >/dev/null && run_this

### COMPARE ###

# listing all files together with their inodes currently in backup dir
# note that here we use "real" find, because the busybox one doesn't have "-printf"
# Note: if changing, copypaste to rebuild.sh and README.md (in rdfind section)
/usr/bin/find "$BACKUP_CURRENT" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf '%i %P\0' | LC_ALL=POSIX sort -z >"$BACKUP_LIST".new

# Add empty file if it's missing so comm doesn't complain
touch "$BACKUP_LIST"

mkfifo "$BACKUP_FIFO.sql"
mkfifo "$BACKUP_FIFO.files.new"
mkfifo "$BACKUP_FIFO.files.old"

# comparing this list to its previous version
LC_ALL=POSIX comm -z -3 "$BACKUP_LIST" "$BACKUP_LIST".new | tee "$BACKUP_FIFO.sql" "$BACKUP_FIFO.files.new" >"$BACKUP_FIFO.files.old" &

# Note that here we use "real" sed, because the busybox one doesn't have "-z"

### SQL ###
# * new files: add to db
# * old files: set deleted time and freq

/bin/sed -r -z "
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	\$a END TRANSACTION;
	\$a PRAGMA optimize;
	# /\"/d;     # delete lines with double-quotes in filenames
	s/'/''/g   # duplicate single quotes
	/^\\t/{    # lines starting with TAB means new file
		s_^\\t[0-9]* ((.*)/)?(.*)_	\\
			INSERT INTO history (dirname, filename, created, deleted, freq)	\\
			VALUES ('\\2', '\\3', '$BACKUP_TIME', '$BACKUP_TIME_NOW', 0);	\\
		_;p;d}
	s_^[0-9]* ((.*)/)?(.*)_	\\
		UPDATE history	\\
		SET 	deleted = '$BACKUP_TIME',	\\
			freq = CASE	\\
				WHEN strftime('%Y-%m', created,        '-1 minute') !=	\\
				     strftime('%Y-%m', '$BACKUP_TIME', '-1 minute')	\\
				     THEN 1 -- different month	\\
				WHEN strftime('%Y %W', created,        '-1 minute') !=	\\
				     strftime('%Y %W', '$BACKUP_TIME', '-1 minute')	\\
				     THEN 5 -- different week	\\
				WHEN strftime('%Y-%m-%d', created,        '-1 minute') !=	\\
				     strftime('%Y-%m-%d', '$BACKUP_TIME', '-1 minute')		\\
				     THEN 30 -- different day	\\
				WHEN strftime('%Y-%m-%d %H', created,        '-1 minute') !=	\\
				     strftime('%Y-%m-%d %H', '$BACKUP_TIME', '-1 minute')	\\
				     THEN 720 -- different hour	\\
				ELSE $BACKUP_MAX_FREQ		\\
			END			\\
		WHERE dirname = '\\2'		\\
		  AND filename = '\\3'		\\
		  AND created != '$BACKUP_TIME'	\\
		  AND freq = 0;_
	" "$BACKUP_FIFO.sql" | tr '\0' '\n' | tee "$BACKUP_LOG".sql | $SQLITE &

### NEW FILES ###
# hardlink from BACKUP_CURRENT to BACKUP_MAIN

cmd="cd \"$BACKUP_MAIN\"
mkdir -p \"\$@\"
while test \$# -ge 1; do
	echo \"\$1\" >>\"$BACKUP_LOG\".new
	ln \"$BACKUP_CURRENT/\$1\" \"$BACKUP_MAIN/\$1/$BACKUP_TIME$BACKUP_TIME_SEP$BACKUP_TIME_NOW\"
	shift
done"
rm "$BACKUP_LOG".new

/bin/sed -z '/^\t/!d;     # delete lines NOT starting with TAB
	# /"/d;             # delete lines with double-quotes in filenames
	s_^\t[0-9]* __   # delete inode number
	' "$BACKUP_FIFO.files.new" | xargs -r -0 sh -c "$cmd" x &

### OLD FILES ###
# * ask database for created date
# * add current date to filename

cmd="cd \"$BACKUP_MAIN\"
while test \$# -ge 1; do
	echo \"\$1\" >>\"$BACKUP_LOG\".old
	mv \"./\$1$BACKUP_TIME_SEP$BACKUP_TIME_NOW\" \"./\$1$BACKUP_TIME_SEP$BACKUP_TIME\"
	shift
done" 
rm "$BACKUP_LOG".old

/bin/sed -r -z "
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	\$a END TRANSACTION;
	/^\\t/d;    # delete lines starting with TAB
	# /\"/d;      # delete lines with double-quotes in filenames
	s/'/''/g;   # duplicate single quotes
	s_^[0-9]* ((.*)/)?(.*)_	\\
		SELECT dirname || '/' || filename || '/' || created	\\
		FROM history			\\
		WHERE dirname = '\\2'		\\
		  AND filename = '\\3'		\\
		  AND created != '$BACKUP_TIME'	\\
		  AND (freq = 0			\\
		    OR deleted = '$BACKUP_TIME');_
	" "$BACKUP_FIFO.files.old" | tr '\0' '\n' | tee "$BACKUP_LOG".old.sql | $SQLITE | tr '\n' '\0' | xargs -r -0 sh -c "$cmd" x &

# wait for all background activity to finish
wait

# clean up
mv "$BACKUP_LIST".new "$BACKUP_LIST"
touch -d "$BACKUP_TIME" "$BACKUP_LIST"
rm "$BACKUP_FIFO"*

