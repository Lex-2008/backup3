Style
-----

Use pipes, like this:

	cmd="	while test \$# -ge 1; do
			# operate on \$1
			shift
		done"

	$SQLITE "$sql" | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE

Note that sqlite doesn't support null-separated lines, so we have to use `tr`.

Note the busybox `sh` syntax: `-c 'SCRIPT' [ARG0 [ARGS]` hence "x" as ARG0


To select filenames:

	SELECT dirname || '/' || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted
	FROM history;

To parse filenames in `$BACKUP_MAIN`:

	/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf '%P\0' | /bin/sed -z -r "
		s_((.*)/)?(.*)/(.*)$BACKUP_TIME_SEP(.*)_	\
			dirname with trailing slash=\\1		\
			dirname without trailing slash=\\2	\
			filename=\\3	\
			created=\\4	\
			deleted=\\5	\
		_"

Note that `sed` output will be on one line, unless you include `\n`.

Note that both `dirname_with_trailing_slash` and `dirname_without_trailing_slash` might be empty.
