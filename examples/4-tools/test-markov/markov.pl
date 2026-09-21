#!/usr/bin/env perl
use strict;
use warnings;

my %chain;
my @words = split /\s+/, join ' ', <>;
push @{$chain{$words[$_]}}, $words[$_+1] for 0..$#words-1;

my $word = $words[rand @words];
print "$word " for 1..50;
print "\n";

