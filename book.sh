#!/bin/bash

DIR=$(dirname $(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null||echo $0))

VERSION="0.5"
PROGRAM_NAME="Books Downloader"
# Get supported providers by the filename.
readarray -t SUPPORTER_PROVIDERS < <(ls ./providers/ -1)
PROVIDER_NAME=""
PACKER="FB2"

# Colors 
CGreen='\033[0;32m' # Green
CRed='\033[0;31m' # Red
CN='\033[0m' # No Color

# Array to store urls
URLS=()

# Store arguments in a special array
args=("$@")
URL=""
regex='(https?|ftp|file)://[-[:alnum:]\+&@#/%?=~_|!:,.;]*[-[:alnum:]\+&@#/%=~_|]'
if [[ ${args[0]} =~ $regex ]]
then 
    URL=${args[0]}
    URLS+=("${args[0]}")
    unset args[0]
fi

# Book filename.
FILENAME=""
# Folder to store temprorary files.
FILES_DIR="files"
# Folder to store temprorary downloaded images
IMAGES_DIR="images"
IMAGES_DOMAIN=""
BOOKS_DIR="/home/public/Books/2025"
# Global file to save the book.
FILENAME="$BOOKS_DIR/test.fb2"
# Main book cover image.
IMAGE_COVER_URL=""
# Store images urls in array to process at the end of the file.
IMAGES_URLS=()
LIST_FILE=""

# Loading helpers and packer.
. "$DIR/scripts/helpers.sh"
. "$DIR/scripts/packer.sh"

for i in "${args[@]}"; do
case "$i" in
    --debug)
    DEBUG="1"
    ;;
    --list=*)
    LIST_FILE="${i#*=}"
    ;;
    --help)
    show_help
    ;;
    --clean)
    ;;
    *)
esac
shift
done

if [ ! -z "$LIST_FILE" ]; then
    if [ ! -f "$LIST_FILE" ]; then
        show_help "Error: File '$LIST_FILE' not found"
    fi
    
    # Clear the array before loading
    URLS=()
    
    # Read file line by line and add to array
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and lines starting with #
        if [ -n "$line" ] && [[ ! "$line" =~ ^[[:space:]]*# ]]; then
            if [[ $line =~ $regex ]]; then
                URLS+=("$line")
            fi
        fi
    done < "$LIST_FILE"
fi

# Show help if no parameters were provided
if [ -z "$URLS" ]; then
    show_help "ERROR. No urls were provided."
fi

#================== START ==================
echo "$PROGRAM_NAME v.$VERSION is starting..."

# Process all urls
for i in "${!URLS[@]}"; do
    URL="${URLS[$i]}"
    echo "$URL"

    PROVIDER_NAME=$(echo $URL | awk -F[/:] '{print $4}')
    if [[ ! " ${SUPPORTER_PROVIDERS[@]} " =~ " $PROVIDER_NAME " ]]; then
        echo -e "$CRed Download error $CN. Wrong website name $CGreen ($PROVIDER_NAME) $CN was used in the input.";
        continue
    fi

    # Loading scripts relates to website.
    . "$DIR/providers/$PROVIDER_NAME"

    # Clear everything
    rm -rf $IMAGES_DIR/*
    rm -rf $FILES_DIR/*

    # Create folder
    [ -d $BOOKS_DIR ] || mkdir -p $BOOKS_DIR

    process_book

    echo "Book possibly was saved to: $FILENAME"
done

echo "$PROGRAM_NAME finished."
