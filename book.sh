#!/bin/bash

DIR=$(dirname $(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null||echo $0))

VERSION="0.3"
PROGRAM_NAME="Books Downloader"
SUPPORTER_PROVIDERS=("booknet.ua" "readukrainianbooks.com" "uabooks.net" "bookuruk.com")
PROVIDER_NAME=""
PACKER="FB2"

# Colors 
CGreen='\033[0;32m' # Green
CRed='\033[0;31m' # Red
CN='\033[0m' # No Color

# Store arguments in a special array 
args=("$@")
URL=""
regex='(https?|ftp|file)://[-[:alnum:]\+&@#/%?=~_|!:,.;]*[-[:alnum:]\+&@#/%=~_|]'
if [[ ${args[0]} =~ $regex ]]
then 
	URL=${args[0]}
	unset args[0]
fi

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

# Loading helpers and packer.
. "$DIR/scripts/helpers.sh"
. "$DIR/scripts/packer.sh"

# Check if link to page is present.
if [ -z "$URL" ]; then
	echo "No url supplied. Please use correct name. (ex: https://ssss.sss/sss.html)"
	echo -e "Downloader works with websites: $CGreen ${SUPPORTER_PROVIDERS[*]} $CN"
	echo 'You can use additional parameters:'
	exit
fi

for i in "${args[@]}"; do
case "$i" in
	# --identity*)
	# FILE_IDENTITY="./identity.txt"
	# ;;
	# --incomplete*)
	# INCOMPLETE_DOWNLOAD="1"
	# ;;  
	--debug)
	DEBUG="1"
	;;
	# --help)
	# echo "Usage: ./book.sh https://booknet.ua/reader/mainpage-1234566"
	# echo "Params:"
	# echo "--identity - Using identity.txt file where you should place value from _identity cookie when you're logged in."
	# echo "--incomplete - Download book even if it's not full (non-free)"
	# exit
	# ;;
	--clean)
	#echo "Clear all variables and tmp segments."
	#rm -rf $VARS_DIR/*
	#rm -rf $OUTPUT_SEGMENTS/*
	;;  
	*)
esac
shift
done

#================== START ==================
echo "$PROGRAM_NAME v.$VERSION is starting..."
PROVIDER_NAME=$(echo $URL | awk -F[/:] '{print $4}')
if [[ ! " ${SUPPORTER_PROVIDERS[@]} " =~ " $PROVIDER_NAME " ]]; then
	echo -e "Wrong website name $CGreen ($PROVIDER_NAME) $CN was used in input.";
	echo "Please use one of:";
	for p in ${SUPPORTER_PROVIDERS[@]}; do echo $p; done;
	exit 1;
fi

# Loading scripts relates to website.
. "$DIR/providers/$PROVIDER_NAME"

# Clear everything
rm -rf $IMAGES_DIR/*.**
rm -rf $FILES_DIR/*.**

# Create folder
[ -d $BOOKS_DIR ] || mkdir -p $BOOKS_DIR

process_book

echo "$PROGRAM_NAME finished."
