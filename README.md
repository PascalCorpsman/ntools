# ntools – npush & npoll

Send files and folders between two computers in the same LAN – without a shared folder, without setup, without a server.

- **npoll** runs on the receiver, in the folder where the files should go.
- **npush** runs on the sender, with the files to send as parameters.

Both find each other automatically, transfer the files and close when everything is done.

```text
Receiver                              Sender
C:\Downloads> npoll                   C:\Projects> npush report.pdf images
npoll ver. 0.10 by Corpsman           npush ver. 0.10 by Corpsman
Info  : waiting for connections...    Info  : scanning for connections...
Info  : Receive files from : 10.0.0.5 Info  : Send files to : 10.0.0.7
Info  : report.pdf                    Info  : report.pdf
Info  : \images\holiday.jpg           Info  : \images\holiday.jpg
  100,0%  476,8 MB / 476,8 MB  ...      100,0%  476,8 MB / 476,8 MB  ...
Info  : Done: 2 file(s) received ...  Info  : Done: 2 file(s) sent ...
```

## Contents

- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [npush – sender](#npush--sender)
- [npoll – receiver](#npoll--receiver)
- [Exit codes](#exit-codes)
- [Examples](#examples)
- [Firewall](#firewall)
- [Security](#security)
- [Building from source](#building-from-source)
- [Integration into the file manager](#integration-into-the-file-manager)
- [License](#license)

## How it works

1. **npoll** listens on UDP port 8002.
2. **npush** opens TCP port 8002 and sends a UDP broadcast "Hello" on every network adapter (and to itself, in case npoll runs on the same machine).
3. npoll answers by opening a TCP connection to the sender.
4. For every file npush sends a header (name, size, optional MD5). npoll decides: transfer, skip (already there / `-n`) or resume (`-a`).
5. When all files are done, npush sends an end mark and both programs close.

The order in which you start the two programs does not matter, npush keeps searching until it finds an npoll (or `-t` runs out).

## Quick start

On the **receiver**, open a terminal in the target folder:

```sh
npoll
```

On the **sender**, open a terminal in the folder with the files:

```sh
npush myfile.zip
```

While a transfer is running, the progress of the current file is shown automatically. Press `ESC` to abort, `i` to print the progress on demand (also with `-q`).

## npush – sender

```text
npush [options] [files / folders / masks]
```

| Call | What is sent |
| --- | --- |
| `npush` | nothing, only a connection test (ping) |
| `npush <file> [<file> ...]` | the given files |
| `npush <folder>` | the folder with all files and subfolders |
| `npush *.*` | all files in the current folder |
| `npush *.<ext>` | all files of a type, e.g. `npush *.pdf` |
| `npush "*.<ext>;*.<ext>"` | several types, e.g. `npush "*.jpg;*.png"` |
| `npush *` | all files and subfolders of the current folder |
| `npush -c` | open a chat with npoll instead of sending files |

If a given file or folder does not exist, npush stops immediately with an error (exit code 2).

On Linux and macOS the shell expands `*` itself, quote it (`npush "*.pdf"`) if npush should do it.

| Option | Description |
| --- | --- |
| `-md5` | Send the MD5 checksum. npoll skips files that already exist with the same content and **verifies every received file**. A file with a wrong checksum is deleted and reported as error. |
| `-a` | Append: if the file already exists on the receiver and is smaller, only the missing rest is sent (resume an aborted transfer). Combine with `-md5` to make sure the result is correct. |
| `-m <n>` | Serve `<n>` npoll one after another, `0` = until `ESC`. Every connection counts, also a second one of the same npoll (e.g. `npoll -s`) and an aborted one. If several npoll connect at the same time, they wait in a queue. |
| `-t <sec>` | Give up if no npoll is found within `<sec>` seconds (exit code 3). |
| `-q` | Do not show the progress automatically. |
| `-i <ip>` | Send the "Hello" only to this address instead of broadcasting, e.g. a single PC or a broadcast address of another subnet. |
| `-p <port>` | Use another port than 8002 (npoll needs the same `-p`). |
| `-l <0..6>` | Log level, 0 = everything, 6 = only fatal errors. |
| `-h` | Show the online help. |

## npoll – receiver

```text
npoll [options]
```

npoll stores the received files (including subfolders) in the **current folder**. File names that point outside of it (e.g. `..\..\file`) are rejected.

| Option | Description |
| --- | --- |
| `-s` | Stay open: after a transfer wait for the next npush (end with `ESC`). |
| `-n` | Do not overwrite existing files, skip them. |
| `-t <sec>` | Give up if no npush is found within `<sec>` seconds (exit code 3). |
| `-q` | Do not show the progress automatically. |
| `-i <ip>` | Do not wait for the UDP broadcast, connect directly to the npush at `<ip>`. Useful if broadcasts are blocked or npush runs in another subnet. |
| `-p <port>` | Use another port than 8002 (npush needs the same `-p`). |
| `-l <0..6>` | Log level, 0 = everything, 6 = only fatal errors, default 4. |
| `-h` | Show the online help. |

What happens with a file that already exists on the receiver:

| Options | Same content | Same size, other content | Smaller (e.g. aborted) | Larger |
| --- | --- | --- | --- | --- |
| (none) | overwritten | overwritten | overwritten | overwritten |
| `-md5` | skipped | overwritten | overwritten | overwritten |
| `-a` | skipped | **skipped** | missing rest appended | overwritten |
| `-md5 -a` | skipped | overwritten | missing rest appended, then verified | overwritten |
| npoll `-n` | skipped | skipped | skipped | skipped |

`-a` alone only compares the size. If the file on the receiver may have changed, use `-md5 -a`: a wrong result is detected, deleted and sent completely the next time.

## Exit codes

Both programs return an exit code, so they can be used in scripts:

| Code | Meaning |
| --- | --- |
| 0 | Everything done |
| 1 | Aborted by the user (`ESC`) |
| 2 | Error, e.g. file not found, connection lost, MD5 mismatch, file rejected |
| 3 | No partner found within the timeout (`-t`) |

## Examples

Send a folder and resume it later if the connection breaks:

```sh
npush -md5 -a D:\Photos\2026
```

Distribute an installer to three PCs, each runs `npoll` in its download folder:

```sh
npush -m 3 setup.exe
```

Keep a receiver open the whole day, but never overwrite anything:

```sh
npoll -s -n
```

Use in a script (Windows batch):

```bat
npush -t 30 -q -md5 backup.7z
if errorlevel 3 echo No receiver found & exit /b 3
if errorlevel 1 echo Transfer failed & exit /b 1
```

## Firewall

| Program | Needs incoming |
| --- | --- |
| npoll (receiver) | UDP 8002 |
| npush (sender) | TCP 8002 |

On Windows the firewall asks at the first start, allow the access for the private network. With `-i` on npoll no UDP is needed, only TCP 8002 on the sender.

## Security

ntools are made for comfort in a trusted LAN, not for security:

- There is **no authentication**. When npush searches for an npoll, the first npoll that answers gets the data. A connection can be hijacked during the startup.
- The transfer is **not encrypted**, it is as secure as plain TCP/IP.
- npoll accepts files from any npush that it finds. It only writes into the current folder (names with `..` or absolute paths are rejected), but it overwrites existing files unless `-n` or `-md5` is used.

Do not use ntools in untrusted networks.

## Building from source

Requirements:

- [Lazarus](https://www.lazarus-ide.org/) (tested with Lazarus 4.8 / FPC 3.2.2 on Windows; Linux and macOS work as well)
- the **L-Net** package (`lnetbase`), from the Lazarus Online Package Manager or from <https://github.com/almindor/lnet>

### With the Lazarus IDE

1. Install L-Net: *Package → Online Package Manager → lNet → Install*, or open `lazaruspackage/lnetbase.lpk` from the L-Net sources and click *Compile*.
2. Open `npoll/npoll.lpi`, *Run → Build*.
3. Open `npush/npush.lpi`, *Run → Build*.

### On the command line

```sh
# only once: make the L-Net package known to Lazarus
lazbuild --add-package /path/to/lnet/lazaruspackage/lnetbase.lpk

lazbuild npoll/npoll.lpi
lazbuild npush/npush.lpi
```

The programs are created as `npoll/npoll(.exe)` and `npush/npush(.exe)`. Copy them into a folder that is in your `PATH`.

### Project layout

| Path | Content |
| --- | --- |
| `ntools.inc` | version, port, buffer size and exit codes for both programs, history |
| `npush/unpush.pas` | sender logic (`TNPush`) |
| `npush/uip.pas` | network adapters and broadcast addresses (`ipconfig` / `ifconfig`) |
| `npoll/unpoll.pas` | receiver logic (`TNPoll`) |
| `*/ulogger.pas` | logger |
| `send_to_npush`, `install.txt` | file manager integration (see below) |

## Integration into the file manager

The most comfortable way: send files with a right click, start npoll with a right click into a folder. `install.txt` contains the original notes in German.

### Windows

**npush in "Send to":** press `Win + R`, enter `shell:sendto` and create a shortcut to `npush.exe` in this folder. Now *right click → Send to → npush* sends the selected files.

**npoll in the folder background menu:** with `regedit` create the key

```text
HKEY_CLASSES_ROOT\Directory\Background\shell\npoll\command
```

and set its default value to the full path of `npoll.exe`, e.g. `"C:\Tools\npoll.exe"`. Now *right click into a folder → npoll* receives files into this folder.

### Linux (MATE / Caja)

**npush:** copy `send_to_npush` to `~/.config/caja/scripts/`, make it executable and adjust the paths in it. Now *right click → Scripts → send_to_npush* sends the selected files.

**npoll:** add the folder of `npoll` to your `PATH` (e.g. in `~/.bashrc`) and start `npoll` in a terminal in the target folder.

## Binary download

If you do not want to build the programs yourself (may be an older version than this repository):

<https://www.corpsman.de/klickcounter.php?url=download/ntools.zip>

## License

See [license.md](license.md): Postcardware or modified LGPL, as you like.
