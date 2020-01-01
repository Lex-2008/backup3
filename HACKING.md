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

	SELECT parent || dirname || filename || '/' || created || '$BACKUP_TIME_SEP' || deleted
	FROM history;

To parse filenames in `$BACKUP_CURRENT`:

	/usr/bin/find "$BACKUP_CURRENT" $BACKUP_FIND_FILTER \( -type f -o -type l \) -printf "%i ./%P\\n" | sed -r "
		s_^([0-9]*) (.*/)?([^/]*/)([^/]*)_	\
			inode=\\1	\
			parent dir=\\2	\
			dirname=\\3	\
			filename=\\4	\
		_"

To parse filenames in `$BACKUP_MAIN`:

	/usr/bin/find "$BACKUP_MAIN" $BACKUP_FIND_FILTER \( -type f -o -type l \) -name "*$BACKUP_TIME_SEP*" -printf '%i ./%P\n' | sed -r "
		s_^([0-9]*) (.*/)?([^/]*/)([^/]*)/([^/$BACKUP_TIME_SEP]*)$BACKUP_TIME_SEP([^/$BACKUP_TIME_SEP]*)_	\
			inode=\\1	\
			parent dir=\\2	\
			dirname=\\3	\
			filename=\\4	\
			created=\\5	\
			deleted=\\6	\
		_"

Note that `sed` output will be on one line, unless you include `\n`.

Note that both `parent dir` and `dirname` must end with a slash. Also, `parent dir` might be empty, but `dirname` will never be empty.
For files at the root of `$BACKUP_CURRENT`: `parent dir='', dirname='./'`
