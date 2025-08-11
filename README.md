# Books downloader

This repository provides simple scripts to download and convert online books into FB2 format.

Supported websites:

- readukrainianbooks.com
- booknet.ua
- uabooks.net
- bookuruk.com

## How to use script for readukrainianbooks.com
````
./book.sh https://readukrainianbooks.com/6340-faktor-cherchillja-jak-odna-ljudina-zminila-istoriju-boris-dzhonson.html
````

## How to use script for booknet.ua

For booknet.ua to download books you've bought identity and csrf cookies should be paste in indentity.txt and csrf.txt files.
Check "_identity" and "_csrf" cookies when you're logged in.
Identity file will bo loaded automatically.

In the latest update of the script images support were added. I've noticed that books from this website can have images when I was reading this cool sci-fi book https://booknet.ua/book/ekstremofl-b419491 . So for me it was a challenge to pack all images into FB2 format with bash only.

````
./book.sh https://booknet.ua/reader/mainpage-1234566
````

## How to use script for bookuruk.com

````
./book.sh https://bookuruk.com/book/vidma-filosofskih-nauk
````

### P.S. Support authors - buy their books!
