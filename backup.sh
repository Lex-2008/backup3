#!/bin/busybox ash
#
# Main backup script.

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_FLOCK"   && BACKUP_FLOCK=$BACKUP_ROOT/lock
test -z "$BACKUP_FIFO"    && BACKUP_FIFO=$BACKUP_ROOT/fifo
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_RSYNC_LOGS" && BACKUP_RSYNC_LOGS=$BACKUP_ROOT/rsync.logs
test -z "$BACKUP_FIND_FILTER" # this is fine
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -n "$BACKUP_TIME"    && BACKUP_TIME="$(date -d "$BACKUP_TIME" +"%F %H:%M")"
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"%F %H:%M")"
test -z "$BACKUP_TIME_SEP" && BACKUP_TIME_SEP="~"
test -z "$BACKUP_TIME_NOW" && BACKUP_TIME_NOW=now # must be 'now' or valid date in future
test -z "$BACKUP_MAX_FREQ" && BACKUP_MAX_FREQ=8640

SQLITE="sqlite3 $BACKUP_DB"

NL='
'

# exit if there is another copy of this script running
exec 200>"$BACKUP_FLOCK"
flock -n 200 || exit 200

### RSYNC ###

# run rsync to backup from $1 to $2, with $3 extra arguments
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
	rsync -a --itemize-changes --human-readable --stats --fake-super --delete --one-file-system "$@" "$from" "$BACKUP_CURRENT/$to" >"$logfile"
}

# run
command -v run_this >/dev/null && run_this

### BACKUP ###

mkfifo "$BACKUP_FIFO.new"
mkfifo "$BACKUP_FIFO.new.sql"
mkfifo "$BACKUP_FIFO.new.files"
mkfifo "$BACKUP_FIFO.old"
mkfifo "$BACKUP_FIFO.old.sql"
mkfifo "$BACKUP_FIFO.old.files"

# listing all files together with their inodes currently in backup dir
# note that here we use "real" find, because the busybox one doesn't have "-printf"
# if changing, copypaste to rebuild.sh
/usr/bin/find "$BACKUP_CURRENT" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf '%i %P\0' | LC_ALL=POSIX sort -z >"$BACKUP_LIST".new

# Add empty file if it's missing so comm doesn't complain
touch "$BACKUP_LIST"

# comparing this list to its previous version
LC_ALL=POSIX comm -z -3 "$BACKUP_LIST" "$BACKUP_LIST".new | tee "$BACKUP_FIFO.new" >"$BACKUP_FIFO.old" &

# note that here we use "real" sed, because the busybox one doesn't have "-z"

### NEW FILES ###

/bin/sed -z '/^\t/!d;     # delete lines not starting with TAB
	/"/d;             # delete lines with double-quotes in filenames
	s/^\t[0-9]* //;   # delete tab and inode number
	' "$BACKUP_FIFO.new" | tee "$BACKUP_FIFO.new.sql" >"$BACKUP_FIFO.new.files" &

# SQL query for new files
cd "$BACKUP_CURRENT" # to pass relative pathnames to stat
xargs -r -0 stat -c "%s %n" <"$BACKUP_FIFO.new.sql" | sed '
	1i .timeout 10000
	1i BEGIN TRANSACTION;
	'"s/'/''/g"'      # duplicate single quotes
	/^[^/]*$/s_ _ /_; # ensure all lines have dir separator
	s_\([0-9]*\) \(.*\)/\(.*\)_	\
		INSERT INTO history (dirname, filename, created, deleted, freq, size)	\
		VALUES '"('\\2', '\\3', '$BACKUP_TIME', '$BACKUP_TIME_NOW', 0, '\\1')"';_
	$a END TRANSACTION;
	' | $SQLITE &
cd - >/dev/null

# operate on new files
cmd="cd \"$BACKUP_MAIN\"
mkdir -p \"\$@\"
while test \$# -ge 1; do
	ln -T \"$BACKUP_CURRENT/\$1\" \"$BACKUP_MAIN/\$1/$BACKUP_TIME$BACKUP_TIME_SEP$BACKUP_TIME_NOW\"
	shift
done" 
<"$BACKUP_FIFO.new.files" xargs -r -0 sh -c "$cmd" x &

### OLD FILES ###

/bin/sed -z '/^\t/d;      # delete lines starting with TAB
	/"/d;             # delete lines with double-quotes in filenames
	s/^[0-9]* //;     # delete inode number
	'"s/'/''/g"'      # duplicate single quotes
	/^[^/]*$/s_^_/_;  # ensure all lines have dir separator
	' "$BACKUP_FIFO.old" | tee "$BACKUP_FIFO.old.sql" >"$BACKUP_FIFO.old.files" &

# SQL query for old files
/bin/sed -z '1i .timeout 10000
	1i BEGIN TRANSACTION;
	s_\(.*\)/\(.*\)_'"	\\
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
		WHERE dirname = '\\1'		\\
		  AND filename = '\\2'		\\
		  AND created != '$BACKUP_TIME'	\\
		  AND freq = 0;_"'
	$a END TRANSACTION;
	' "$BACKUP_FIFO.old.sql" | tr '\0' '\n' | $SQLITE &

# operate on old files
cmd="cd \"$BACKUP_MAIN\"
while test \$# -ge 1; do
	mv \"\$1$BACKUP_TIME_SEP$BACKUP_TIME_NOW\" \"\$1$BACKUP_TIME_SEP$BACKUP_TIME\"
	shift
done" 
/bin/sed -z '1i .timeout 10000
	1i BEGIN TRANSACTION;
	s_\(.*\)/\(.*\)_'"			\\
		SELECT dirname || '/' || filename || '/' || created	\\
		FROM history			\\
		WHERE dirname = '\\1'		\\
		  AND filename = '\\2'		\\
		  AND created != '$BACKUP_TIME'	\\
		  AND (freq = 0			\\
		    OR deleted = '$BACKUP_TIME');_"'
	$a END TRANSACTION;
	' "$BACKUP_FIFO.old.files" | tr '\0' '\n' | $SQLITE | tr '\n' '\0' | xargs -r -0 sh -c "$cmd" x &

# wait for all background activity to finish
wait

# clean up
mv "$BACKUP_LIST".new "$BACKUP_LIST"
touch -d "$BACKUP_TIME" "$BACKUP_LIST"
rm "$BACKUP_FIFO"*

