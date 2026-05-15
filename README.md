# FloatNote

FloatNote is a small native macOS floating sticker app built with Swift and AppKit.

## Features

- Floating always-on-top stickers
- Top-right quick create and hide controls
- Persisted sticker text, position, size, and zoom
- Clipboard text as the default content for new stickers
- Markdown-style list editing with Display/Edit mode and block-based table preview
- Resizable stickers with adaptive text scaling

## Build

```sh
./build.sh
```

The build script creates:

```text
FloatNote.app
```

## Install Locally

```sh
ditto FloatNote.app ~/Applications/FloatNote.app
open ~/Applications/FloatNote.app
```

Sticker data is stored under:

```text
~/Library/Application Support/FloatingSticker/stickers.json
```
