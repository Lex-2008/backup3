#!/bin/bash
#
# Main backup script.
#
# Note: this is *bash* script due to 2x speed improvements that variable
# replacement like this: "${varname//a/n}" gives us over calling external
# tool like this: "$(echo "$varname" | sed 's/a/b/g')"

test -z "$BACKUP_ROOT"    && exit 2

test -z "$BACKUP_CURRENT" && BACKUP_CURRENT=$BACKUP_ROOT/current
test -z "$BACKUP_LIST"    && BACKUP_LIST=$BACKUP_ROOT/files.txt
test -z "$BACKUP_MAIN"    && BACKUP_MAIN=$BACKUP_ROOT/data
test -z "$BACKUP_DB"      && BACKUP_DB=$BACKUP_ROOT/backup.db
test -z "$BACKUP_TIME"    && BACKUP_TIME="$(date +"%F %T")"

SQLITE="sqlite3 $BACKUP_DB"

### DIFF ###

# listing all files together with their inodes currently in backup dir
(find "$BACKUP_CURRENT" \( -type f -o -type l \) -printf '%i %P\n' ) | sort --key 2 >"$BACKUP_LIST".new

# comparing this list to its previous version
diff --new-file "$BACKUP_LIST" "$BACKUP_LIST".new | sed '/^[<>]/!d;s/^\(.\) [0-9]*/\1/;s/^>/N/;s/^</D/' | sort --key=2,1 >"$BACKUP_LIST".diff

mv "$BACKUP_LIST".new "$BACKUP_LIST"

### BACKUP ###

first_day_of_month="$(date -d "$(date -d "$BACKUP_TIME" "+%Y-%m-01")" +"%F %T")"
last_sunday="$(date -d "$(date -d "-$(date -d "$BACKUP_TIME" +%w) days" +"%Y-%m-%d")" +"%F %T")"
last_midnight="$(date -d "$(date -d "$BACKUP_TIME" "+%F")" +"%F %T")"
first_minute_of_hour="$(date -d "$(date -d "$BACKUP_TIME" "+%F %H:00")" +"%F %T")"

cat "$BACKUP_LIST".diff | (
	echo "BEGIN TRANSACTION;"
	while read change fullname; do
		# escape vars for DB
		clean_fullname="${fullname//\'/\'\'}"
		# clean_fullname="$(echo "$fullname" | sed "s/'/''/g")"
		clean_dirname="${clean_fullname%/*}"
		test "$clean_dirname" = "$clean_fullname" && dirname=""
		clean_filename="${clean_fullname##*/}"
		case "$change" in
			( N ) # New file
				echo "INSERT INTO history (dirname, filename, created, deleted, freq) VALUES ('$clean_dirname', '$clean_filename', '$BACKUP_TIME', NULL, 0);"
				dirname="${fullname%/*}"
				test "$dirname" = "$fullname" && dirname=""
				newname="$fullname#$BACKUP_TIME"
				mkdir -p "$BACKUP_MAIN"/"$dirname"
				ln "$BACKUP_CURRENT"/"$fullname" "$BACKUP_MAIN"/"$newname"
				;;
			( D ) # Deleted
				echo "UPDATE history
					SET
						deleted = '$BACKUP_TIME',
						freq = CASE
							WHEN created < '$first_day_of_month' THEN 1
							WHEN created < '$last_sunday' THEN 5
							WHEN created < '$last_midnight' THEN 30
							WHEN created < '$first_minute_of_hour' THEN 720
							ELSE 8640
						END
					WHERE dirname = '$clean_dirname'
					AND filename = '$clean_filename'
					AND freq = 0;"
				;;
		esac
	done
	echo "END TRANSACTION;"
) | $SQLITE

