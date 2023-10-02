import sys
import os
import shutil
from pprint import pprint
from collections import OrderedDict

# note that files in subdirs are still included
exclude_files={'Thumbs.db'}
min_matches=1
min_match_prc=10
dryrun=True

# new_dirs and del_dirs have a directory name as key, and set of filenames
# (with this directory name stripped) as value. for example, for this rsync.log:
# cd+++++++++ dir/
# >f+++++++++ dir/file1.ext
# >f+++++++++ dir/file2.ext
# >f+++++++++ dir/sub/file3.ext
# new_files is like this:
# OrderedDict([('dir/',
#               {'file1.ext',
#                'file2.ext',
#                'sub/file3.ext'})])
new_dirs=OrderedDict()
del_dirs=OrderedDict()
del_files=[]

for line in sys.stdin:
    operation = line[:12]
    filename = line[12:].strip()

    # note that new dirs appear before new files
    if operation == 'cd+++++++++ ':
        new_dirs[filename]=set()
    elif operation == '>f+++++++++ ':
        if filename not in exclude_files:
            for dirname in new_dirs:
                if filename.startswith(dirname):
                    new_dirs[dirname].add(filename[len(dirname):])

    # note that deleted dirs appear **AFTER** deleted files
    elif operation == '*deleting   ':
        if not filename.endswith('/'):
            if filename not in exclude_files:
                del_files.append(filename)
        else:
            # this is a directory
            dirname=filename
            del_dirs[dirname]=set((filename[len(dirname):] for filename in del_files if filename.startswith(dirname)))

#pprint(new_dirs)
#pprint(del_dirs)

if not len(new_dirs) or not len(del_dirs):
    sys.exit(0)

del_files=[]

if len(sys.argv) > 1:
    os.chdir(sys.argv[1])

modified=False
copied=set() # set of already-copied dirs
# now, for each new_dir find the best del_dir candidate
for (new_dirname, new_files) in new_dirs.items():
    # skip over subdirs of already copied dirs
    if any((1 for copied_dir in copied if new_dirname.startswith(copied_dir))):
        continue
    del_dirname = sorted(del_dirs, key=lambda dirname: len(new_files & del_dirs[dirname]), reverse=True)[0]
    matches = len(new_files & del_dirs[del_dirname])
    if matches < min_matches or matches*100/len(new_files) < min_match_prc:
        continue
    copied.add(new_dirname)
    print('cp -al %s %s # %d matched (%d%%)' % (del_dirname, new_dirname, matches, matches*100/len(new_files)))
    if dryrun:
        modified = True
    else:
        shutil.copytree(del_dirname, new_dirname, symlinks=True, copy_function=os.link, dirs_exist_ok=True)

if modified:
    sys.exit(1)
