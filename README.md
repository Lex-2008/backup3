backup3
=======

My ~~third~~ _actually, forth_ attempt at making backups - using bash and SQLite.

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

So the idea is to keep only _one_ copy of each inuque file, plus keep _somewhere_ a time range when it existed, and use a script to reconstruct file tree for a given time using this data. Sounds like a good task for a database?

So it work like this:

* First, rsync updates all files in a "current backup" directory.
  By default it doesn't do it "in place" - instead, it first creates new version and then replaces old one with it, so its inode number changes.
  Note this, we will use it later.

* Then, we compare current state of "current backup" dir with what was there previousely:

  * New files we hardlink to "storage" directory (so they didn't get lost if deleted from "current backup"),
    and record them into database, together with "creation" date.

  * For deleted files we just note their "deletion" date in the database.

  * Changed files we treat as "old version deleted, new version created".

Setup
-----

Find a writeable dir to keep your backups in (say, `/var/backups`) and run:

	BACKUP_ROOT=/var/backups init.sh

It will create necessary dirs and sqlite database to hold information.

### Requirements

* sqlite3
* flock
* bc
* df

Simple usage
------------

To backup your `/home` directory every now and then, save this file into your
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
of your `$HOME` directory - only once an hour? Then use a file like this:

	#!/bin/bash

	export BACKUP_ROOT=/var/backups

	# Operations to run on every backup
	run_always()
	{
		# Backup browser profile
		run_rsync /home/lex/.config/google-chrome/Default/ browser
	}

	# Operations to run every hour
	run_hourly()
	{
		# Backup whole home directory
		run_rsync /home/lex home
	}

	# Run backup operations
	. backup.sh

Note that in last line we _source_ instead of running this script - this way we
can ensure that `backup.sh` script will see declared functions. Also note
hashbang in first line - `backup.sh` must be executed by bash.

Clean-up
--------

To ensure that 10% of disk space remains free, add these lines to the end of
above file:

	# delete old versions until at least 10% of disk space is free
	clean.sh 10 %

Restore from backup
-------------------

You can either dig manually in data dir, or use `flat.sh` to show contents of
archive for a given date.

Check that database is correct
------------------------------

It may happen that data in database is out of sync with actual files. To check
for that, run `check.sh`. To fix it by deleting existing DB records for missing
files and existing files for missing DB records, run `check.sh --delete`.

Rollback backup to previous version
-----------------------------------

In default configuration, backup database is backed up every time, too. To
restore it, pick one that you like and move it in place of current one
(`$BACKUP_ROOT/current/backup.db` by default). After that, run
`check.sh --delete` to synchronize DB with FS.
