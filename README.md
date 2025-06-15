# mdexsync

**MangaDex download and synchronization tool.**

mdexsync is a program to download releases from [MangaDex][mangadex]. It will
create a directory with the title of the manga in the specified download folder.
Then it will create a subdirectory for each chapter containing the page images.

This software is licensed under the [Apache License, Version 2.0][license].

[mangadex]: https://mangadex.org/
[license]: LICENSE.txt

## Features

There are many other (better, more advanced) download tools out there for
MangaDex. However they are generally designed to have helpful user interfaces
and only run in interactive mode. I wanted a super-simple synchronization
program that I can run from scripts automatically (e.g. a script called by a
systemd timer or cron job). This program is designed to be simple, only command
line interface, and easy to invoke from other scripts.

 * Pure CLI.
 * Non-interactive operation.
 * Designed for automation.
 * Minimal dependencies.
 * Uses the official [public API][apidocs].
 * Attempts to stay within rate limits.
 * Persistent manga titles between runs.
 * Does not re-download content you have already synced.
 * Creates a directory structure that sorts reliably.
 * Gracefully handles multiple versions of chapters
 * Will not pollute folders with partial or failed downloads.
 * Includes some basic retry logic to handle a transitory connection failures.

[apidocs]: https://api.mangadex.org/docs/

## Installation

This program is written in bash and designed for use on GNU/Linux systems.

### Install from tarball

Download the latest version of the script from the [releases page][releases] on
GitHub. Extract the contents to some temporary directory. Then run the following
command to install the program:

```shell
sudo make install
```

To uninstall the program you can run the following command in the same folder:

```shell
sudo make uninstall
```

[releases]: https://github.com/stevenbenner/mdexsync/releases

### Dependencies

This script depends on the following programs:

 * [curl][curl]: (required) For HTTP communication
 * [jq][jq]:     (required) For JSON data processing
 * [diff][diff]: (required) For chapter version deduplication
 * [bc][bc]:     (required) For retry timing math

[curl]: https://curl.se/
[jq]: https://jqlang.github.io/jq/
[diff]: https://www.gnu.org/software/diffutils/
[bc]: https://www.gnu.org/software/bc/

## Usage

You will need the ID of the manga that you wish to download. You can find the ID
in the URL used for the work on mangadex.org. It will be a hexadecimal GUID in
the format '88888888-8888-8888-8888-888888888888'.

### Examples

Download first 5 chapters of Yotsuba&! to the `~/Downloads` folder:

 * `mdexsync -p ~/Downloads -i 58be6aa6-06cb-4ca5-bd20-f1392ce451fb -m 5`

### Options

| Option   | Description                                                   |
| :------- | :------------------------------------------------------------ |
| `-p DIR` | Path to directory where downloaded content should be saved.   |
| `-i ID`  | ID of the work to download.                                   |
| `-m NUM` | Maximum number of chapters to download. Unlimited if omitted. |
| `-v`     | Print verbose output.                                         |
| `-h`     | Print usage info and quit.                                    |

## Directory structure

This script creates a deterministic folder structure to uniquely identify every
download and ensure consistent sort order.

 * The top-level folder will be the name of the work.
 * The chapter subdirectory names will include a chapter number, with decimal,
   release version number, associated scanlation group(s), and title (if set).
    - Chapter number will be padded with zeros to always be at least 3 digits.
    - The decimal will always be present, even if it is not published as a
      fractional chapter. The decimal will be 0 in those cases (e.g. "c001.0").
      This is to guarantee sort order in readers. Decimals can be more than one
      digit long (e.g "c040.51").
    - The version number is the version of that particular release. This number
      is incremented when the owner changes something. Including it in the
      folder name ensures that new updates get downloaded.
    - Some chapters do not have associated groups. Those will instead be tagged
      with the username of the user who upload it.
    - There can be multiple groups associated with a release. In those cases the
      groups are concatenated with an ampersand. For example:
      "[Group A & Group B]"
    - The title is often not known/set on chapters. So in those cases it will be
      omitted from the directory name.
 * The individual page file names will be padded with zeros to be at least a
   3-digit number.

### Path text filters

In addition to the directory naming conventions outlined above, the following
text filters are applied in all cases:

 * Slashes are replaced with a unicode "big solidus" character (`⧸`) to preserve
   the text and be compatible with file system naming restrictions.
 * Leading and trailing whitespace characters are removed.
 * Leading dots are removed from directory names.

### Example directory tree
```
Yotsuba&!
├── c001.0v2 [Momotato] Yotsuba & Moving
│   ├── 001.jpg
│   ├── 002.jpg
│   ├── 003.jpg
│   └── ...n
├── c002.0v2 [Momotato] Yotsuba & Manners
│   ├── 001.jpg
│   ├── 002.jpg
│   ├── 003.jpg
│   └── ...n
├── c003.0v2 [Momotato] Yotsuba & Global Warming
│   ├── 001.jpg
│   ├── 002.jpg
│   ├── 003.jpg
│   └── ...n
└── ...n
```

## Persistent titles

The title of a work shown on MangaDex sometimes changes as better or more
official titles come out. For a tool like this, we want the manga title to be
consistent between runs to avoid creating new folders and re-downloading content
when a name is changed. The mdexsync script will save the title associated with
a manga ID to a persistent cache file the first time it successfully fetches it.

This file is stored in the [XDG][xdgspec] cache folder at this location:

 * `$XDG_CACHE_HOME/mdexsync/manga_index`

The XDG cache folder is typically located at `~/.cache`.

[xdgspec]: https://specifications.freedesktop.org/basedir-spec/latest/

### Changing the title of a downloaded work

If you would like to change the title of a manga that you have downloaded then
you will need to change the title in that file. Once you do that you can then
rename the downloaded folder to match.
