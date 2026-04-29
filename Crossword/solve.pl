#!/usr/bin/env perl
# Crossword Puzzle Solver
# Solves crossword puzzles from ASCII grid files using a local dictionary.
#
# Input format:
#   # = black square
#   _ = blank (to be filled)
#   A-Z or a-z = pre-filled letter clue
#
# Usage: perl solve.pl <puzzle_file> [dictionary_file]

use strict;
use warnings;
use Getopt::Long;
use Time::HiRes qw(time);
use File::Basename;

my $dict_file;
my $hints_file;
my $max_solutions = 1;
my $verbose       = 0;
my $help          = 0;

GetOptions(
    'dict|d=s'       => \$dict_file,
    'hints|H=s'      => \$hints_file,
    'max|m=i'        => \$max_solutions,
    'verbose|v'      => \$verbose,
    'help|h'         => \$help,
) or usage();

usage() if $help;

my $puzzle_file = shift @ARGV or usage("No puzzle file specified");

# Default dictionary path: same directory as this script
unless ($dict_file) {
    my $script_dir = dirname(__FILE__);
    $dict_file = "$script_dir/dictionary.txt";
}

die "Puzzle file '$puzzle_file' not found\n"     unless -f $puzzle_file;
die "Dictionary file '$dict_file' not found\n"   unless -f $dict_file;

# ── Parse the grid ──────────────────────────────────────────────────────────

my @grid;
open my $fh, '<', $puzzle_file or die "Cannot open $puzzle_file: $!\n";
while (my $line = <$fh>) {
    $line =~ s/[\r\n]+$//;
    next if $line =~ /^\s*$/;
    my @row = map { uc($_) } split //, $line;
    push @grid, \@row;
}
close $fh;

my $rows = scalar @grid;
my $cols = scalar @{$grid[0]};

# Validate grid is rectangular
for my $r (0 .. $rows - 1) {
    die "Row $r has " . scalar(@{$grid[$r]}) . " cols, expected $cols\n"
        if scalar(@{$grid[$r]}) != $cols;
}

printf "Grid: %dx%d\n", $rows, $cols if $verbose;

# ── Extract word slots ──────────────────────────────────────────────────────
# A slot is a run of 2+ non-black cells in a row (across) or column (down).

my @slots;  # each: { cells => [[r,c], ...], dir => 'A'|'D', len => N }

# Across slots
for my $r (0 .. $rows - 1) {
    my $c = 0;
    while ($c < $cols) {
        if ($grid[$r][$c] ne '#') {
            my $start = $c;
            $c++ while $c < $cols && $grid[$r][$c] ne '#';
            if ($c - $start >= 2) {
                my @cells = map { [$r, $_] } ($start .. $c - 1);
                push @slots, {
                    cells => \@cells,
                    dir   => 'A',
                    len   => scalar @cells,
                };
            }
        } else {
            $c++;
        }
    }
}

# Down slots
for my $c (0 .. $cols - 1) {
    my $r = 0;
    while ($r < $rows) {
        if ($grid[$r][$c] ne '#') {
            my $start = $r;
            $r++ while $r < $rows && $grid[$r][$c] ne '#';
            if ($r - $start >= 2) {
                my @cells = map { [$_, $c] } ($start .. $r - 1);
                push @slots, {
                    cells => \@cells,
                    dir   => 'D',
                    len   => scalar @cells,
                };
            }
        } else {
            $r++;
        }
    }
}

printf "Found %d word slots\n", scalar @slots if $verbose;

# Assign slot indices and record pre-filled letters
for my $i (0 .. $#slots) {
    $slots[$i]{id} = $i;
    my @pattern;
    for my $pos (0 .. $#{$slots[$i]{cells}}) {
        my ($r, $c) = @{$slots[$i]{cells}[$pos]};
        my $ch = $grid[$r][$c];
        if ($ch ne '_') {
            push @pattern, $ch;
        } else {
            push @pattern, undef;
        }
    }
    $slots[$i]{pattern} = \@pattern;
}

# ── Build crossing map ──────────────────────────────────────────────────────
# For each cell (r,c) that belongs to 2 slots, record the crossing.

my %cell_to_slot;  # "r,c" => [ [slot_idx, pos_in_slot], ... ]

for my $i (0 .. $#slots) {
    for my $pos (0 .. $#{$slots[$i]{cells}}) {
        my ($r, $c) = @{$slots[$i]{cells}[$pos]};
        my $key = "$r,$c";
        push @{$cell_to_slot{$key}}, [$i, $pos];
    }
}

# crossings: for slot i, list of [pos_in_i, slot_j, pos_in_j]
my @crossings;
for my $i (0 .. $#slots) {
    $crossings[$i] = [];
}

for my $key (keys %cell_to_slot) {
    my @entries = @{$cell_to_slot{$key}};
    next if @entries < 2;
    for my $a (0 .. $#entries) {
        for my $b ($a + 1 .. $#entries) {
            my ($si, $pi) = @{$entries[$a]};
            my ($sj, $pj) = @{$entries[$b]};
            push @{$crossings[$si]}, [$pi, $sj, $pj];
            push @{$crossings[$sj]}, [$pj, $si, $pi];
        }
    }
}

# ── Load dictionary ─────────────────────────────────────────────────────────

my %words_by_len;  # length => [ word, ... ]

{
    open my $dfh, '<', $dict_file or die "Cannot open $dict_file: $!\n";
    while (my $word = <$dfh>) {
        $word =~ s/[\r\n]+$//;
        $word = uc($word);
        next unless $word =~ /^[A-Z]{2,}$/;
        push @{$words_by_len{length($word)}}, $word;
    }
    close $dfh;
}

if ($verbose) {
    my $total = 0;
    $total += scalar @{$words_by_len{$_}} for keys %words_by_len;
    printf "Dictionary: %d words loaded\n", $total;
}

# ── Load hints file (LLM-generated candidates) ─────────────────────────────
# Hints map clue numbers to prioritized candidates.
# Format: DIRECTION NUMBER CANDIDATE1 CANDIDATE2 ...

my %hints;  # { "A:1" => [WORD1, WORD2, ...], "D:5" => [...], ... }

if ($hints_file && -f $hints_file) {
    open my $hfh, '<', $hints_file or die "Cannot open $hints_file: $!\n";
    while (my $line = <$hfh>) {
        $line =~ s/[\r\n]+$//;
        next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
        my @parts = split /\s+/, $line;
        next unless @parts >= 3;
        my $dir = uc($parts[0]);
        my $num = $parts[1];
        my @candidates = map { uc($_) } @parts[2 .. $#parts];
        $hints{"$dir:$num"} = \@candidates;
    }
    close $hfh;
    printf "Hints: %d entries loaded\n", scalar keys %hints if $verbose;
}

# ── Assign crossword numbering to slots ────────────────────────────────────
# Standard crossword numbering: cells are numbered L-to-R, top-to-bottom.
# A cell gets a number if it starts an across or down word.

my %slot_clue_num;  # slot_idx => "A:N" or "D:N"

if (keys %hints) {
    # Build numbering map
    my %starts_across;  # "r,c" => slot_idx
    my %starts_down;    # "r,c" => slot_idx
    for my $i (0 .. $#slots) {
        my ($r, $c) = @{$slots[$i]{cells}[0]};
        if ($slots[$i]{dir} eq 'A') {
            $starts_across{"$r,$c"} = $i;
        } else {
            $starts_down{"$r,$c"} = $i;
        }
    }

    my $num = 1;
    for my $r (0 .. $rows - 1) {
        for my $c (0 .. $cols - 1) {
            next if $grid[$r][$c] eq '#';
            my $is_across_start = exists $starts_across{"$r,$c"};
            my $is_down_start   = exists $starts_down{"$r,$c"};
            if ($is_across_start || $is_down_start) {
                if ($is_across_start) {
                    $slot_clue_num{$starts_across{"$r,$c"}} = "A:$num";
                }
                if ($is_down_start) {
                    $slot_clue_num{$starts_down{"$r,$c"}} = "D:$num";
                }
                $num++;
            }
        }
    }
    printf "Numbered %d slots\n", scalar keys %slot_clue_num if $verbose;
}

# ── Build initial domains ──────────────────────────────────────────────────
# Domain of each slot = set of dictionary words that match pre-filled letters.
# When hints are available, hint words are marked for priority ordering.

my @domains;       # slot_idx => { word => 1, ... }
my @hint_words;    # slot_idx => { word => 1, ... } (subset that came from hints)

for my $i (0 .. $#slots) {
    my $len     = $slots[$i]{len};
    my $pattern = $slots[$i]{pattern};
    my %dom;
    my %hwords;

    # If we have hints for this slot, add them first
    my $clue_key = $slot_clue_num{$i} || '';
    if ($clue_key && exists $hints{$clue_key}) {
        for my $word (@{$hints{$clue_key}}) {
            next unless length($word) == $len;
            next unless $word =~ /^[A-Z]+$/;
            # Check against pattern
            my @letters = split //, $word;
            my $ok = 1;
            for my $p (0 .. $len - 1) {
                if (defined $pattern->[$p] && $pattern->[$p] ne $letters[$p]) {
                    $ok = 0;
                    last;
                }
            }
            if ($ok) {
                $dom{$word} = 1;
                $hwords{$word} = 1;
            }
        }
    }

    # Add dictionary words
    my $candidates = $words_by_len{$len} || [];
    for my $word (@$candidates) {
        my @letters = split //, $word;
        my $ok = 1;
        for my $p (0 .. $len - 1) {
            if (defined $pattern->[$p] && $pattern->[$p] ne $letters[$p]) {
                $ok = 0;
                last;
            }
        }
        $dom{$word} = 1 if $ok;
    }

    $domains[$i] = \%dom;
    $hint_words[$i] = \%hwords;

    if ($verbose) {
        my ($r, $c) = @{$slots[$i]{cells}[0]};
        my $hint_count = scalar keys %hwords;
        if ($hint_count) {
            printf "  Slot %d (%s @ %d,%d len=%d): %d candidates (%d from hints)\n",
                $i, $slots[$i]{dir}, $r, $c, $len, scalar keys %dom, $hint_count;
        } else {
            printf "  Slot %d (%s @ %d,%d len=%d): %d candidates\n",
                $i, $slots[$i]{dir}, $r, $c, $len, scalar keys %dom;
        }
    }
}

# ── Arc consistency (AC-3) ──────────────────────────────────────────────────

sub ac3 {
    my ($doms) = @_;

    my @queue;
    for my $i (0 .. $#slots) {
        for my $xing (@{$crossings[$i]}) {
            push @queue, [$i, @$xing];  # [si, pos_i, sj, pos_j]
        }
    }

    while (@queue) {
        my $arc = shift @queue;
        my ($si, $pi, $sj, $pj) = @$arc;

        # Collect letters that slot j allows at position pj
        my %allowed_j;
        for my $wj (keys %{$doms->[$sj]}) {
            $allowed_j{substr($wj, $pj, 1)} = 1;
        }

        my $changed = 0;
        for my $wi (keys %{$doms->[$si]}) {
            unless ($allowed_j{substr($wi, $pi, 1)}) {
                delete $doms->[$si]{$wi};
                $changed = 1;
            }
        }

        if ($changed) {
            return 0 if keys(%{$doms->[$si]}) == 0;
            # Re-enqueue arcs pointing to si
            for my $xing (@{$crossings[$si]}) {
                my ($pos_i, $sk, $pos_k) = @$xing;
                next if $sk == $sj;
                push @queue, [$sk, $pos_k, $si, $pos_i];
            }
        }
    }
    return 1;
}

my $t0 = time();

unless (ac3(\@domains)) {
    die "No solution: arc consistency found empty domain\n";
}

if ($verbose) {
    for my $i (0 .. $#slots) {
        my $n = scalar keys %{$domains[$i]};
        printf "  Slot %d after AC-3: %d candidates\n", $i, $n;
    }
}

# ── Backtracking search with forward checking ──────────────────────────────

my @solution;
my $solutions_found = 0;
my $backtracks      = 0;

# Choose the slot with the smallest domain (MRV heuristic)
sub select_unassigned {
    my ($assignment) = @_;
    my $best_idx  = -1;
    my $best_size = 999_999_999;
    for my $i (0 .. $#slots) {
        next if defined $assignment->[$i];
        my $size = scalar keys %{$domains[$i]};
        if ($size < $best_size) {
            $best_size = $size;
            $best_idx  = $i;
        }
    }
    return $best_idx;
}

sub forward_check {
    my ($assignment, $si, $word_i) = @_;
    my @saved;  # list of [sj, removed_words_hashref]

    for my $xing (@{$crossings[$si]}) {
        my ($pi, $sj, $pj) = @$xing;
        next if defined $assignment->[$sj];

        my $required_letter = substr($word_i, $pi, 1);
        my %removed;

        for my $wj (keys %{$domains[$sj]}) {
            if (substr($wj, $pj, 1) ne $required_letter) {
                $removed{$wj} = 1;
                delete $domains[$sj]{$wj};
            }
        }

        push @saved, [$sj, \%removed] if keys %removed;

        if (keys(%{$domains[$sj]}) == 0) {
            # Undo removals so far
            for my $s (@saved) {
                my ($idx, $rem) = @$s;
                $domains[$idx]{$_} = 1 for keys %$rem;
            }
            return undef;
        }
    }

    return \@saved;
}

sub restore_domains {
    my ($saved) = @_;
    for my $s (@$saved) {
        my ($idx, $rem) = @$s;
        $domains[$idx]{$_} = 1 for keys %$rem;
    }
}

sub solve {
    my ($assignment) = @_;

    my $idx = select_unassigned($assignment);
    if ($idx == -1) {
        # All slots assigned — found a solution
        $solutions_found++;
        print_solution($assignment);
        return 1 if $solutions_found >= $max_solutions;
        return 0;  # keep searching for more
    }

    # Try hint words first, then dictionary words alphabetically
    my @candidates;
    my %is_hint = %{$hint_words[$idx]};
    my @hints_list = sort grep { $is_hint{$_} && exists $domains[$idx]{$_} } keys %{$domains[$idx]};
    my @others = sort grep { !$is_hint{$_} } keys %{$domains[$idx]};
    @candidates = (@hints_list, @others);

    for my $word (@candidates) {
        # Check crossing constraints with already-assigned slots
        my $consistent = 1;
        for my $xing (@{$crossings[$idx]}) {
            my ($pi, $sj, $pj) = @$xing;
            if (defined $assignment->[$sj]) {
                if (substr($word, $pi, 1) ne substr($assignment->[$sj], $pj, 1)) {
                    $consistent = 0;
                    last;
                }
            }
        }
        next unless $consistent;

        $assignment->[$idx] = $word;
        my $saved = forward_check($assignment, $idx, $word);

        if (defined $saved) {
            if (solve($assignment)) {
                return 1;
            }
            restore_domains($saved);
        }

        $backtracks++;
        $assignment->[$idx] = undef;
    }

    return 0;
}

sub print_solution {
    my ($assignment) = @_;

    # Build solved grid
    my @solved;
    for my $r (0 .. $rows - 1) {
        $solved[$r] = [ @{$grid[$r]} ];
    }

    for my $i (0 .. $#slots) {
        my $word = $assignment->[$i];
        my @letters = split //, $word;
        for my $pos (0 .. $#{$slots[$i]{cells}}) {
            my ($r, $c) = @{$slots[$i]{cells}[$pos]};
            $solved[$r][$c] = $letters[$pos];
        }
    }

    if ($solutions_found > 1) {
        print "\n--- Solution $solutions_found ---\n";
    }

    for my $r (0 .. $rows - 1) {
        print join('', @{$solved[$r]}), "\n";
    }
}

my @assignment;
$#assignment = $#slots;

print "Solving...\n" if $verbose;

# ── Two-phase solve when hints are available ───────────────────────────────
# Phase 1: Try with restricted domains (hints-only for hinted slots)
# Phase 2: Fall back to full dictionary with hints prioritized

my $solved = 0;

if (keys %hints) {
    # Phase 1: restrict hinted slots to only hint words
    my @saved_domains;
    my $can_try_restricted = 1;

    for my $i (0 .. $#slots) {
        $saved_domains[$i] = { %{$domains[$i]} };  # deep copy
        if (keys %{$hint_words[$i]}) {
            # Restrict to just hint words that survived AC-3
            my %restricted;
            for my $w (keys %{$hint_words[$i]}) {
                $restricted{$w} = 1 if exists $domains[$i]{$w};
            }
            if (keys %restricted) {
                $domains[$i] = \%restricted;
            } else {
                # No hint words survived AC-3, can't use restricted mode
                $can_try_restricted = 0;
                last;
            }
        }
    }

    if ($can_try_restricted) {
        printf "Phase 1: trying hints-only solve...\n" if $verbose;
        $solved = solve(\@assignment);
    }

    if (!$solved) {
        # Restore full domains for phase 2
        printf "Phase 2: full dictionary with hints prioritized...\n" if $verbose;
        @domains = @saved_domains;
        @assignment = ();
        $#assignment = $#slots;
        $solutions_found = 0;
        $backtracks = 0;
        $solved = solve(\@assignment);
    }
} else {
    $solved = solve(\@assignment);
}

my $elapsed = time() - $t0;

if ($solutions_found == 0) {
    print "No solution found.\n";
} elsif ($verbose) {
    printf "\nFound %d solution(s) in %.3f seconds (%d backtracks)\n",
        $solutions_found, $elapsed, $backtracks;
}

exit($solutions_found > 0 ? 0 : 1);

# ── Usage ───────────────────────────────────────────────────────────────────

sub usage {
    my $msg = shift;
    print STDERR "$msg\n\n" if $msg;
    print STDERR <<'END';
Usage: perl solve.pl [options] <puzzle_file>

Options:
  -d, --dict FILE    Path to dictionary file (default: dictionary.txt in script dir)
  -H, --hints FILE   Path to hints file (LLM-generated candidates)
  -m, --max N        Maximum solutions to find (default: 1)
  -v, --verbose      Show progress details
  -h, --help         Show this help

Input format (plain text grid):
  #  = black square
  _  = blank cell (to be solved)
  A-Z = pre-filled letter clue

Hints file format (one per line):
  A 1 ASH OAK BAT      (Across clue 1, candidates in priority order)
  D 5 GATOR CROC       (Down clue 5, candidates in priority order)

Example:
  #___#
  _____
  __A__
  _____
  #___#
END
    exit 1;
}
