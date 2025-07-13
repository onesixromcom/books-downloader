#!/bin/bash

get_book_text()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i div#texts |
	sed -e 's/<div.*>//g' -e 's/<\/div>//g' |
	sed -e ':a;N;$!ba;s/\n//g' |
	sed -e $'s/                  / /g'
}

get_book_text_online()
{
	echo $1 |
	wget -O- -i- --no-verbose --quiet | 
	hxnormalize -x -e -s |
	hxselect -i div#texts |
	sed -e 's/<div.*>//g' -e 's/<\/div>//g' |
	sed -e ':a;N;$!ba;s/\n//g' |
	sed -e $'s/                  / /g'
}

get_book_title()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i h1.short-title |
	sed -e 's/<[^>]*>//g' |
	sed -e 's/Читати книгу - //g' | 
	sed -e 's/"//g' |
	sed -e ':a;N;$!ba;s/\n//g' |
	sed -e $'s/                  / /g'
}

get_book_description()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i div.shortstory-text |
	sed -e 's/<[^>]*>//g' |
	sed -e ':a;N;$!ba;s/\n//g' |
	sed -e $'s/                  / /g'
}

get_book_author()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i span.fa.fa-pencil+a |
	sed -e 's/<[^>]*>//g' -e 's/\r//'
}

get_book_genre()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i span.fa.fa-book+a |
	sed -e 's/<[^>]*>//g' |
	sed -e ':a;N;$!ba;s/\n//g' |
	sed -e $'s/                  / /g'
}

get_book_image_url()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i ".fimg.img-wide img" |
	sed -e "s/.* data-src=\"\(.*\)\".*/\1/"
}

get_pages_list()
{
	cat $1 |
	hxnormalize -x -e -s |
	hxselect -i div.storenumber.ftext div.to-page | 
	sed 's/<option/<a/g' | #replacements to make hxwls work
	sed 's/option>/a>/g' | #replacements to make hxwls work
	sed 's/value=/href=/g' |  #replacements to make hxwls work
	hxwls
}

write_fb2_header()
{
	if [ -f "$FILENAME" ]; then	rm "$FILENAME"; fi
	touch "$FILENAME";
	echo '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">' > "$FILENAME";
}

write_fb2_footer()
{
	echo '</section></body>' >> "$FILENAME";
	if [ ! -z "$IMG" ]; then
		IMG="https://readukrainianbooks.com$IMG"
		echo '<binary id="cover.jpg" content-type="image/jpeg">' >> "$FILENAME";
		wget -O "$IMAGES_DIR/cover.jpg" --no-verbose --quiet $IMG
		base64 "$IMAGES_DIR/cover.jpg" >> "$FILENAME";
		echo '</binary>' >> "$FILENAME";
	fi 

	echo '</FictionBook>' >> "$FILENAME";
}

write_fb2_description()
{
	echo '<description><title-info>' >> "$FILENAME";
	echo "<book-title>$1</book-title>"  >> "$FILENAME";
	echo "<genre>$3</genre>" >> "$FILENAME";
	echo "<author><first-name>$2</first-name><middle-name></middle-name><last-name></last-name></author>" >> "$FILENAME";
	echo '<from>Downloaded from readukrainianbooks.com. Converted by 16rom.com</from>' >> "$FILENAME";
	echo "<annotation><p>$4</p></annotation>"  >> "$FILENAME";
	if [ ! -z "$IMG" ]; then
		echo '<coverpage><image l:href="#cover.jpg"></image></coverpage>' >> "$FILENAME";
	fi
	echo '<lang>ua</lang></title-info></description><body xmlns:fb="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:xlink="http://www.w3.org/1999/xlink"><section>' >> "$FILENAME";
}

write_fb2_text()
{
	echo "$1" >> "$FILENAME";
}

#================== START ==================
process_book()
{
FILENAME=$(echo "$URL" | sed "s/https:\/\/readukrainianbooks.com\///" | sed 's/.html.*//' | sed -e 's/^[0-9]\+-*//g').fb2
PAGE_HTML="$FILES_DIR/readukrainianbooks_page1.html"
	
# Download and save file to process
wget -O "$PAGE_HTML" --no-verbose --quiet $URL

FILENAME="$BOOKS_DIR/$FILENAME"
echo "Book will be saved to $FILENAME"

IMG=$(get_book_image_url $PAGE_HTML)

PAGES_URLS=($(get_pages_list $PAGE_HTML))
if [ -z "$PAGES_URLS" ]; then
	echo "No pages were found! exit";
	exit;
fi

BOOK_TITLE=$(get_book_title $PAGE_HTML)
BOOK_AUTHOR=$(get_book_author $PAGE_HTML)
BOOK_GENRE=$(get_book_genre $PAGE_HTML)
BOOK_DESCRIPTION=$(get_book_description $PAGE_HTML)


write_fb2_header
write_fb2_description "$BOOK_TITLE" "$BOOK_AUTHOR" "$BOOK_GENRE" "$BOOK_DESCRIPTION"

echo "Processing ${#PAGES_URLS[@]} pages."
for page_url in "${PAGES_URLS[@]}";
do
	echo "Process: $page_url"
	BOOK_TEXT=$(get_book_text_online $page_url)
	write_fb2_text "$BOOK_TEXT"
done

write_fb2_footer

}
