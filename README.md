# sync_photos

sync_photos.rb [options]
    -c, --config NAME                Config name, one of [steeve]
    -s, --src DIR                    Source directory, default /run/media/steeve
    -d, --dst DIR                    Backup directory, default /var/tmp/sync_photos/steeve/backup
    -y, --yes                        Answer yes to prompts
    -n, --dry-run                    Dry run
    -p, --progress                   Progress output
        --[no-]purge                 Delete after copy, default is false
    -q, --quiet                      Quiet things down
    -v, --verbose                    Verbose output
    -D, --debug                      Turn on debugging output
    -h, --help                       Help

Description:

	Sync photos from source to destination directories sorting by YYYY/MM/DD
	dates are grokked from EXIF data.  Uses rsync to transfer files from source
	to destination directories.

Environment variables:

	SYNC_PHOTOS  - destination directory for photo sync (not set)

