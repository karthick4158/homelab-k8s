#!/bin/sh
# Rename "<anything> - Title (YYYY)<anything>.mkv" in SOURCE_DIR to
# "Title (YYYY).mkv" and move it to TARGET_DIR. Run by the mkv-rename CronJob
# (mkv-rename.yaml), which sets SOURCE_DIR and TARGET_DIR. POSIX sh / busybox
# ash: no bashisms.
#
# Safe to rerun: never overwrites an existing target, skips names without a
# "(YYYY)" match, and leaves files modified in the last 2 minutes alone (still
# being written).

case "$SOURCE_DIR$TARGET_DIR" in
    *CHANGE_ME*)
        echo "ERROR: SOURCE_DIR/TARGET_DIR still contain CHANGE_ME; set them in apps/media/mkv-rename.yaml" >&2
        exit 1
        ;;
esac
if [ -z "$SOURCE_DIR" ] || [ -z "$TARGET_DIR" ]; then
    echo "ERROR: SOURCE_DIR and TARGET_DIR must both be set" >&2
    exit 1
fi
if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: SOURCE_DIR does not exist: $SOURCE_DIR" >&2
    exit 1
fi

# Group-writable, like the other apps (UMASK 002).
umask 002
mkdir -p "$TARGET_DIR" || exit 1

for f in "$SOURCE_DIR"/*.mkv; do
    [ -e "$f" ] || continue
    filename=$(basename "$f")

    # Still being written: find prints the file only if mtime < 2 min ago.
    if [ -n "$(find "$f" -maxdepth 0 -mmin -2)" ]; then
        echo "Skipped (modified in the last 2 minutes): $filename"
        continue
    fi

    clean_name=$(echo "$filename" | sed -E 's/.* - ([^(]+ \([0-9]{4}\)).*/\1.mkv/')
    clean_name=$(echo "$clean_name" | sed 's/[[:space:]]*$//')
    if [ "$clean_name" = "$filename" ]; then
        echo "No match, skipped: $filename"
        continue
    fi

    if [ -e "$TARGET_DIR/$clean_name" ]; then
        echo "Skipped, target exists: $filename -> $clean_name"
        continue
    fi

    echo "Renaming:"; echo "  $filename"; echo "  → $clean_name"
    # -n: never overwrite, even if the target appeared since the check above.
    mv -n "$f" "$TARGET_DIR/$clean_name"
done
