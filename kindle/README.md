# Ukrainian books: KOReader plugin

Browse, search and download books on the Kindle as FB2, from:

- **readukrainianbooks.com**: free, no login.
- **booknet.ua**: browsing is public, but downloading (even free books) needs your login cookie (see below).

Downloaded books open directly in KOReader.

## Install

1. Connect the Kindle over USB.
2. Copy the `ukrbooks.koplugin` folder to `koreader/plugins/` on the Kindle
   (so you end up with `/mnt/us/koreader/plugins/ukrbooks.koplugin/main.lua`).
3. For booknet: copy `identity.txt` (and `csrf.txt`, if you have it), the same files the
   bash script uses, into that folder.
4. Restart KOReader.
5. Open it from **File browser → top menu → 🔍 (Search) → Ukrainian books**.

When you update the plugin by copying the folder again, keep `identity.txt` / `csrf.txt` in it.

## Usage

The first screen lists the sites, then **Downloaded** and **Download folder**. Each site has:

- **Search…**: title or author (at least 2 characters).
- **New books** / **Categories**: listings load as you page forward.
- Tap a book to see its annotation, then **Download**, **Read** or **By this author**
  (readukrainianbooks only).

Booknet adds two entries to its menu:

- **Listings: free books only / all books**: free only by default. Search results have no price,
  so they're never filtered; the book screen shows the price.
- **Login: identity.txt found / not found**: whether downloads are possible. The files are read
  every time the window opens, so no restart is needed after copying them.

**Downloaded** lists books downloaded before. Long-press an entry to remove it from the list.
**Download folder** defaults to `/mnt/us/books`.

### readukrainianbooks.com

1. If the site offers a ready FB2 file (newer "Блог" books), that file is used as-is
   (the author is filled in if the file leaves it empty).
2. Otherwise the book's pages are downloaded one by one and converted to FB2:
   chapter titles become sections, and the cover and annotation are included.

### booknet.ua

Same protocol as `providers/booknet.ua` in the bash version:

1. The reader page is opened with your cookies to get a CSRF token.
2. The last chapter is requested once: if it isn't available, the book isn't readable with
   your account (paid, not bought) and nothing is downloaded.
3. Chapters are downloaded page by page, 1 second apart. Each chapter becomes an FB2 section
   with the chapter name as title. Images in the text and the cover are embedded.
4. **If the site refuses a request** (the token expired), the plugin **waits 2 minutes**
   (countdown on screen), reloads the reader page for a fresh token, and **retries that page
   once**. If it fails again, it stops and saves what it has as `<name>-incomplete.fb2`, with a
   note at the end of the book. An incomplete download never replaces a complete copy.
5. Between two book downloads there's a **60-second pause** (as in `book.sh`).

If booknet answers "Доступ обмежено" (access restricted), `identity.txt` has expired: copy a
fresh `_identity` cookie value from your browser into it.

Tap the progress message to cancel. For booknet, a cancelled download keeps the chapters
already downloaded (saved as incomplete).

Settings and history are stored in `koreader/settings/ukrbooks.lua`.
