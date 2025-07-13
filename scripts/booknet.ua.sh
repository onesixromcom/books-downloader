#!/bin/bash

FILE_IDENTITY=""
# Cookie for authenticated download
COOKIE_IDENTITY=""
# Flag to force download of incomplete book.
INCOMPLETE_DOWNLOAD=""
# Store images urls in array to process at the end of the file.
IMAGES_URLS=()
# Main book cover image.
IMAGE_COVER_URL=""

# Files values
COOKIES_FILE="$FILES_DIR/cookies.txt"
AJAX_RESPONSE_FILE="$FILES_DIR/ajax_response.json"
PAGE_HTML="$FILES_DIR/book_ua_page.html"
# Save info from your cookie form the browser
# to donwload the books you've bought.
FILE_IDENTITY="./identity.txt"
FILE_CSRF="./csrf.txt"

CSRF=""
# Global variable with the book's text.
PAGE_TEXT=""

for i in "${args[@]}"; do
case "$i" in
	--incomplete*)
	INCOMPLETE_DOWNLOAD="1"
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

if [ ! -z "$FILE_CSRF" ]; then
	if test -f "$FILE_CSRF"; then
		CSRF_VALUE=$(< "$FILE_CSRF")
		COOKIE_CSRF="_csrf=$CSRF_VALUE;"
	fi
fi

if [ ! -z "$COOKIE_IDENTITY" ]; then
	echo ">>> Using Identity in requests. All bought content should be available <<<"
fi

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
# $2 - chapter num
# $3 - page num
get_ajax_page()
{
	curl 'https://booknet.ua/reader/get-page' \
	-H 'accept: application/json, text/javascript, */*; q=0.01' \
	-H 'accept-language: en-US,en;q=0.9' \
	-H 'cache-control: no-cache' \
	-H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
	-b "$COOKIE_CSRF;$COOKIE_IDENTITY;" \
	-H 'origin: https://booknet.ua' \
	-H 'pragma: no-cache' \
	-H 'priority: u=1, i' \
	-H "referer: $1" \
	-H 'sec-ch-ua: "Not)A;Brand";v="8", "Chromium";v="138"' \
	-H 'sec-ch-ua-mobile: ?0' \
	-H 'sec-ch-ua-platform: "Linux"' \
	-H 'sec-fetch-dest: empty' \
	-H 'sec-fetch-mode: cors' \
	-H 'sec-fetch-site: same-origin' \
	-H 'user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36' \
	-H "x-csrf-token: $CSRF_TOKEN" \
	-H 'x-requested-with: XMLHttpRequest' \
	-o "$AJAX_RESPONSE_FILE" \
	--silent \
	--data-raw "chapterId=$2&page=$3&_csrf=$CSRF_TOKEN"

	# debug data
	#cp "$AJAX_RESPONSE_FILE" "$FILES_DIR/$2-$3.json"
	#get_json_val $AJAX_RESPONSE_FILE data > "$FILES_DIR/$2-$3.data"
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
	echo "$PAGE_TEXT" >> "$FILENAME"
}


token_refresh()
{
	#echo "-> Refresh request tokens."
	#echo "$COOKIE_CSRF;$COOKIE_IDENTITY"
	# Get page and save cookies.
	if [ ! -z "$COOKIE_IDENTITY" ]; then
		curl $URL\
		-b "$COOKIE_CSRF;$COOKIE_IDENTITY" \
		-H 'pragma: no-cache' \
		-H 'priority: u=0, i' \
		-H 'sec-ch-ua: "Not)A;Brand";v="8", "Chromium";v="138"' \
		-H 'sec-ch-ua-mobile: ?0' \
		-H 'sec-ch-ua-platform: "Linux"' \
		-H 'sec-fetch-dest: document' \
		-H 'sec-fetch-mode: navigate' \
		-H 'sec-fetch-site: none' \
		-H 'sec-fetch-user: ?1' \
		-H 'service-worker-navigation-preload: true' \
		-H 'upgrade-insecure-requests: 1' \
		-H 'user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36' \
		-o "$PAGE_HTML" --silent --no-verbose 
	else
		curl -o "$PAGE_HTML" --silent --no-verbose --cookie-jar $COOKIES_FILE $URL
		CSRF=$(get_cookie $COOKIES_FILE "_csrf")
		COOKIE_CSRF="_csrf=$CSRF"
	fi
	
	CSRF_TOKEN=$(get_meta_name $PAGE_HTML "csrf-token")
	
	#echo "csrf-token: $CSRF_TOKEN"
	#echo "cookie _csrf: $COOKIE_CSRF"
}

#================== START ==================

process_book()
{
# Edit url to reader page.
URL=$(echo "$URL" | sed "s/\/book\//\/reader\//")
FILENAME=$(echo "$URL" | sed "s/https:\/\/booknet.ua\/reader\///" | sed 's/.html.*//' | sed -e 's/^[0-9]\+-*//g').fb2

# if [ -f "$PAGE_HTML" ]; then rm "$PAGE_HTML";  fi

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
	echo -e "$CRed !! Complete book is not available. You should pay for it !! $CN"
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

$ Get book genre.
readarray -t BOOK_GENRE_TMP < <(get_book_genre $PAGE_HTML)
IFS=\, eval 'BOOK_GENRE="${BOOK_GENRE_TMP[*]}"'
echo $BOOK_GENRE

# Get chapters names.
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
	write_fb2_text "$(get_json_val $AJAX_RESPONSE_FILE data)"

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

}
