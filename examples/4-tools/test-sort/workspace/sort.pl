#!/usr/bin/env perl
use strict;
use warnings;

sub partition {
  my ($arr, $lo, $hi) = @_;
  my $pivot = $arr->[$hi];
  my $i = $lo - 1;
  for my $j ($lo .. $hi - 1) {
    if ($arr->[$j] < $pivot) {
      $i++;
      @{$arr}[$i, $j] = @{$arr}[$j, $i];
    }
  }
  @{$arr}[$i + 1, $hi] = @{$arr}[$hi, $i + 1];
  return $i + 1;
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
