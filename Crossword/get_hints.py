#!/usr/bin/env python3
"""
get_hints.py - Extract crossword clues from PDF and query ollama for candidate answers.

Reads a WSJ crossword PDF, extracts the grid structure and clue text,
queries a local ollama LLM for candidate answers, and outputs a hints file
that solve.pl can use to prioritize candidates.

Usage:
    python3 get_hints.py puzzle.pdf                    # outputs puzzle.hints
    python3 get_hints.py puzzle.pdf -o hints.txt       # custom output
    python3 get_hints.py puzzle.pdf -m llama3.1:8b     # different model
    python3 get_hints.py puzzle.pdf -n 5               # 5 candidates/clue
    python3 get_hints.py puzzle.pdf --grid puzzle.txt  # use existing grid file
    python3 get_hints.py --batch DIR/                  # process all PDFs in dir

Hints file format:
    A 1 ASH OAK BAT
    A 4 GATOR CROC
    D 1 ASKS BEGS
    ...
Each line: direction(A/D) clue_number candidate1 candidate2 ...
"""

import sys
import os
import re
import json
import time
import argparse
import urllib.request
from pathlib import Path

try:
    import fitz  # PyMuPDF
except ImportError:
    print("Error: PyMuPDF required. Install with: pip install pymupdf", file=sys.stderr)
    sys.exit(1)


def extract_grid_from_pdf(pdf_path):
    """Extract grid structure from PDF. Returns grid as 2D list and cell_size."""
    doc = fitz.open(pdf_path)
    page = doc[0]
    drawings = page.get_drawings()

    # Find filled rectangles
    rects = []
    for d in drawings:
        if d.get('fill') is not None and d.get('items'):
            for item in d['items']:
                if item[0] == 're':
                    rect = item[1]
                    w = rect.width
                    h = rect.height
                    if w > 5 and h > 5:
                        rects.append((rect, d['fill']))

    if not rects:
        return None, None

    # Separate background (white/light, largest) from black squares
    rects.sort(key=lambda x: x[0].width * x[0].height, reverse=True)

    # Find background rect (largest white-ish rect)
    bg_rect = None
    for rect, fill in rects:
        if fill and sum(fill[:3]) > 2.0:  # white or near-white
            bg_rect = rect
            break

    if not bg_rect:
        bg_rect = rects[0][0]

    # Find black squares
    black_squares = []
    for rect, fill in rects:
        w = rect.width
        h = rect.height
        if fill and sum(fill[:3]) < 0.5 and 8 < w < 25 and 8 < h < 25:
            black_squares.append(rect)

    if not black_squares:
        return None, None

    # Detect cell size from black squares
    widths = [r.width for r in black_squares]
    cell_size = sorted(widths)[len(widths) // 2]  # median

    # Determine grid dimensions
    grid_w = round(bg_rect.width / cell_size)
    grid_h = round(bg_rect.height / cell_size)

    if grid_w < 5 or grid_h < 5 or grid_w > 25 or grid_h > 25:
        return None, None

    # Build grid
    grid = [['_'] * grid_w for _ in range(grid_h)]
    for r in black_squares:
        cx = r.x0 + r.width / 2
        cy = r.y0 + r.height / 2
        col = int((cx - bg_rect.x0) / cell_size)
        row = int((cy - bg_rect.y0) / cell_size)
        if 0 <= row < grid_h and 0 <= col < grid_w:
            grid[row][col] = '#'

    doc.close()
    return grid, cell_size


def number_grid(grid):
    """Assign crossword numbering to the grid. Returns dict mapping (row,col) -> number."""
    rows = len(grid)
    cols = len(grid[0])
    numbering = {}
    num = 1

    for r in range(rows):
        for c in range(cols):
            if grid[r][c] == '#':
                continue
            starts_across = (c == 0 or grid[r][c-1] == '#') and (c + 1 < cols and grid[r][c+1] != '#')
            starts_down = (r == 0 or grid[r-1][c] == '#') and (r + 1 < rows and grid[r+1][c] != '#')
            if starts_across or starts_down:
                numbering[(r, c)] = num
                num += 1

    return numbering


def get_slot_lengths(grid, numbering):
    """Get word lengths for each numbered clue. Returns dict: (direction, number) -> length."""
    rows = len(grid)
    cols = len(grid[0])
    slots = {}

    for (r, c), num in numbering.items():
        # Check across
        if (c == 0 or grid[r][c-1] == '#') and (c + 1 < cols and grid[r][c+1] != '#'):
            length = 0
            cc = c
            while cc < cols and grid[r][cc] != '#':
                length += 1
                cc += 1
            slots[('A', num)] = length

        # Check down
        if (r == 0 or grid[r-1][c] == '#') and (r + 1 < rows and grid[r+1][c] != '#'):
            length = 0
            rr = r
            while rr < rows and grid[rr][c] != '#':
                length += 1
                rr += 1
            slots[('D', num)] = length

    return slots


def extract_clues_from_pdf(pdf_path):
    """Extract clue text from PDF. Returns dict: (direction, number) -> clue_text."""
    doc = fitz.open(pdf_path)
    page = doc[0]
    text = page.get_text('text')
    doc.close()

    clues = {}

    # Find "Across" and "Down" sections
    across_match = re.search(r'\bAcross\b', text)
    down_match = re.search(r'\bDown\b', text)

    if not across_match:
        return clues

    # Extract all clue entries using regex
    # Clues look like: \t N \t clue text (possibly multi-line)
    # Or just: N clue text
    clue_pattern = re.compile(r'(?:^|\t)\s*(\d+)\s+(.+?)(?=(?:^|\t)\s*\d+\s|\Z)', re.DOTALL | re.MULTILINE)

    if down_match:
        across_text = text[across_match.end():down_match.start()]
        down_text = text[down_match.end():]
    else:
        across_text = text[across_match.end():]
        down_text = ""

    # Remove common interruptions that appear mid-text
    noise_patterns = [
        r'Previous Puzzle.s Solution',
        r'Email your answer.*?(?=\t\s*\d+|\Z)',
        r'A solver selected.*?(?=\t\s*\d+|\Z)',
    ]
    for pattern in noise_patterns:
        across_text = re.sub(pattern, '', across_text, flags=re.DOTALL)
        down_text = re.sub(pattern, '', down_text, flags=re.DOTALL)

    def parse_clues(text_block):
        """Parse clue numbers and text from a block."""
        result = {}
        # Split on clue number pattern
        parts = re.split(r'[\t\n]\s*(\d+)\s*[\t\n\s]', text_block)
        # parts: [preamble, num1, text1, num2, text2, ...]
        i = 1
        while i < len(parts) - 1:
            num = int(parts[i])
            clue_text = parts[i + 1].strip()
            # Clean up multi-line clues
            clue_text = re.sub(r'\s*\n\s*', ' ', clue_text)
            clue_text = clue_text.strip()
            if clue_text:
                result[num] = clue_text
            i += 2
        return result

    across_clues = parse_clues(across_text)
    down_clues = parse_clues(down_text)

    for num, text in across_clues.items():
        clues[('A', num)] = text
    for num, text in down_clues.items():
        clues[('D', num)] = text

    return clues


def query_ollama(clue, length, model='qwen2.5:7b', num_candidates=5, timeout=30):
    """Query ollama for crossword answer candidates using multiple strategies."""
    candidates = []
    seen = set()

    def add_candidate(word):
        w = re.sub(r'[^A-Za-z]', '', word).upper()
        if w and len(w) == length and w not in seen:
            seen.add(w)
            candidates.append(w)

    # Strategy 1: Direct single-answer query at low temperature (most likely answer)
    for temp in [0.2, 0.6, 1.0]:
        if len(candidates) >= num_candidates:
            break
        try:
            prompt = f'Crossword answer for "{clue}" that is exactly {length} letters: '
            data = json.dumps({
                'model': model,
                'prompt': prompt,
                'stream': False,
                'options': {'temperature': temp, 'num_predict': 20}
            }).encode()
            req = urllib.request.Request(
                'http://localhost:11434/api/generate',
                data=data,
                headers={'Content-Type': 'application/json'}
            )
            resp = urllib.request.urlopen(req, timeout=timeout)
            result = json.loads(resp.read())
            text = result.get('response', '').strip()
            # Parse first word from response
            for token in re.split(r'[\s,;/\n\.\(\)]', text):
                add_candidate(token)
                if len(candidates) >= num_candidates:
                    break
        except Exception:
            pass

    # Strategy 2: List-format query if we still need more candidates
    if len(candidates) < num_candidates:
        try:
            prompt = (
                f'List {num_candidates} possible crossword answers for the clue "{clue}". '
                f'Each answer must be exactly {length} letters long. '
                f'Write one answer per line, uppercase only, no explanations:'
            )
            data = json.dumps({
                'model': model,
                'prompt': prompt,
                'stream': False,
                'options': {'temperature': 0.8, 'num_predict': 80}
            }).encode()
            req = urllib.request.Request(
                'http://localhost:11434/api/generate',
                data=data,
                headers={'Content-Type': 'application/json'}
            )
            resp = urllib.request.urlopen(req, timeout=timeout)
            result = json.loads(resp.read())
            text = result.get('response', '')
            for line in text.split('\n'):
                for token in re.split(r'[\s,;/\.\(\)\d]+', line):
                    add_candidate(token)
                if len(candidates) >= num_candidates:
                    break
        except Exception:
            pass

    return candidates


def query_ollama_batch(clues_with_lengths, model='qwen2.5:7b', num_candidates=3, timeout=60):
    """Query ollama with multiple clues in one prompt for speed."""
    if not clues_with_lengths:
        return {}

    # Build batch prompt (max ~10 clues per batch)
    clue_lines = []
    keys = []
    for key, clue, length in clues_with_lengths:
        clue_lines.append(f'- "{clue}" ({length} letters)')
        keys.append((key, length))

    prompt = (
        'You are a crossword puzzle expert. For each clue below, provide the single most likely '
        'crossword answer that is EXACTLY the specified number of letters. '
        'Reply with ONLY the answers, one per line, in uppercase. '
        'Each answer must match its required letter count exactly.\n\n'
        + '\n'.join(clue_lines)
    )

    data = json.dumps({
        'model': model,
        'prompt': prompt,
        'stream': False,
        'options': {
            'temperature': 0.3,
            'num_predict': len(clues_with_lengths) * 15,
        }
    }).encode()

    try:
        req = urllib.request.Request(
            'http://localhost:11434/api/generate',
            data=data,
            headers={'Content-Type': 'application/json'}
        )
        resp = urllib.request.urlopen(req, timeout=timeout)
        result = json.loads(resp.read())
        response_text = result.get('response', '')

        # Parse responses
        results = {}
        lines = [l.strip() for l in response_text.strip().split('\n') if l.strip()]
        for i, line in enumerate(lines):
            if i >= len(keys):
                break
            key, expected_length = keys[i]
            word = re.sub(r'^[\d\.\)\-\*\s]+', '', line).strip()
            word = re.sub(r'\s.*$', '', word)
            word = re.sub(r'[^A-Za-z]', '', word).upper()
            if word and len(word) == expected_length:
                results[key] = [word]

        return results

    except Exception:
        return {}


def generate_hints(pdf_path, model='qwen2.5:7b', num_candidates=5, verbose=False,
                   grid_file=None):
    """Full pipeline: PDF -> clues -> ollama -> hints dict."""
    if verbose:
        print(f"Processing: {pdf_path}", file=sys.stderr)

    # Get grid (from file or PDF)
    if grid_file and os.path.exists(grid_file):
        grid = []
        with open(grid_file) as f:
            for line in f:
                line = line.rstrip('\r\n')
                if line and all(c in '#_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' for c in line):
                    grid.append(list(line.upper()))
    else:
        grid, _ = extract_grid_from_pdf(pdf_path)

    if not grid:
        if verbose:
            print(f"  Could not extract grid", file=sys.stderr)
        return None

    # Number the grid and get slot lengths
    numbering = number_grid(grid)
    slot_lengths = get_slot_lengths(grid, numbering)

    if verbose:
        print(f"  Grid: {len(grid[0])}x{len(grid)} with {len(slot_lengths)} slots", file=sys.stderr)

    # Extract clues
    clues = extract_clues_from_pdf(pdf_path)
    if not clues:
        if verbose:
            print(f"  Could not extract clues", file=sys.stderr)
        return None

    if verbose:
        print(f"  Extracted {len(clues)} clues", file=sys.stderr)

    # Match clues to slots and query ollama
    hints = {}
    total = len(slot_lengths)
    matched = 0
    answered = 0

    for i, ((direction, num), length) in enumerate(sorted(slot_lengths.items())):
        clue_text = clues.get((direction, num))
        if not clue_text:
            continue
        matched += 1

        if verbose:
            dir_name = "Across" if direction == 'A' else "Down"
            print(f"  [{i+1}/{total}] {num} {dir_name} ({length}): {clue_text[:50]}...",
                  end='', file=sys.stderr, flush=True)

        candidates = query_ollama(clue_text, length, model, num_candidates)

        if candidates:
            hints[(direction, num)] = candidates
            answered += 1
            if verbose:
                print(f" -> {', '.join(candidates)}", file=sys.stderr)
        else:
            if verbose:
                print(f" -> (no valid candidates)", file=sys.stderr)

    if verbose:
        print(f"  Results: {matched} clues matched, {answered} answered by LLM", file=sys.stderr)

    return hints


def write_hints_file(hints, output_path):
    """Write hints to file in format: DIRECTION NUMBER CANDIDATE1 CANDIDATE2 ..."""
    with open(output_path, 'w') as f:
        f.write("# Crossword hints generated by get_hints.py + ollama\n")
        f.write("# Format: DIRECTION NUMBER CANDIDATE1 CANDIDATE2 ...\n")
        for (direction, num), candidates in sorted(hints.items()):
            f.write(f"{direction} {num} {' '.join(candidates)}\n")


def main():
    parser = argparse.ArgumentParser(
        description='Generate crossword hints using local LLM (ollama)')
    parser.add_argument('input', nargs='?', help='PDF file or directory (with --batch)')
    parser.add_argument('-o', '--output', help='Output hints file (default: input.hints)')
    parser.add_argument('-m', '--model', default='qwen2.5:7b',
                        help='Ollama model to use (default: qwen2.5:7b)')
    parser.add_argument('-n', '--num-candidates', type=int, default=5,
                        help='Number of candidates per clue (default: 5)')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Show progress')
    parser.add_argument('--grid', help='Use existing grid .txt file instead of extracting from PDF')
    parser.add_argument('--batch', action='store_true',
                        help='Process all PDFs in directory')
    parser.add_argument('--timeout', type=int, default=30,
                        help='Timeout per ollama query in seconds (default: 30)')

    args = parser.parse_args()

    if not args.input:
        parser.print_help()
        sys.exit(1)

    # Check ollama availability
    try:
        req = urllib.request.Request('http://localhost:11434/api/tags')
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        print("Error: Cannot connect to ollama at localhost:11434", file=sys.stderr)
        print("Start ollama with: ollama serve", file=sys.stderr)
        sys.exit(1)

    if args.batch:
        # Batch mode: process all PDFs in directory
        input_dir = Path(args.input)
        if not input_dir.is_dir():
            print(f"Error: {args.input} is not a directory", file=sys.stderr)
            sys.exit(1)

        pdfs = sorted(input_dir.glob('*.pdf')) + sorted(input_dir.glob('*.PDF'))
        print(f"Processing {len(pdfs)} PDFs in {input_dir}")

        success = 0
        failed = 0
        for pdf_path in pdfs:
            hints_path = pdf_path.with_suffix('.hints')
            grid_path = pdf_path.with_suffix('.txt')

            if hints_path.exists():
                if args.verbose:
                    print(f"  Skipping {pdf_path.name} (hints exist)")
                success += 1
                continue

            grid_file = str(grid_path) if grid_path.exists() else None
            hints = generate_hints(str(pdf_path), args.model, args.num_candidates,
                                   args.verbose, grid_file)

            if hints:
                write_hints_file(hints, str(hints_path))
                success += 1
                if not args.verbose:
                    print(f"  OK: {pdf_path.name} ({len(hints)} hints)")
            else:
                failed += 1
                if not args.verbose:
                    print(f"  FAIL: {pdf_path.name}")

        print(f"\nDone: {success} succeeded, {failed} failed")

    else:
        # Single file mode
        pdf_path = args.input
        if not os.path.exists(pdf_path):
            print(f"Error: {pdf_path} not found", file=sys.stderr)
            sys.exit(1)

        output_path = args.output or str(Path(pdf_path).with_suffix('.hints'))
        grid_file = args.grid

        start_time = time.time()
        hints = generate_hints(pdf_path, args.model, args.num_candidates,
                               args.verbose, grid_file)
        elapsed = time.time() - start_time

        if hints:
            write_hints_file(hints, output_path)
            print(f"Wrote {len(hints)} hints to {output_path} ({elapsed:.1f}s)")
        else:
            print(f"Failed to generate hints for {pdf_path}", file=sys.stderr)
            sys.exit(1)


if __name__ == '__main__':
    main()
