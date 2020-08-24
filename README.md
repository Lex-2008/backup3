backup3
=======

My third _and a half_ attempt at making backups - using ~bash~ _busybox_, ~find~, ~diff~ ~comm -3~, and SQLite.

Background
----------

### History

My [previous backup system][1] was based on hardlinks - as often as every 5 minutes most of backup tree was `cp -al`'ed from _previous_ to newly-created _current_ dir, and then `rsync` was running to apply any changes.
As a result - I had snapshots as frequent as every 5 minutes, each of them contained only changes since last rsync run (few megabytes).
Advanced heuristic was running to delete old snapshots while keeping some of them (hourly, daily, monthly) longer.
Sounds good, right?

[1]: http://alexey.shpakovsky.ru/en/rsync-backups.html

And it was good indeed, while I assumed that directories are created and deleted instantly.
But after a while I noticed that cleaning up disk space takes awfully long time: deleting each snapshot took 10~15 minutes, and freed only a few megabytes.
How long should it be running to clean 10 Gb?

### Idea

So the idea is to keep only _one_ copy of each unique file, plus keep _somewhere_ a time range when it existed, and use a script to reconstruct file tree for a given time using this data. Sounds like a good task for a database?

So it work like this:

* First, rsync updates all files in a "current backup" directory.
  By default it doesn't do it "in place" - instead, it first creates new version and then replaces old one with it, so _its inode number changes_.
  Note this! We will use it later.

* Then, we compare current state of "current backup" dir with what was there previously:

  * New files we hardlink to "storage" directory (so they didn't get lost when deleted from "current backup" some day later),
    and record them into database, together with "creation" date.

  * For deleted files we just note their "deletion" date in the database.

  * Changed files we treat as "old version deleted, new version created".

#### How do we compare?

To notice changes in new and deleted files, we can just save list of all files, like this: `find -type f >files.list.new` ~and run `diff` to compare it to previous version~.
~Then new files will appear in diff marked with `>` symbol, and deleted - with `<`.~

Update: `diff` sometimes gets confused when many lines get changed, and reports not-changed files as both created and deleted.
~I've moved to `comm -3` utility since then - when comparing two files, it prefixes lines unique to second file with tab character, and (due to `-3` argument) skips lines which present in both files.~
~Lines unique to first file are printed not-tab-indented.~

Update 2: To make it possible to work with individual dirs of files in 'current' directory, I've moved to using SQLite for comparing "real" and "stored" filesystem state: output of `find` command is converted by sed to SQL statements to populate new table, which gets `LEFT JOIN`ed with table from previous run, and if we select rows containing `NULL` values in _right_ table - then we get rows which exist _only_ in _left_ table - these are _new_ or _old_ files depending on odred in which we join tables.

To track also changed files, we actually need to record inode number together with filename - in case it's modified by rsync (remember that rsync changes inode number when modifying files), line if `find` output will change, and ~`diff`~ ~`comm -3` output will have two lines - one for "deletion" of old line, and one for "addition" of new one~ SQLite will see these lines as different and show one of them in list of new files, and another one - in list of deleted files - exactly what we want!

Setup
-----

Find a writeable dir to keep your backups in (say, `/var/backups`) and run:

	BACKUP_ROOT=/var/backups init.sh

It will create necessary dirs and sqlite database to hold information.

### Requirements

* sqlite3 (can be accessed remotely via network)
* busybox (ash, du, df, stat, also httpd for [WebUI](#webui))
* find (optionally - better for performance)
* smbclient (optionally - only if using password-protected dirs in WebUI)
* par2create (optionally - only if creating par2 files)
* cpulimit (optionally - only if limiting cpu usage by par2 process)


Simple usage
------------

To backup your `/home` directory every now and then, add this file into your
crontab:

	# Required config
	export BACKUP_ROOT=/var/backups # dir to hold all backups-related data

	# rsync operations, maybe several
	rsync -a --delete /home "$BACKUP_ROOT/current"

	# Run main backup operation
	backup.sh

Advanced usage
--------------

But what if you want to backup, say, your browser data every 5 minutes, and rest
of your `$HOME` directory - only once an hour? Then create a file called
`local.sh` next to the `backup.sh`, with a contents like this:

	BACKUP_ROOT=/var/backups

	run_this()
	{
		# Backup Chrome profile to "browser" subdir on *every* backup
		run_rsync always browser /home/lex/.config/google-chrome/Default/

		# Backup whole home directory once every hour
		run_rsync hourly home /home/lex
	}

And add just `backup.sh` to your crontab. It will _source_ the `local.sh` file,
and execute the `run_this` function.

### Clean-up

Before running above function, `backup.sh` will ensure that there is at least
10% of free disk space by deleting old files. You can configure this by setting
`BACKUP_CLEAN_VAL` and `BACKUP_CLEAN_ON` variables in `local.sh` (see their
values in `config.sh`).

### Protecting against bit rot

To protect against [bit rot][], run this command every month after the monthly
backup:

	par2create.sh 1

It will walk through all files in the last monthly backup and create `*.par2`
archives for files over 300kb. This feature requires [par2cmdline][] installed
(usually available in your distro repos).
Files smaller than 300kb will be just copied to `*.bak` files, because `*.par2`
files will be bigger than files they are protecting.
Running `par2create.sh` without arguments will ensure that `*.par2` or `*.bak`
files exist for all monthly backups, not only for the last one.
To check if par2 archives are valid and no bit rot happened, run this command:

	par2verify.sh

It has same arguments as `par2create.sh`. To check previous month's `*.par2`
files, use these arguments:

	par2verify.sh 2 1

If run in September, this command will check `*.par2` files created by
`par2create.sh 1` command ran in August.

If you have [cpulimit][] installed (usually available in your distro repos),
you can limit the CPU usage by `par2` process. For example, to make it use
about 10% of CPU, export this variable before running the
`par2create.sh`/`par2verify.sh` command:

	export BACKUP_PAR2_CPULIMIT=10

It is especially useful if you use some [fanless][] computer and don't want it
to overheat under the task.

[bit rot]: https://en.wikipedia.org/wiki/Data_degradation
[par2cmdline]: https://github.com/parchive/par2cmdline
[cpulimit]: https://github.com/opsengine/cpulimit
[fanless]: http://alexey.shpakovsky.ru/en/fanlesstech.html

### Restore from backup

You can either dig manually in data dir, or use `show.sh` to show contents of
archive for a given date, or read next big chapter:

Web UI
------

Go to the `web` dir of this repo and run the following command:

	busybox httpd -p 8800

Then navigate to <http://localhost:8800/> in your browser and you can browse
through contents of your backups:

![Main screen](Screenshot_2019-02-03-main.png)

First, select "root" backup dir in top-left corner, then navigate through
directories to the place of interest, use time slider in top-right corner
to select desired time of backup, and after that you have three options:

* Either click one of files to download its version for a given time

* Or click button in top row to download whole directory

* Or change value of switch in top row to show all versions of file instead of
downloading it and click any of file names - you will see a screen where you
can choose which version of the file you want to restore:

![File info dialog](Screenshot_2019-02-03-fileinfo.png)

### Password protection

Password protection currently implemented via attempt to connect to samba share.
To protect, for example, "root" directory called "private", create text file
`private.pw` next to it with name of user and share, like this:

	lex|\\localhost\private\

This way, when accessing anything in "private" dir, we will try to access
`\\localhost\private\` share using `lex` username and user-provided password.
Note that you need to have `smbclient` installed for this to work.
To override default username, user can provide username in password field,
space-separated before password, like this: `username password`.

### API index

Every time you open WebUI, it creates an 'api' index to speed up further
requests. It's not needed for anything else, so if you don't use WebUI very
often, I recommend adding the following command to crontab to run every night:

	$SQLITE "DROP INDEX IF EXISTS api;"

### Remote trigger

Instead of running by cron, it is also possible to trigger backup.sh run from a
remote machine by sending HTTP request to `http://<webui>/cgi-bin/api.sh?sync`,
where `http://<webui>/` is your WebUI endpoint. It can be useful, for example,
when chaining different backup utilities to run one after another, or when a
remote machine detects a change in a rarely-updated directory.

If you want different things to happen when you run backup.sh by cron and by API
trigger, you can check for `$GATEWAY_INTERFACE` environment variable in
`local.sh`, like this:

	# Common setup
	BACKUP_ROOT=/var/backups

	# things to sync by cron
	cron_job()
	{
		run_rsync hourly homes /home
		run_rsync always browser /home/lex/.config/google-chrome/Default/
	}

	# things to sync when triggered remotely
	web_job()
	{
		run_rsync always remote "user@host::share"
	}

	# choose which of the above to run
	if test -z "$GATEWAY_INTERFACE"; then
		alias run_this=cron_job
	else
		BACKUP_WAIT_FLOCK=1
		alias run_this=web_job
	fi

Also note `BACKUP_WAIT_FLOCK=1` statement above - it will ensure that if API
gets triggered when a backup job is in progress - the script will wait for a
blocking job to finish before issuing an api-initiated backup - and it will not
be lost.

If you want to define several remote triggers, you can add anything after `sync`
word in the URL, like this: `http://<webui>/cgi-bin/api.sh?sync-this`,
`http://<webui>/cgi-bin/api.sh?sync-that`, and check `$QUERY_STRING` variable,
like this:

	if test "$QUERY_STRING" = "sync-this"; then
		alias run_this=this_job
	elif test "$QUERY_STRING" = "sync-that"; then
		alias run_this=that_job
	else
		alias run_this=cron_job
	fi

Remote database
---------------

If you're running this script on the machine which doesn't have sqlite3, but
which has (network) access to the machine which does have both sqlite3 and
busybox - you can access the database via network. For this, just run sqlite3 as
a server, like this:

	busybox nc -lk -p 24692 -e sqlite3 backup.db

Where 24692 is your favorite port number, and backup.db is the file to be used.
Check `busybox nc --help` for proper usage, it might be `-ll` or `-lk` in
different versions.

And set SQLITE variable to access it remotely like this:

	export SQLITE="busybox nc 192.168.100.145 24692"

Where 24692 is the same port number, and 192.168.100.145 is address of the
machine with SQLite "server".

Fun stuff
---------

### Getting total number of rows in database

	$SQLITE 'SELECT count(*) FROM history;'

### Checking disk space used by each dir

	cd $BACKUP_ROOT
	echo "Disk usage of each dir:"
	(
		echo 'name current data'
		(
			(
				echo .
				ls data
			) | xargs -I% echo 'echo "% $(test -e current/% && du -BG -d0 current/% | cut -f1) $(du -BG -d0 data/% | cut -f1)"' | sh
		)
	) | column -t

### Getting number of files in each directory

	$SQLITE "SELECT substr(dirname,3,instr(substr(dirname,3),'/')-1) AS root, count(*) FROM history WHERE dirname != './' GROUP BY root; | column -tns'|'

Note that `-n` argument for `column` command is a non-standard Debian extension

### Checking how much space `*.par2` files are occupying

If you're wondering how much does the protection against bit rot costs you in
sense of gigabytes, just run this command: (taken from [this][a322828]
stackexchange answer):

	find "$BACKUP_ROOT" -type f \( -name '*.bak' -o -name '*.par2' -o -name '*.vol*' \) -printf '%s\n' | gawk -M '{sum+=$1} END {print sum}' | numfmt --to=si

[a322828]: https://unix.stackexchange.com/questions/41550/find-the-total-size-of-certain-files-within-a-directory-branch/322828#322828

### Getting most frequently changed files

	$SQLITE "SELECT dirname, filename, count(*) AS num FROM history GROUP BY dirname, filename ORDER BY num DESC LIMIT 10;"

### Getting latest file in each of "freq" group

	$SQLITE "SELECT freq, MIN(deleted) FROM history WHERE freq != 0 GROUP BY freq;"

Messing with db
---------------

### Check that database is correct

It may happen that data in database is out of sync with actual files. To check
for that, run `check.sh`. To fix it, run `check.sh --fix`. It will correct
information in the database.

### Rebuild database from files

All information in the database is also stored in filenames in backup. To
rebuild database from files, simply run `rebuild.sh`.

### Delete files from backup

If you realised that you've backed up some files that you didn't actually want
to backup (like caches), you can delete them - both from filesystem, like this:

	rm -rf $BACKUP_ROOT/{current,data}/home/.cache

and from database, like this:

	$SQLITE "DELETE FROM history WHERE dirname LIKE 'home/.cache%'"

Or run only the first command, followed by `check.sh --fix`. Remember to exclude
them from the rsync operation - otherwise they will appear in backup again!

### Clean empty dirs

Especially after above command, you're left with a tree of empty directories in
`$BACKUP_DATA`. To get rid of them, run this command (taken from [this][a107556]
stackexchange answer):

	find $BACKUP_MAIN -type d -empty -delete

[a107556]: https://unix.stackexchange.com/questions/8430/how-to-remove-all-empty-directories-in-a-subtree/107556#107556

### Removing duplicates

Among all (two) utilities I checked for removing duplicates, [rmlint][] seems to
work best. Recommended options to use it are:

	rmlint -T df -c sh:hardlink -k --keep-hardlinked data // current

[rmlint]: https://github.com/sahib/rmlint

### Migrating from "old" (rsync --link-dest) style to current one.

If you used my [previous backup system][1], you can easily migrate to this new
one with help of `migrate.sh` script. Read its comment on top for usage
instructions, and also note that it has hardcoded path to `~/backup3/backup.sh`.
