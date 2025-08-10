#!/bin/bash

# Get host from URL.
# $1 - URL
get_host() {
	echo $1 |
	awk -F[/:] '{print $4}'
}

# Get META content attr by property attr.
# $1 - filename with html
# $2 - meta property
get_meta_property()
{
	grep -r ".*<meta property=\"$2\" content=\"\(.*\)\"" $1 |
	sed -e "s/.* content=\"\(.*\)\".*/\1/"
}

# Get META content attr by name attr.
# $1 - filename with html
# $2 - meta name
get_meta_name()
{
	grep -r ".*<meta name=\"$2\" content=\"\(.*\)\"" $1 |
	sed -e "s/.* content=\"\(.*\)\".*/\1/"
}

# Simple solution to get json value by key.
# $1 - path to json file
# $2 - property to read
# $3 - additional sub property
get_json_val()
{
	if [ ! -z $3 ]; then
		VAL=$(cat $1 | \
		php -r "echo json_decode(file_get_contents('php://stdin'), true)['$2']['$3'] ?? '';")
	else
		VAL=$(cat $1 | \
		php -r "echo json_decode(file_get_contents('php://stdin'), true)['$2'] ?? '';")
	fi

	echo $VAL
}

# Download html.
# $1 - URL
# $2 - File to save
get_html_page()
{
	curl $1 \
	-H 'accept: application/json, text/javascript, */*; q=0.01' \
	-H 'accept-language: en-US,en;q=0.9' \
	-H 'cache-control: no-cache' \
	-o "$2" \
	--silent
}
