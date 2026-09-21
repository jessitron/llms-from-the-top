#!/usr/bin/env perl
use strict;
use warnings;

sub partition {
  my ($arr, $lo, $hi) = @_;
  my $pivot = $arr->[int(($lo + $hi) / 2)];
  my $i = $lo - 1;
  my $j = $hi + 1;
  while (1) {
    do { $i++ } while ($arr->[$i] < $pivot);
    do { $j-- } while ($arr->[$j] > $pivot);
    return $j if $i >= $j;
    @{$arr}[$i, $j] = @{$arr}[$j, $i];
  }
}

sub quicksort {
  my ($arr, $lo, $hi) = @_;
  if ($lo < $hi) {
    my $p = partition($arr, $lo, $hi);
    quicksort($arr, $lo, $p - 1);
    quicksort($arr, $p + 1, $hi);
  }
}

while (my $line = <>) {
  chomp $line;
  my @a = split ' ', $line;
  quicksort(\@a, 0, $#a);
  print "@a\n";
}
