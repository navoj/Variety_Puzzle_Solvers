#!/usr/bin/env perl
# solve_with_hints.pl - Full pipeline: PDF → clue extraction → LLM hints → solve
#
# Requires: python3 with pymupdf, ollama running locally, solve.pl, get_hints.py
#
# Usage:
#   perl solve_with_hints.pl puzzle.pdf           # generates .hints, solves, prints grid
#   perl solve_with_hints.pl puzzle.pdf -v        # verbose output
#   perl solve_with_hints.pl puzzle.pdf -n 5      # 5 candidates per clue
#   perl solve_with_hints.pl puzzle.pdf --skip-hints  # use existing .hints file

use strict;
use warnings;
use Getopt::Long;
use File::Basename;
use Time::HiRes qw(time);

my $verbose    = 0;
my $help       = 0;
my $n_cands    = 3;
my $model      = 'qwen2.5:7b';
my $skip_hints = 0;
my $timeout    = 60;

GetOptions(
    'verbose|v'      => \$verbose,
    'help|h'         => \$help,
    'candidates|n=i' => \$n_cands,
    'model|m=s'      => \$model,
    'skip-hints'     => \$skip_hints,
    'timeout|t=i'    => \$timeout,
) or usage();

usage() if $help;

my $input = shift @ARGV or usage("No input file specified");

my $script_dir = dirname(__FILE__);
my $solve_pl   = "$script_dir/solve.pl";
my $get_hints  = "$script_dir/get_hints.py";

die "solve.pl not found at $solve_pl\n"       unless -f $solve_pl;
die "get_hints.py not found at $get_hints\n"  unless -f $get_hints;

# Determine file paths
my ($base, $dir, $ext) = fileparse($input, qr/\.[^.]*/);
my $pdf_file   = $input;
my $grid_file  = "${dir}${base}.txt";
my $hints_file = "${dir}${base}.hints";

# Step 1: Ensure grid file exists (convert PDF if needed)
if (!-f $grid_file) {
    my $pdf_to_grid = "$script_dir/pdf_to_grid.py";
    die "No grid file and pdf_to_grid.py not found\n" unless -f $pdf_to_grid;
    print "Converting PDF to grid...\n" if $verbose;
    system("python3", $pdf_to_grid, $pdf_file, "-o", $dir) == 0
        or die "PDF conversion failed\n";
    die "Grid file not created: $grid_file\n" unless -f $grid_file;
}

# Step 2: Generate hints (unless skipped or already exists)
if (!$skip_hints || !-f $hints_file) {
    if (-f $hints_file && $skip_hints) {
        print "Using existing hints: $hints_file\n" if $verbose;
    } else {
        print "Generating hints with ollama ($model)...\n" if $verbose;
        my $t0 = time();
        my @cmd = ("python3", $get_hints, $pdf_file,
                   "-o", $hints_file,
                   "-m", $model,
                   "-n", $n_cands,
                   "--grid", $grid_file);
        push @cmd, "-v" if $verbose;
        system(@cmd) == 0 or warn "Hint generation had issues (continuing anyway)\n";
        printf "Hints generated in %.1f seconds\n", time() - $t0 if $verbose;
    }
}

# Step 3: Solve
print "Solving puzzle...\n" if $verbose;
my @solve_cmd = ("perl", $solve_pl, $grid_file);
push @solve_cmd, "--hints=$hints_file" if -f $hints_file;
push @solve_cmd, "-v" if $verbose;

exec @solve_cmd;

sub usage {
    my $msg = shift;
    print STDERR "$msg\n\n" if $msg;
    print STDERR <<'END';
Usage: perl solve_with_hints.pl [options] <puzzle.pdf>

Full pipeline: extracts grid from PDF, generates LLM hints via ollama,
then solves the puzzle with hint-assisted constraint satisfaction.

Options:
  -n, --candidates N   Candidates per clue from LLM (default: 3)
  -m, --model MODEL    Ollama model (default: qwen2.5:7b)
  -t, --timeout SECS   Solver timeout in seconds (default: 60)
  --skip-hints         Use existing .hints file if present
  -v, --verbose        Show progress
  -h, --help           Show this help

Requirements:
  - ollama running locally (ollama serve)
  - Python 3 with PyMuPDF (pip install pymupdf)
  - solve.pl and get_hints.py in same directory
END
    exit 1;
}
