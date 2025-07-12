#!/bin/bash

# Store arguments in a special array 
args=("$@")
URL=""
regex='(https?|ftp|file)://[-[:alnum:]\+&@#/%?=~_|!:,.;]*[-[:alnum:]\+&@#/%=~_|]'
if [[ ${args[0]} =~ $regex ]]
then 
    URL=${args[0]}
    unset args[0]
fi

FILE_IDENTITY=""
# Cookie for authenticated download
COOKIE_IDENTITY=""
# Flag to force download of incomplete book.
INCOMPLETE_DOWNLOAD=""
FILES_DIR="files"
# Folder to store temprorary downloaded images
IMAGES_DIR="images"
BOOKS_DIR="/home/public/Books/booknet_ua"
# Store images urls in array to process at the end of the file.
IMAGES_URLS=()
# Main book cover image.
IMAGE_COVER_URL=""

# Files values
COOKIES_FILE="$FILES_DIR/cookies.txt"
AJAX_RESPONSE_FILE="$FILES_DIR/ajax_response.json"
PAGE_HTML="$FILES_DIR/book_ua_page.html"

PAGE_TEXT=""

for i in "${args[@]}"; do
  case "$i" in
    --identity*)
      FILE_IDENTITY="./identity.txt"
      ;;
    --incomplete*)
      INCOMPLETE_DOWNLOAD="1"
	  ;;  
    --debug)
      DEBUG="1"
      ;;
    --help)
	  echo "Usage: ./booknet_ua.sh https://booknet.ua/reader/mainpage-1234566"
	  echo "Params:"
	  echo "--identity - Using identity.txt file where you should place value from _identity cookie when you're logged in."
	  echo "--incomplete - Download book even if it's not full (non-free)"
      exit
	  ;;
	--clean)
	  #echo "Clear all variables and tmp segments."
	  #rm -rf $VARS_DIR/*
	  #rm -rf $OUTPUT_SEGMENTS/*
	  ;;  
    *)
  esac
  shift
done

if [ ! -z "$FILE_IDENTITY" ]; then
	if test -f "$FILE_IDENTITY"; then
		IDENTITY_VALUE=$(< "$FILE_IDENTITY")
		COOKIE_IDENTITY="_identity=$IDENTITY_VALUE;"
	fi
fi


# Check if link to page is present.
if [ -z "$URL" ]; then
    echo "No url or incorret url supplied. Please use collection name. (ex: https://booknet.ua/reader/smttyar-b155659)"
    exit
fi 

if [ ! -z "$COOKIE_IDENTITY" ]; then
	echo ">>> Using Identity in requests. All bought content should be available <<<"
fi

# Get META content attr by property attr.
get_meta_property()
{
	grep -r ".*<meta property=\"$2\" content=\"\(.*\)\"" $1 |
	sed -e "s/.* content=\"\(.*\)\".*/\1/"
}

# Get META content attr by name attr.
get_meta_name()
{
	grep -r ".*<meta name=\"$2\" content=\"\(.*\)\"" $1|
	sed -e "s/.* content=\"\(.*\)\".*/\1/"
}

# Get cookie from curl saved cookies file.
get_cookie()
{
	cat $1 |
	grep ".*$2" | cut -f7
}

get_book_author()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i a.sa-name |
	sed -e 's/<[^>]*>//g' -e 's/\r//'
}

get_book_genre()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i div.col-md-12.jsAddTargetBlank a |
	tr -d '\n' | hxpipe | awk -F "^-" '{print $2}' | grep "\S"
}

get_chapters_list()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i select.js-chapter-change | 
	sed 's/<option/<a/g' | #replacements to make hxwls work
	sed 's/option>/a>/g' | #replacements to make hxwls work
	sed 's/value=/href=/g' |  #replacements to make hxwls work
	hxwls
}

get_chapters_names()
{
	cat $1 |
	hxnormalize -x -e -s | 
	hxselect -i select.js-chapter-change | 
	sed -e 's/<select[^>]*>//g' | 
	sed 's/<option/<a/g' | 
	sed 's/option>/a>/g' | 
	sed 's/value=/href=/g' | 
	tr -d '\n' | hxpipe | awk -F "-" '{print $2}' | grep "\S"
}

# $1 - URL
# $2 - page url with chapter
# $3 - page num
get_ajax_page()
{
	curl 'https://booknet.ua/reader/get-page' \
	-H 'accept: application/json, text/javascript, */*; q=0.01' \
	-H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
	-H "cookie: _csrf=$CSRF_COOKIE;$COOKIE_IDENTITY" \
	-H "referer: $1?c=$2" \
	-H "x-csrf-token: $CSRF_TOKEN" \
	-o "$AJAX_RESPONSE_FILE" \
	-X POST \
	--silent \
	--data-raw "chapterId=$2&page=$3&_csrf=$CSRF_TOKEN" 
}

# Simple solution to get json value by key.
get_json_val()
{
	cat $1 | \
	php -r "echo json_decode(file_get_contents('php://stdin'))->$2 ?? '';"
}

process_images()
{
	PAGE_TEXT=$(echo "$PAGE_TEXT" | sed -e 's|&amp;|\&|g')
	
	IMAGES_TMP=($(echo "$PAGE_TEXT" |
	hxnormalize -x -e -s |
	hxselect -i img |
	hxwls
	))
	
	for image in "${IMAGES_TMP[@]}";
	do
		if [ ! -z "$image" ]; then
			if [ -z "$(echo $image | grep facebook)" ]; then
				IMAGES_URLS+=("$image")
				FNAME=$(basename $image)
				# Change extesion to jpg.
				FNAME="${FNAME%.*}.jpg"
				PAGE_TEXT=`echo "$PAGE_TEXT" | sed -e "s|$image|#$FNAME|g"`
				#echo "Image was found in the text $FNAME"
			else
				# Replace img urls from the text.
				PAGE_TEXT=`echo "$PAGE_TEXT" | sed -e "s|$image|#pixel.jpg|g"`
			fi
		fi
	done
	
	PAGE_TEXT=`echo "$PAGE_TEXT" | sed -e "s|src=|l:href=|g"`
	PAGE_TEXT=`echo "$PAGE_TEXT" | sed -e "s|img|image|g"`
}
  
write_fb2_header()
{
	if [ -f "$FILENAME" ]; then
		rm "$FILENAME"
	fi
	touch "$FILENAME";
	echo '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">' > "$FILENAME";
}

write_fb2_footer()
{
	echo '</body>' >> "$FILENAME";
	if [ ! -z "$IMAGE_COVER_URL" ]; then
		echo '<binary id="cover.jpg" content-type="image/jpeg">' >> "$FILENAME";
		wget -O $IMAGES_DIR/cover.jpg --no-verbose --quiet $IMAGE_COVER_URL
		base64 $IMAGES_DIR/cover.jpg >> "$FILENAME";
		echo '</binary>' >> "$FILENAME";
	fi
	
	IMAGES_URLS_TOTAL="${#IMAGES_URLS[@]}"
	echo "Images to process: $IMAGES_URLS_TOTAL"
	# Add images binaries.
	for image in "${IMAGES_URLS[@]}";
	do
		FNAME=$(basename $image)
		FNAME_JPEG="${FNAME%.*}.jpg"
		echo "<binary id=\"$FNAME_JPEG\" content-type=\"image/jpeg\">" >> "$FILENAME";
		wget -O $IMAGES_DIR/$FNAME --no-verbose --quiet $image
		# Converting images to JPG format.
		convert -quality 50 $IMAGES_DIR/$FNAME $IMAGES_DIR/$FNAME_JPEG
		base64 $IMAGES_DIR/$FNAME_JPEG >> "$FILENAME";
		echo '</binary>' >> "$FILENAME";
	done

	echo '</FictionBook>' >> "$FILENAME";
}

write_fb2_description()
{
	echo '<description><title-info>' >> "$FILENAME";
	echo "<book-title>$1</book-title>"  >> "$FILENAME";
	echo "<genre>$3</genre>" >> "$FILENAME";
	echo "<author><first-name>$2</first-name><middle-name></middle-name><last-name></last-name></author>" >> "$FILENAME";
	echo '<from>Downloaded from booknet.ua. Converted by 16rom.com</from>' >> "$FILENAME";
	echo "<annotation><p>$4</p></annotation>"  >> "$FILENAME";
	if [ ! -z "$IMAGE_COVER_URL" ]; then
		echo '<coverpage><image l:href="#cover.jpg"></image></coverpage>' >> "$FILENAME";
	fi
	echo '<lang>ua</lang></title-info></description><body xmlns:fb="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:xlink="http://www.w3.org/1999/xlink">' >> "$FILENAME";
}

write_fb2_text()
{
	PAGE_TEXT="$1"
	process_images
	echo "$PAGE_TEXT" >> "$FILENAME";
	#echo "$(process_images "$1")" >> "$FILENAME";
		#IMAGES_URLS_TOTAL="${#IMAGES_URLS[@]}"
	#echo "Images to process: $IMAGES_URLS_TOTAL"
}


token_refresh()
{
	# Get page and save cookies.
	if [ ! -z "$COOKIE_IDENTITY" ]; then
		curl -o "$PAGE_HTML" --silent --no-verbose --cookie-jar $COOKIES_FILE -H "cookie:$COOKIE_IDENITY" $URL
	else
		curl -o "$PAGE_HTML" --silent --no-verbose --cookie-jar $COOKIES_FILE $URL
	fi
	
	CSRF_TOKEN=$(get_meta_name $PAGE_HTML "csrf-token")
	CSRF_COOKIE=$(get_cookie $COOKIES_FILE "_csrf")
}
#================== START ==================

# Edit url to reader page.
echo "booknet.ua downloader is starting..."

URL=$(echo "$URL" | sed "s/\/book\//\/reader\//")
FILENAME=$(echo "$URL" | sed "s/https:\/\/booknet.ua\/reader\///" | sed 's/.html.*//' | sed -e 's/^[0-9]\+-*//g').fb2

if [ -f "$PAGE_HTML" ]; then rm "$PAGE_HTML";  fi
# if [ -f "./cover.jpg" ]; then rm "./cover.jpg"; fi

rm -rf $IMAGES_DIR/*.**
rm -rf $FILES_DIR/*.**

token_refresh

CHAPTERS=($(get_chapters_list $PAGE_HTML))
# Check if all book is available.
CHAPTERS_TOTAL="${#CHAPTERS[@]}"
CHAPTERS_TOTAL=$((CHAPTERS_TOTAL-1))
get_ajax_page $URL ${CHAPTERS[$CHAPTERS_TOTAL]} 1
TOTALPAGES=$(get_json_val $AJAX_RESPONSE_FILE totalPages)

if [ -z "$TOTALPAGES" ] && [ -z "$INCOMPLETE_DOWNLOAD" ]; then
	echo "!! Complete book is not available. You should pay for it !!"
	exit;
fi

FILENAME="$BOOKS_DIR/$FILENAME"
echo "Book will be saved to $FILENAME" 

IMAGE_COVER_URL=$(get_meta_property $PAGE_HTML "og:image")
BOOK_TITLE=$(get_meta_property $PAGE_HTML "og:title")
BOOK_DESCRIPTION=$(get_meta_property $PAGE_HTML "og:description")
BOOK_AUTHOR=$(get_book_author $PAGE_HTML)

echo $BOOK_AUTHOR
echo $BOOK_TITLE
echo $BOOK_DESCRIPTION

readarray -t BOOK_GENRE_TMP < <(get_book_genre $PAGE_HTML)
IFS=\, eval 'BOOK_GENRE="${BOOK_GENRE_TMP[*]}"'
echo $BOOK_GENRE


readarray -t CHAPTERS_NAMES < <(get_chapters_names $PAGE_HTML)


if [ -z "$CHAPTERS" ]; then
	echo "No chapters were found! exit";
	exit;
fi

write_fb2_header
write_fb2_description "$BOOK_TITLE" "$BOOK_AUTHOR" "$BOOK_GENRE" "$BOOK_DESCRIPTION"

CHAPTER_NUM=0
echo "Processing ${#CHAPTERS[@]} chapters."
for chapter in "${CHAPTERS[@]}";
do
	echo "Process chapter: $CHAPTER_NUM - ${CHAPTERS_NAMES[$CHAPTER_NUM]}, page: 1"
	
	# Write section start.
	write_fb2_text "<section><title><p>${CHAPTERS_NAMES[$CHAPTER_NUM]}</p></title>"
	get_ajax_page $URL $chapter 1
	TOTALPAGES=$(get_json_val $AJAX_RESPONSE_FILE totalPages)
	
	if [ -z "$TOTALPAGES" ]; then
		echo 'Lets try to refresh csrf tokens. 2mins waiting...';
		sleep 120
		token_refresh
		get_ajax_page $URL $chapter 1
		TOTALPAGES=$(get_json_val $AJAX_RESPONSE_FILE totalPages)
		if [ -z "$TOTALPAGES" ]; then
			echo "Total pages not found. Fatal error. Book could be not free. Exit.";
			# Save finished data and exit.
			write_fb2_text "</section>"
			write_fb2_footer
			exit;
		fi
	fi
	

	# Write data text.
	PAGE_TEXT="$(get_json_val $AJAX_RESPONSE_FILE data)"
	write_fb2_text 

	if [ "$TOTALPAGES" -gt 1 ]; then
		# echo "chapter has pages: $TOTALPAGES"
		for (( i=2; i <= $TOTALPAGES; ++i ))
		do
		echo "Process chapter: $CHAPTER_NUM page: $i"
		get_ajax_page $URL $chapter $i
		write_fb2_text "$(get_json_val $AJAX_RESPONSE_FILE data)"
		#sleep 2
		done
	fi

	# Write section end.
	CHAPTER_NUM=$((CHAPTER_NUM+1))
	write_fb2_text "</section>"
	#sleep 2
done

write_fb2_footer

echo "booknet.ua downloader finished."
