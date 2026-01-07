🇬🇧 English | 🇮🇹 Italiano (README.it.md)

# A1-Text

A1-Text is an experimental text editor written in Ruby and GTK4, inspired by C1-Text for Amiga.

It is designed to make typing as fluid and natural as possible by acting **in real time**
on punctuation, capitalization, and text flow, instead of applying corrections afterwards.

![Intelligent punctuation demo](media/punctuation.gif)

## Project philosophy

Most modern word processors apply static rules
to punctuation and typing.

A1-Text takes a different approach:
it intercepts key events and context while typing,
adapting text behavior to the natural flow of language.

It is not intended for layout or formatting,
but for narrative and fluid writing.

## Main features

### Writing and typing
- Context-aware automatic punctuation
- Intelligent capitalization
- Dialogue handling with typographic quotation marks
- Visible line break symbols

### Writing assistance
- Automatic word substitutions
- Word completion
- Grammar checking (LanguageTool)

### System
- Load and save plain text files (.txt)
- Autosave every 5 minutes
- Font selection
- Keypress sounds

### Optional features
- AI-based text improvement features (can be disabled)

## Distinctive behavior

### Intelligent punctuation

- A space is automatically inserted after punctuation marks
- After a period (`.`), the following word is automatically capitalized
- If `Enter` is pressed after a period or a closing quotation mark (`»`),
  the automatically inserted space is removed

This behavior is designed to make writing dialogues
and narrative text easier without interrupting the writing flow.

### Visualization
Line breaks (Enter key presses) are displayed using a symbol.

### Word completion
To complete a word, scroll through the popover suggestions using the arrow keys
and press `TAB` or click with the mouse to accept.
The popover automatically disappears after 6 seconds or when pressing `ESC`.

### Substitutions
Words are replaced when the space key is pressed.
The substitution table is stored in the `replacement.txt` file.
New entries can be added using the following format:

```
word_to_replace <space> replacement
```

## Dependencies

### Required software
- Ruby 3.4
- GTK4
- LanguageTool
- Java (required to run the LanguageTool server)

### Ruby gems
- `gtk4`
- `thread`
- `net/http`
- `json`
- `open3`
- `httpx`
- `yaml`
- `gosu`

### AI features API
To enable AI features, an API key must be obtained for free from https://groq.com/ and added to the `config.yml` file together with the desired model (default: `llama-3.3-70b-versatile`).

## Installation

### Installing gems locally with Bundler

Add the following lines to your `.bashrc`:

```bash
export GEM_HOME="$HOME/.gem"
export GEM_PATH="$GEM_HOME:/path/to/system/gems"
export PATH="$HOME/.gem/bin:$PATH"
```

From a terminal, in the same directory as the program and the `Gemfile`, run:

```bash
bundle install
```

### Fonts

Copy the included fonts into the `~/.fonts` directory.

### LanguageTool configuration

The program searches for LanguageTool in `/usr/share/languagetool` and sets the language to `en-US`. If the installation path in your distribution is different and/or you want a different language, edit the relevant entries in the `config.yml` file. If necessary, you can also change the server port number.

## Configuration

### Block cursor in insert mode

To enable a block cursor in insert mode,
add or modify the following line in `settings.ini`
located in `~/.config/gtk-4.0`:

```ini
gtk-cursor-aspect-ratio=0.5
```

The value 0.5 controls the cursor thickness.

### Font rendering improvements

Add the following settings (if not already present) to improve font rendering:

```ini
gtk-hint-font-metrics=1
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
```
### Wayland and dead keys

On Wayland, if you are using a keyboard layout with dead keys (e.g. US International) and they do not work correctly, try installing ibus.

## Project structure

The repository contains:

- **Included fonts**: IBMPlexMono-Regular, JetBrainsMono-Regular, Prototype, Topaz_a1200_v1.0
- **AI configuration files**: `robot.txt` and `ai.txt` for AI bot control
- **Substitution table**: `replacement.txt` for automatic word substitutions
- **Configuration**: `config.yml` for application settings
- **Audio files**: `click.wav` and `click2.wav`

## License

This software is released under a **custom source-available license** (**LicenseRef-blastbeat-NC-NoAI-CodebergRef-2025**).

**This project is NOT Open Source according to the Open Source Initiative (OSI) definition.**

Main license characteristics:

- **Non-commercial use only**
- **No AI / Machine Learning usage**
- **Codeberg as the reference platform**

Copyright © 2025 blastbeat

For full and legally binding terms, see:

- `LICENSE`
- `LICENSE.spdx`

## Design notes

Design decisions and rationale are documented in [`DESIGN.md`](DESIGN.md).

## Project status

A1-Text is a personal side project developed in spare time.

Updates may be irregular, and there is no public roadmap.
Bug reports and feedback are welcome, but without expectations regarding timelines or support.

