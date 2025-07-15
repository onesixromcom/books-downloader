#!/bin/bash

# Add header.
book_header()
{
if [ $PACKER == "FB2" ]; then
	if [ -f "$FILENAME" ]; then rm "$FILENAME"; fi
	touch "$FILENAME";
	echo '<?xml version="1.0" encoding="utf-8"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">' > "$FILENAME";
fi
}

# Add description to the book.
# $1 - title
# $2 - author
# $3 - genre
# $4 - description
book_description()
{
if [ $PACKER == "FB2" ]; then
	echo '<description><title-info>' >> "$FILENAME";
	echo "<book-title>$1</book-title>"  >> "$FILENAME";
	echo "<genre>$3</genre>" >> "$FILENAME";
	echo "<author><first-name>$2</first-name><middle-name></middle-name><last-name></last-name></author>" >> "$FILENAME";
	echo '<from>Downloaded from booknet.ua. Converted by 16rom.com</from>' >> "$FILENAME";
	echo "<annotation><p>$4</p></annotation>"  >> "$FILENAME";
	if [ ! -z "$IMAGE_COVER_URL" ]; then
		echo '<coverpage><image l:href="#cover.jpg"></image></coverpage>' >> "$FILENAME";
	fi
	echo '<lang>ua</lang></title-info></description><body>' >> "$FILENAME";
fi
}

# Write book text.
book_text()
{
if [ $PACKER == "FB2" ]; then
	# Remove all divs, h1, em
	PAGE_TEXT=$( echo $1 | \
	sed 's/<div[^>]*>//g; s/<\/div>//g' | \
	sed 's/<h1[^>]*>//g; s/<\/h1>//g'| \
	sed 's/<br[^>]*>//g' | \
	sed 's/<em[^>]*>//g; s/<\/em>//g' | \
	sed 's/<a[^>]*>//g; s/<\/a>//g' | \
	sed '/<script\b/,/<\/script>/d'
	)

	book_process_images

	echo "$PAGE_TEXT" >> "$FILENAME"
fi
}

book_footer()
{
if [ $PACKER == "FB2" ]; then
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
		echo "Downloading image $image"
		FNAME=$(basename $image)
		FNAME_JPEG="${FNAME%.*}.jpg"
		wget -O $IMAGES_DIR/$FNAME --no-verbose --quiet $image

		if [ -s $IMAGES_DIR/$FNAME ]; then
			# Converting images to JPG format.
			convert -quality 50 $IMAGES_DIR/$FNAME $IMAGES_DIR/$FNAME_JPEG

			# Check if image is correct.
			if [[ $(file -b $IMAGES_DIR/$FNAME_JPEG) =~ JPEG ]]; then
				echo "<binary id=\"$FNAME_JPEG\" content-type=\"image/jpeg\">" >> "$FILENAME";
				base64 $IMAGES_DIR/$FNAME_JPEG >> "$FILENAME";
				echo '</binary>' >> "$FILENAME";
			fi
		else
			# Add a dummy image.
			echo "<binary id=\"$FNAME_JPEG\" content-type=\"image/jpeg\">" >> "$FILENAME";
			base64 dummy.jpg >> "$FILENAME";
			echo '</binary>' >> "$FILENAME";
		fi
	done

	echo '</FictionBook>' >> "$FILENAME";
fi
}

book_process_images()
{
	PAGE_TEXT=$(echo "$PAGE_TEXT" | sed -e 's|&amp;|\&|g')

	IMAGES_TMP=($(echo "$PAGE_TEXT" |
		hxnormalize -x -e -s |
		hxselect -i img |
		hxwls
	))
	# TODO: check filesize before processing
	for image in "${IMAGES_TMP[@]}";
	do
		if [ ! -z "$image" ]; then
			if [ -z "$(echo $image | grep facebook)" ]; then
				echo "++ Image found: $IMAGES_DOMAIN$image"
				IMAGES_URLS+=("$IMAGES_DOMAIN$image")
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

	PAGE_TEXT=$( echo "$PAGE_TEXT" | sed -e "s|src=|l:href=|g" )
	PAGE_TEXT=$( echo "$PAGE_TEXT" | sed 's/<img\([^>]*[^/[:space:]]\)[[:space:]]*>/<image\1 \/>/g' )
	PAGE_TEXT=$( echo "$PAGE_TEXT" | sed -e "s|img|image|g" )
}
