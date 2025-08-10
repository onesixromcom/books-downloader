# Download books from bookuruk.com website.
# Provide the main book page to process.
# example: https://bookuruk.com/book/somebook

PAGE_HTML="$FILES_DIR/bookuruk_page.html"
PAGE_HTML2="$FILES_DIR/bookuruk_page2.html"

#================== START ==================

process_book()
{
	get_html_page $URL $PAGE_HTML

	# Get book chapters.
	CHAPTERS_LINK=""
	LINKS=($(cat $PAGE_HTML | hxnormalize -x -e -d -s | hxselect -i main.single nav | hxwls))
	for link in "${LINKS[@]}";
	do
		if [[ $link == /book/chapters* ]]; then
			echo "Chapters page found $link"
			CHAPTERS_LINK=$link
		fi
	done

	IMAGE_COVER_URL=$(get_meta_property $PAGE_HTML "og:image")
	BOOK_TITLE=$(cat $PAGE_HTML | hxnormalize -x -e -s | hxselect -i -c h1)
	BOOK_DESCRIPTION=$(get_meta_property $PAGE_HTML "og:description")
	BOOK_AUTHOR=$(cat $PAGE_HTML | hxnormalize -x -e -s | hxselect -i -c .single-header__title .bookcard_author a)
	FILENAME=$(echo "$URL" | sed "s/https:\/\/bookuruk.com\/book\///").fb2

	FILENAME="$BOOKS_DIR/$FILENAME"
	echo "Book will be saved to $FILENAME" 

	echo "Author: $BOOK_AUTHOR"
	echo "Title: $BOOK_TITLE"
	echo "Description: $BOOK_DESCRIPTION"

	# Get chapters page.
	get_html_page "https://bookuruk.com$CHAPTERS_LINK" $PAGE_HTML

	CHAPTERS=($(cat $PAGE_HTML | hxnormalize -x -e -d -s | hxselect -i a.read-chapters-item | hxwls))
	# CHAPTERS_NAMES=
	readarray -t CHAPTERS_NAMES < <(cat $PAGE_HTML | hxnormalize -x | hxselect -i a.read-chapters-item | sed 's/ class="[^"]*"//g' | tr -d '\n' | sed -e ':a;N;$!ba;s/\n//g' | hxpipe | awk -F "-" '{print $2}' | grep "\S" )
	CHAPTER_NUM=0

	# Start creating a book
	book_header
	book_description "$BOOK_TITLE" "$BOOK_AUTHOR" "$BOOK_GENRE" "$BOOK_DESCRIPTION"

	echo "Processing ${#CHAPTERS[@]} chapters."
	for chapter in "${CHAPTERS[@]}";
	do
		echo "Process chapter: $CHAPTER_NUM - ${CHAPTERS_NAMES[$CHAPTER_NUM]}" 
		# Write section start.
		book_text "<section><title><p>${CHAPTERS_NAMES[$CHAPTER_NUM]}</p></title>"

		# Write data text.
		get_html_page "https://bookuruk.com$chapter" $PAGE_HTML
		cat $PAGE_HTML | hxnormalize -x -e -s | hxselect -i .read-area | grep -oE "decodeBase64\(['\"][^'\"]*['\"]\)" | sed -E "s/decodeBase64\(['\"]//g; s/['\"]\)\$//g" | base64 -d > $PAGE_HTML2
		book_text "$(cat $PAGE_HTML2)"

		# Write section end.
		CHAPTER_NUM=$((CHAPTER_NUM+1))
		book_text "</section>"
	done

	book_footer
}
