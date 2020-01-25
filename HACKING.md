Style
-----

Use pipes, like this:

	cmd="	while test \$# -ge 1; do
			# operate on \$1
			shift
		done"

	echo "$sql" | $SQLITE | tr '\n' '\0' | xargs -0 sh -c "$cmd" x | $SQLITE

Note that sqlite doesn't support null-separated lines, so we have to use `tr`.

Note the busybox `sh` syntax: `-c 'SCRIPT' [ARG0 [ARGS]` hence "x" as ARG0

Note that some implementations of $SQLITE don't support receiving sql expression
as an argument (most notably, "remote SQLite"), hence please avoid using it.

To select filenames:

	SELECT dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted
	FROM history;

To parse filenames in `$BACKUP_CURRENT`:

	my_find "$BACKUP_CURRENT" . $BACKUP_FIND_FILTER | sed -r "
		s_^([0-9]*) (.) (.*/)([^/]*)$_	\\
			inode=\\1	\\
			type=\\2	\\
			dirname=\\2	\\
			filename=\\4	\\
		_"

Note: `my_find` is a wrapper around busybox find or GNU find to produce similar
output.

To parse filenames in `$BACKUP_MAIN`:

	my_find "$BACKUP_MAIN" . $BACKUP_FIND_FILTER -not -type d | sed -r "
		s_^([0-9]*) (.) (.*/)([^/]*)/(.*)$BACKUP_TIME_SEP(.*)$_	\\
			inode=\\1	\\
			type=\\2	\\
			dirname=\\2	\\
			filename=\\4	\\
			created=\\5	\\
			deleted=\\6	\\
		_"

Note that `sed` output will be on one line, unless you include `\n`.

Note that `dirname` must end with a slash and will never be empty - for files at the root of `$BACKUP_CURRENT`, it's './'
