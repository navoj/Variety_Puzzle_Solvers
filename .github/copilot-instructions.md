# Copilot Instructions

## Project Overview

Variety Puzzle Solvers is a collection of Perl programs that solve variety puzzles (crosswords, sudoku, and potentially others). Each puzzle type lives in its own capitalized top-level directory (e.g., `Crossword/`, `Sudoku/`).

## Language & Toolchain

- **Language:** Perl (v5.38+)
- **Build toolchain:** The `.gitignore` is configured for standard Perl distribution tools (ExtUtils::MakeMaker, Module::Build, Dist::Zilla)
- **Code coverage:** Devel::Cover
- **Profiling:** Devel::NYTProf
- **No internet at runtime:** Solvers must work entirely offline. Any data files (dictionaries, word lists) should be bundled in the puzzle directory.

## Running a Solver

```bash
# Crossword solver
perl Crossword/solve.pl [options] <puzzle_file>
perl Crossword/solve.pl -v Crossword/examples/medium_5x5.txt

# Convert a WSJ PDF to ASCII grid (requires Python 3 + pymupdf)
python3 Crossword/pdf_to_grid.py "Crossword/WSJ Crosswords/XWD01032022.pdf"

# Batch convert all PDFs
python3 Crossword/pdf_to_grid.py -v -o output/ --batch "Crossword/WSJ Crosswords/"
```

## Architecture

Each puzzle type is a self-contained directory with:
- A `solve.pl` main solver script
- A `README.md` describing the input format and usage
- An `examples/` directory with test puzzles
- Any required data files (e.g., `dictionary.txt`)

When adding a new puzzle type, always capitalize the first letter of the directory name.

## Conventions

- Use `strict` and `warnings` pragmas in all Perl files
- Handle both Unix and Windows line endings (`\r\n`) in input file parsing
- Solvers accept puzzle files as command-line arguments
- Support `-v`/`--verbose` for detailed output and `-h`/`--help` for usage
- License: MIT

## Crossword Input Format

Plain text grid where `#` = black square, `_` = blank to solve, letters = pre-filled clues. All rows must be the same width. Example:

```
#_#_#
STA_E
#_#_#
OP_NS
#_#_#
```
