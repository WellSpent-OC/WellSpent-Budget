#!/bin/sh
# Keeps only the screenshots in a folder of attachments exported from a UI
# test's result bundle, and deletes everything else. CI uploads what is left
# when a test fails.
#
#   scripts/keep-images.sh FOLDER
#
# xcresulttool exports attachments under bare IDs with no extension, so a file
# is judged by what it holds, not by its name. An image is kept and given the
# extension its type names, so it opens on a click. Anything else goes: an
# activity log can hold what was typed into the sign-in fields, and the
# artifacts of a public repo are public.
set -eu

folder="${1:?usage: scripts/keep-images.sh FOLDER}"
[ -d "$folder" ] || exit 0

find "$folder" -type f | while read -r file; do
    case "$(file -b --mime-type "$file")" in
        image/png) case "$file" in *.png) ;; *) mv "$file" "$file.png" ;; esac ;;
        image/jpeg) case "$file" in *.jpg|*.jpeg) ;; *) mv "$file" "$file.jpg" ;; esac ;;
        image/heic) case "$file" in *.heic) ;; *) mv "$file" "$file.heic" ;; esac ;;
        *) rm -f "$file" ;;
    esac
done
