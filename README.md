# Books downloader

This repository provides simple scripts to download and convert online books into FB2 format.

Supported websites:

- readukrainianbooks.com
- booknet.ua

## How to use script for readukrainianbooks.com
````
./readukrainianbooks_com.sh https://readukrainianbooks.com/6340-faktor-cherchillja-jak-odna-ljudina-zminila-istoriju-boris-dzhonson.html
````

## How to use script for booknet.ua

For booknet.ua to download books you've bought identity cookie should be paste in indentity.txt file.
Check "_identity" cookie when you're logged in.

In the latest update of the script images support were added. I've noticed that books from this website can have images when I was reading this cool sci-fi book https://booknet.ua/book/ekstremofl-b419491 . So for me it was a challenge to pack all images into FB2 format with bash only.

Params:
-  --identity - Using identity.txt file where you should place value from _identity cookie when you're logged in."
-  --incomplete - Download book even if it's not full (non-free)"

````
./booknet_ua.sh https://booknet.ua/reader/mainpage-1234566
````
````
./booknet_ua.sh https://booknet.ua/reader/mainpage-1234566 --incomplete
````
````
./booknet_ua.sh https://booknet.ua/reader/mainpage-1234566 --identity
````

### P.S. Support authors - buy their books!
