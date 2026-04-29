#!/usr/bin/env python3
"""Convert WSJ crossword PDF files to ASCII grid format.

Extracts the crossword grid from PDF vector drawings and outputs
the ASCII representation used by solve.pl.

Requires: PyMuPDF (pip install pymupdf)

Usage:
    python3 pdf_to_grid.py <pdf_file> [<pdf_file> ...]
    python3 pdf_to_grid.py -o output_dir/ *.pdf
    python3 pdf_to_grid.py --batch <directory>
"""

import sys
import os
import argparse
from collections import Counter

try:
    import fitz  # PyMuPDF
except ImportError:
    print("Error: PyMuPDF is required. Install with: pip install pymupdf",
          file=sys.stderr)
    sys.exit(1)


def extract_rects(page):
    """Extract all filled rectangles from a PDF page."""
    rects = []
    for d in page.get_drawings():
        for item in d["items"]:
            if item[0] == "re":
                rects.append({
                    "rect": item[1],
                    "fill": d.get("fill"),
                    "color": d.get("color"),
                })
    return rects


def find_grid_background(rects):
    """Find the large white rectangle that forms the grid background."""
    white = [r for r in rects
             if r["fill"] and all(c > 0.95 for c in r["fill"])]
    if not white:
        return None
    return max(white, key=lambda r: r["rect"].width * r["rect"].height)["rect"]


def find_black_squares(rects, bg, cell_size):
    """Find black filled rectangles inside the grid that match cell size."""
    tolerance = cell_size * 0.3
    squares = []
    for r in rects:
        fill = r["fill"]
        if not fill or any(c > 0.05 for c in fill):
            continue
        rect = r["rect"]
        if abs(rect.width - cell_size) > tolerance:
            continue
        if abs(rect.height - cell_size) > tolerance:
            continue
        if rect.x0 < bg.x0 - 1 or rect.y0 < bg.y0 - 1:
            continue
        if rect.x1 > bg.x1 + 1 or rect.y1 > bg.y1 + 1:
            continue
        squares.append(rect)
    return squares


def detect_cell_size(rects, bg):
    """Detect cell size from black squares inside the grid."""
    black_in_grid = []
    for r in rects:
        fill = r["fill"]
        if not fill or any(c > 0.05 for c in fill):
            continue
        rect = r["rect"]
        if (rect.width < 5 or rect.width > bg.width / 2):
            continue
        if (rect.x0 >= bg.x0 - 1 and rect.y0 >= bg.y0 - 1 and
                rect.x1 <= bg.x1 + 1 and rect.y1 <= bg.y1 + 1):
            black_in_grid.append(rect)

    if not black_in_grid:
        return None

    # Find the most common square size
    sizes = Counter()
    for r in black_in_grid:
        s = (round(r.width, 0), round(r.height, 0))
        if abs(s[0] - s[1]) <= 1:  # approximately square
            sizes[s] += 1

    if not sizes:
        return None

    best = sizes.most_common(1)[0][0]
    # Refine with mean of all rects matching best size
    matching = [r for r in black_in_grid
                if abs(round(r.width, 0) - best[0]) <= 1
                and abs(round(r.height, 0) - best[1]) <= 1]
    avg_w = sum(r.width for r in matching) / len(matching)
    avg_h = sum(r.height for r in matching) / len(matching)
    return (avg_w + avg_h) / 2


def extract_prefilled_letters(page, bg, cell_size, grid_rows, grid_cols):
    """Extract any pre-filled letters from the grid (not clue numbers)."""
    letters = {}
    td = page.get_text("dict")

    # Clue numbers are small; pre-filled letters are larger and centered
    # Typical clue number size is 6-9pt; letters would be 10+pt
    min_letter_size = cell_size * 0.5

    for b in td["blocks"]:
        if "lines" not in b:
            continue
        for line in b["lines"]:
            for span in line["spans"]:
                if span["size"] < min_letter_size:
                    continue
                text = span["text"].strip()
                if len(text) != 1 or not text.isalpha():
                    continue
                x, y = span["origin"]
                if not (bg.x0 <= x <= bg.x1 and bg.y0 <= y <= bg.y1):
                    continue
                col = int((x - bg.x0) / cell_size)
                row = int((y - bg.y0) / cell_size)
                if 0 <= row < grid_rows and 0 <= col < grid_cols:
                    letters[(row, col)] = text.upper()

    return letters


def extract_grid_standard(page):
    """Extract grid using the standard format: white background + black squares."""
    rects = extract_rects(page)
    bg = find_grid_background(rects)
    if bg is None:
        return None, "No grid background found"

    cell_size = detect_cell_size(rects, bg)
    if cell_size is None:
        # Try deriving from common crossword sizes
        for n in [15, 21, 17, 19, 23, 13, 11]:
            cs = bg.width / n
            if abs(cs - bg.height / n) < 1:
                cell_size = cs
                break
    if cell_size is None:
        return None, "Could not determine cell size"

    grid_cols = round(bg.width / cell_size)
    grid_rows = round(bg.height / cell_size)

    if grid_rows < 3 or grid_cols < 3 or grid_rows > 30 or grid_cols > 30:
        return None, f"Unusual grid size {grid_rows}x{grid_cols}"

    black_squares = find_black_squares(rects, bg, cell_size)

    grid = [['_'] * grid_cols for _ in range(grid_rows)]
    for sq in black_squares:
        col = round((sq.x0 - bg.x0) / cell_size)
        row = round((sq.y0 - bg.y0) / cell_size)
        if 0 <= row < grid_rows and 0 <= col < grid_cols:
            grid[row][col] = '#'

    # Check for pre-filled letters
    letters = extract_prefilled_letters(page, bg, cell_size, grid_rows, grid_cols)
    for (r, c), ch in letters.items():
        if grid[r][c] == '_':
            grid[r][c] = ch

    return grid, None


def grid_to_string(grid):
    """Convert grid to ASCII string."""
    return '\n'.join(''.join(row) for row in grid)


def validate_grid(grid):
    """Basic validation: check it looks like a real crossword."""
    rows = len(grid)
    cols = len(grid[0])
    black = sum(1 for r in grid for c in r if c == '#')
    total = rows * cols
    black_pct = black / total * 100

    issues = []
    if black == 0:
        issues.append("no black squares (may be a barred/variety puzzle)")
    if black_pct > 50:
        issues.append(f"unusually high black square density ({black_pct:.0f}%)")

    # Count word slots
    slots = 0
    for r in grid:
        run = 0
        for c in r:
            if c != '#':
                run += 1
            else:
                if run >= 2:
                    slots += 1
                run = 0
        if run >= 2:
            slots += 1
    for ci in range(cols):
        run = 0
        for ri in range(rows):
            if grid[ri][ci] != '#':
                run += 1
            else:
                if run >= 2:
                    slots += 1
                run = 0
        if run >= 2:
            slots += 1

    if slots < 2:
        issues.append("too few word slots")

    return issues


def convert_pdf(pdf_path, verbose=False):
    """Convert a single PDF to an ASCII grid. Returns (grid_string, warnings)."""
    doc = fitz.open(pdf_path)
    warnings = []

    if len(doc) == 0:
        doc.close()
        return None, ["Empty PDF"]

    page = doc[0]
    grid, err = extract_grid_standard(page)
    doc.close()

    if grid is None:
        return None, [err]

    issues = validate_grid(grid)
    if issues:
        warnings.extend(issues)

    rows = len(grid)
    cols = len(grid[0])
    black = sum(1 for r in grid for c in r if c == '#')

    if verbose:
        print(f"  Grid: {rows}x{cols}, {black} black squares, "
              f"{rows * cols - black} cells", file=sys.stderr)
        if warnings:
            for w in warnings:
                print(f"  Warning: {w}", file=sys.stderr)

    return grid_to_string(grid), warnings


def main():
    parser = argparse.ArgumentParser(
        description="Convert WSJ crossword PDFs to ASCII grid format")
    parser.add_argument("files", nargs="*", help="PDF files to convert")
    parser.add_argument("-o", "--outdir",
                        help="Output directory (default: print to stdout)")
    parser.add_argument("-b", "--batch",
                        help="Convert all PDFs in a directory")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Show conversion details")
    parser.add_argument("-s", "--suffix", default=".txt",
                        help="Output file suffix (default: .txt)")
    args = parser.parse_args()

    files = list(args.files)
    if args.batch:
        batch_dir = args.batch
        files.extend(
            os.path.join(batch_dir, f)
            for f in sorted(os.listdir(batch_dir))
            if f.lower().endswith(".pdf")
        )

    if not files:
        parser.print_help()
        sys.exit(1)

    if args.outdir:
        os.makedirs(args.outdir, exist_ok=True)

    success = 0
    failed = 0
    skipped = 0

    for pdf_path in files:
        basename = os.path.splitext(os.path.basename(pdf_path))[0]

        if args.verbose:
            print(f"Converting: {pdf_path}", file=sys.stderr)

        try:
            result, warnings = convert_pdf(pdf_path, verbose=args.verbose)
        except Exception as e:
            print(f"Error: {pdf_path}: {e}", file=sys.stderr)
            failed += 1
            continue

        if result is None:
            print(f"Skipped: {pdf_path}: {'; '.join(warnings)}",
                  file=sys.stderr)
            skipped += 1
            continue

        # Skip grids with no black squares (variety puzzles)
        has_warning_skip = any("no black squares" in w for w in warnings)
        if has_warning_skip:
            print(f"Skipped: {pdf_path}: {'; '.join(warnings)}",
                  file=sys.stderr)
            skipped += 1
            continue

        if args.outdir:
            out_path = os.path.join(args.outdir, basename + args.suffix)
            with open(out_path, 'w') as f:
                f.write(result + '\n')
            if args.verbose:
                print(f"  Wrote: {out_path}", file=sys.stderr)
        else:
            if len(files) > 1:
                print(f"--- {basename} ---")
            print(result)
            if len(files) > 1:
                print()

        success += 1

    if len(files) > 1:
        print(f"\nConverted: {success}, Skipped: {skipped}, Failed: {failed}",
              file=sys.stderr)

    sys.exit(0 if success > 0 else 1)


if __name__ == "__main__":
    main()
