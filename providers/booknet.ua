#!/bin/bash

# Cookie for authenticated download
COOKIE_IDENTITY=""
# Flag to force download of incomplete book.
INCOMPLETE_DOWNLOAD=""

# Files values
COOKIES_FILE="$FILES_DIR/cookies.txt"
AJAX_RESPONSE_FILE="$FILES_DIR/ajax_response.json"
PAGE_HTML="$FILES_DIR/book_ua_page.html"
# Save info from your cookie form the browser
# to donwload the books you've bought.
FILE_IDENTITY="./identity.txt"
FILE_CSRF="./csrf.txt"

CSRF=""

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

	# Uncomment to save each request data.
	#cp "$AJAX_RESPONSE_FILE" "$FILES_DIR/$2-$3.json"
	#get_json_val $AJAX_RESPONSE_FILE data > "$FILES_DIR/$2-$3.data"
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

echo "Author: $BOOK_AUTHOR"
echo "Title: $BOOK_TITLE"
echo "Description: $BOOK_DESCRIPTION"

# Get book genre.
readarray -t BOOK_GENRE_TMP < <(get_book_genre $PAGE_HTML)
IFS=\, eval 'BOOK_GENRE="${BOOK_GENRE_TMP[*]}"'
echo "Genre: $BOOK_GENRE"

# Get chapters names.
readarray -t CHAPTERS_NAMES < <(get_chapters_names $PAGE_HTML)

if [ -z "$CHAPTERS" ]; then
	echo "No chapters were found! exit";
	exit;
fi

book_header
book_description "$BOOK_TITLE" "$BOOK_AUTHOR" "$BOOK_GENRE" "$BOOK_DESCRIPTION"

CHAPTER_NUM=0
# Debug stuff to skip downloading chapters from beginning.
if [ $CHAPTER_NUM -gt 0 ]; then
	for (( i=0;i<$(($CHAPTER_NUM));i++)); do
		unset CHAPTERS[$i]
	done
fi

echo "Processing ${#CHAPTERS[@]} chapters."
for chapter in "${CHAPTERS[@]}";
do
	# Write section start.
	book_text "<section><title><p>${CHAPTERS_NAMES[$CHAPTER_NUM]}</p></title>"
	get_ajax_page $URL $chapter 1
	TOTALPAGES=$(get_json_val $AJAX_RESPONSE_FILE totalPages)
	
	echo "Process chapter: $CHAPTER_NUM - ${CHAPTERS_NAMES[$CHAPTER_NUM]}, page: 1 / $TOTALPAGES"

	if [ -z "$TOTALPAGES" ]; then
		echo 'Lets try to refresh csrf tokens. 2 mins waiting...';
		sleep 120
		token_refresh
		get_ajax_page $URL $chapter 1
		TOTALPAGES=$(get_json_val $AJAX_RESPONSE_FILE totalPages)
		if [ -z "$TOTALPAGES" ]; then
			echo "Total pages not found. Fatal error. Book could be not free. Exit.";
			# Save finished data and exit.
			book_text "</section>"
			book_footer
			exit
		fi
	fi

	# Write data text.
	book_text "$(get_json_val $AJAX_RESPONSE_FILE data)"

	if [ "$TOTALPAGES" -gt 1 ]; then
		# echo "chapter has pages: $TOTALPAGES"
		for (( i=2; i <= $TOTALPAGES; ++i ))
		do
		echo "Process chapter: $CHAPTER_NUM - ${CHAPTERS_NAMES[$CHAPTER_NUM]}, page: $i / $TOTALPAGES"
		get_ajax_page $URL $chapter $i
		book_text "$(get_json_val $AJAX_RESPONSE_FILE data)"
		#sleep 2
		done
	fi

	# Write section end.
	CHAPTER_NUM=$((CHAPTER_NUM+1))
	book_text "</section>"
	#sleep 2
done

book_footer

}
