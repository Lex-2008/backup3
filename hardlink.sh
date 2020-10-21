#!/bin/false
# It is expected that this file is sourced by backup.sh
#
# Script to create hardlinks for human-accessible backups

# note: $f is used later in $sql, too
for f in 1 30 720; do
    case $f in
        # note1: now_fmt MUST have different lengths or separators
        # note2: they must match oldest_dir_to_keep (generated from HARDLINK_EXPR)
        ( 1 )    dir_fmt="%Y-%m"; strict_fmt="%d %H:%M"; strict_match="01 00:00"; date_fmt="%Y-%m-01" ;; # monthly
        ( 30 )   dir_fmt="%Y-%m-%d"; strict_fmt="%H:%M"; strict_match="00:00"; date_fmt="%Y-%m-%d" ;;    # daily
        ( 720 )  dir_fmt="%Y-%m-%d %H"; strict_fmt="%M"; strict_match="00"; date_fmt="%Y-%m-%d %H:00" ;; # hourly
    esac
    dir="$(date -d "$BACKUP_TIME" +"$dir_fmt")"
    if ! test -d "$HARDLINK_DIR/$dir"; then
        mkdir -p "$HARDLINK_DIR"
        # first, delete obsolete dirs
        dir_re="$(echo "$dir" | sed 's/[0-9]/./g')"
        sql="SELECT CASE $f $HARDLINK_EXPR ELSE 'now' END;"
        oldest_dir_to_keep="$(echo "$sql" | $SQLITE)"
        (cd "$HARDLINK_DIR"; ls | grep -x "$dir_re") | while IFS="$NL" read -r dir; do
                if expr "$dir" '<' "$oldest_dir_to_keep" >/dev/null; then
                    rm -rf "$HARDLINK_DIR/$dir"
                fi
            done
        # now, create new dir
        if [ "$(date -d "$BACKUP_TIME" +"$strict_fmt")" = "$strict_match" ]; then
            cp -al "$BACKUP_CURRENT" "$HARDLINK_DIR/$dir"
        elif [ "$HARDLINK" = "loose" ]; then
            parsable_date="$(date -d "$BACKUP_TIME" +"$date_fmt")"
            "$BACKUP_BIN/show.sh" "$parsable_date" . "$HARDLINK_DIR/$dir"
            touch "$HARDLINK_DIR/$dir-loose"
        fi
    fi
done
