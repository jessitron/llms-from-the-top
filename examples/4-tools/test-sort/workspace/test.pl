#!/usr/bin/env perl
use strict;
use warnings;

open(my $in, '<', 'arrays.txt') or die $!;
my @expected = map { chomp; join(' ', sort { $a <=> $b } split ' ') } <$in>;
close $in;

my @actual = split /\n/, `perl sort.pl < arrays.txt`;

my $pass = 0;
for my $i (0 .. $#expected) {
  my $got = $actual[$i] // '';
  my $ok = $got eq $expected[$i];
  $pass++ if $ok;
  print(($ok ? "PASS" : "FAIL") . " line " . ($i + 1) . ": expected [$expected[$i]] got [$got]\n");
}
print "\n$pass/" . scalar(@expected) . " lines correct\n";
exit($pass == @expected ? 0 : 1);
