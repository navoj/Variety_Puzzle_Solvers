#!/usr/bin/env perl
# Test harness for solving all crossword puzzles in a directory.
#
# Solves each .txt grid file and writes the solution alongside it
# with a _solved.txt suffix. Prints a summary of results.
#
# Usage: perl test_all.pl [options] [directory]
#
# Options:
#   -t, --timeout N     Per-puzzle timeout in seconds (default: 60)
#   --hints             Generate LLM hints via ollama before solving
#   --model MODEL       Ollama model for hints (default: qwen2.5:7b)
#   --candidates N      Candidates per clue (default: 3)
#   --pdf-dir DIR       Directory with source PDFs (for hint generation)
#   -v, --verbose       Show each puzzle's output
#   -h, --help          Show this help

use strict;
use warnings;
use Getopt::Long;
use Time::HiRes qw(time);
use File::Basename;
use File::Spec;

my $timeout    = 60;
my $verbose    = 0;
my $help       = 0;
my $use_hints  = 0;
my $model      = 'qwen2.5:7b';
my $candidates = 3;
my $pdf_dir    = '';

GetOptions(
    'timeout|t=i'    => \$timeout,
    'verbose|v'      => \$verbose,
    'help|h'         => \$help,
    'hints'          => \$use_hints,
    'model=s'        => \$model,
    'candidates|n=i' => \$candidates,
    'pdf-dir=s'      => \$pdf_dir,
) or usage();
usage() if $help;

my $dir = shift @ARGV || File::Spec->catdir(dirname(__FILE__), 'WSJ Crosswords');
die "Directory '$dir' not found\n" unless -d $dir;

my $solver = File::Spec->catfile(dirname(__FILE__), 'solve.pl');
die "Solver not found at '$solver'\n" unless -f $solver;

my $get_hints = File::Spec->catfile(dirname(__FILE__), 'get_hints.py');
if ($use_hints && !-f $get_hints) {
    die "get_hints.py not found at '$get_hints' (required for --hints)\n";
}

# Determine PDF directory for hint generation
if ($use_hints && !$pdf_dir) {
    $pdf_dir = $dir;  # assume PDFs are in same directory as .txt files
}

# Find all .txt grid files (skip _solved.txt files)
opendir my $dh, $dir or die "Cannot open $dir: $!\n";
my @puzzles = sort grep { /\.txt$/ && !/_(solved|solution)\.txt$/ } readdir $dh;
closedir $dh;

die "No .txt puzzle files found in $dir\n" unless @puzzles;

printf "Solving %d puzzles in %s (timeout: %ds%s)\n\n",
    scalar @puzzles, $dir, $timeout,
    $use_hints ? ", with LLM hints via $model" : "";

my $solved   = 0;
my $failed   = 0;
my $timed_out = 0;
my $errors   = 0;
my $total_time = 0;
my @failures;

for my $i (0 .. $#puzzles) {
    my $file = $puzzles[$i];
    my $path = File::Spec->catfile($dir, $file);

    my $base = $file;
    $base =~ s/\.txt$//;
    my $out_path = File::Spec->catfile($dir, "${base}_solved.txt");

    printf "[%3d/%3d] %-45s ", $i + 1, scalar @puzzles, $file;

    my $t0 = time();

    # Generate hints if requested
    my $hints_file = '';
    if ($use_hints) {
        my $pdf_base = $base;
        my $pdf_path = File::Spec->catfile($pdf_dir, "${pdf_base}.pdf");

        if (-f $pdf_path) {
            $hints_file = File::Spec->catfile($dir, "${base}.hints");

            # Only regenerate if hints file doesn't exist
            unless (-f $hints_file) {
                my @cmd = ('python3', $get_hints, $pdf_path,
                           '-o', $hints_file,
                           '-m', $model,
                           '-n', $candidates,
                           '--grid', $path);
                my $hint_out = `@cmd 2>&1`;
                my $hint_rc = $? >> 8;
                if ($hint_rc != 0) {
                    print "HINT_ERR " if $verbose;
                    $hints_file = '';  # proceed without hints
                }
            }
        } else {
            # No PDF found, solve without hints
            printf "(no PDF) " if $verbose;
        }
    }

    # Run solver with timeout using fork/exec for clean process control
    my $output = '';
    my $timed_out_flag = 0;

    my $pid = open(my $pipe, '-|');
    if (!defined $pid) {
        printf "ERROR  (fork failed)\n";
        $errors++;
        push @failures, "$file (fork failed: $!)";
        next;
    }

    if ($pid == 0) {
        # Child: exec the solver
        my @cmd = ('perl', $solver, $path);
        push @cmd, "--hints=$hints_file" if $hints_file && -f $hints_file;
        exec(@cmd) or exit(127);
    }

    # Parent: read with timeout
    eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm($timeout);
        local $/;
        $output = <$pipe>;
        alarm(0);
    };

    if ($@ && $@ =~ /TIMEOUT/) {
        $timed_out_flag = 1;
        kill('TERM', $pid);
        # Also kill any grandchildren in the process group
        kill('TERM', -$pid) if $pid;
        close($pipe);
        waitpid($pid, 0);
    } else {
        close($pipe);
    }

    my $elapsed = time() - $t0;
    $total_time += $elapsed;
    my $exit_code = $timed_out_flag ? -1 : ($? >> 8);

    if ($timed_out_flag) {
        printf "TIMEOUT  (%5.1fs)\n", $elapsed;
        $timed_out++;
        push @failures, "$file (timeout after ${timeout}s)";
    } elsif ($exit_code != 0) {
        printf "FAIL     (%5.1fs)\n", $elapsed;
        $failed++;
        my $reason = $output ? (split /\n/, $output)[0] : "exit code $exit_code";
        push @failures, "$file ($reason)";
        if ($verbose) {
            print "  $output\n";
        }
    } elsif ($output =~ /No solution found/) {
        printf "NOSOL    (%5.1fs)\n", $elapsed;
        $failed++;
        push @failures, "$file (no solution found)";
    } else {
        # Write solution
        open my $fh, '>', $out_path or do {
            printf "ERROR writing output\n";
            $errors++;
            push @failures, "$file (write error: $!)";
            next;
        };
        print $fh $output;
        close $fh;

        # Count grid dimensions from output
        my @lines = grep { /^[A-Z#]+$/ } split /\n/, $output;
        my $dims = @lines ? sprintf("%dx%d", scalar @lines, length($lines[0])) : "?";

        printf "OK  %s (%5.1fs)\n", $dims, $elapsed;
        $solved++;

        if ($verbose) {
            print "  $output\n";
        }
    }
}

# Summary
print  "\n" . "=" x 60 . "\n";
printf "RESULTS: %d solved, %d failed, %d timeout, %d errors\n",
    $solved, $failed, $timed_out, $errors;
printf "TOTAL:   %d puzzles in %.1f seconds (avg %.1fs/puzzle)\n",
    scalar @puzzles, $total_time,
    @puzzles ? $total_time / scalar @puzzles : 0;

if (@failures) {
    print "\nFailed puzzles:\n";
    print "  $_\n" for @failures;
}

exit($solved == scalar @puzzles ? 0 : 1);

sub usage {
    print STDERR <<'END';
Usage: perl test_all.pl [options] [directory]

Options:
  -t, --timeout N     Per-puzzle timeout in seconds (default: 60)
  --hints             Generate LLM hints via ollama before solving
  --model MODEL       Ollama model for hints (default: qwen2.5:7b)
  --candidates N      Candidates per clue (default: 3)
  --pdf-dir DIR       Directory with source PDFs (default: same as puzzle dir)
  -v, --verbose       Show solver output for each puzzle
  -h, --help          Show this help

Default directory: WSJ Crosswords/ (relative to this script)

Example:
  perl test_all.pl --hints --timeout=90 "WSJ Crosswords/"
END
    exit 1;
}
