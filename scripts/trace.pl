#! /usr/bin/perl
#
# Copyright © 2017 Intel Corporation
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice (including the next
# paragraph) shall be included in all copies or substantial portions of the
# Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#

use strict;
use warnings;
use 5.010;

my $gid = 0;
my (%db, %queue, %submit, %notify, %rings, %ctxdb, %ringmap, %reqwait);
my @freqs;

my $max_items = 3000;
my $width_us = 32000;
my $correct_durations = 0;
my %ignore_ring;
my %skip_box;
my $html = 0;
my $trace = 0;
my $avg_delay_stats = 0;
my $squash_context_id = 0;
my $gpu_timeline = 0;

my @args;

sub arg_help
{
	return unless scalar(@_);

	if ($_[0] eq '--help' or $_[0] eq '-h') {
		shift @_;
print <<ENDHELP;
Notes:

   The tool parse the output generated by the 'perf script' command after the
   correct set of i915 tracepoints have been collected via perf record.

   To collect the data:

	./trace.pl --trace [command-to-be-profiled]

   The above will invoke perf record, or alternatively it can be done directly:

	perf record -a -c 1 -e i915:intel_gpu_freq_change, \
			       i915:i915_request_add, \
			       i915:i915_request_submit, \
			       i915:i915_request_in, \
			       i915:i915_request_out, \
			       i915:intel_engine_notify, \
			       i915:i915_request_wait_begin, \
			       i915:i915_request_wait_end \
			       [command-to-be-profiled]

   Then create the log file with:

	perf script >trace.log

   This file in turn should be piped into this tool which will generate some
   statistics out of it, or if --html was given HTML output.

   HTML can be viewed from a directory containing the 'vis' JavaScript module.
   On Ubuntu this can be installed like this:

	apt-get install npm
	npm install vis

Usage:
   trace.pl <options> <input-file >output-file

      --help / -h			This help text
      --max-items=num / -m num		Maximum number of boxes to put on the
					timeline. More boxes means more work for
					the JavaScript engine in the browser.
      --zoom-width-ms=ms / -z ms	Width of the initial timeline zoom
      --split-requests / -s		Try to split out request which were
					submitted together due coalescing in the
					driver. May not be 100% accurate and may
					influence the per-engine statistics so
					use with care.
      --ignore-ring=id / -i id		Ignore ring with the numerical id when
					parsing the log (enum intel_engine_id).
					Can be given multiple times.
      --skip-box=name / -x name		Do not put a certain type of a box on
					the timeline. One of: queue, ready,
					execute and ctxsave.
					Can be given multiple times.
      --html				Generate HTML output.
      --trace cmd			Trace the following command.
      --avg-delay-stats			Print average delay stats.
      --squash-ctx-id			Squash context id by substracting engine
					id from ctx id.
      --gpu-timeline			Draw overall GPU busy timeline.
ENDHELP

		exit 0;
	}

	return @_;
}

sub arg_html
{
	return unless scalar(@_);

	if ($_[0] eq '--html') {
		shift @_;
		$html = 1;
	}

	return @_;
}

sub arg_avg_delay_stats
{
	return unless scalar(@_);

	if ($_[0] eq '--avg-delay-stats') {
		shift @_;
		$avg_delay_stats = 1;
	}

	return @_;
}

sub arg_squash_ctx_id
{
	return unless scalar(@_);

	if ($_[0] eq '--squash-ctx-id') {
		shift @_;
		$squash_context_id = 1;
	}

	return @_;
}

sub arg_gpu_timeline
{
	return unless scalar(@_);

	if ($_[0] eq '--gpu-timeline') {
		shift @_;
		$gpu_timeline = 1;
	}

	return @_;
}

sub arg_trace
{
	my @events = ( 'i915:intel_gpu_freq_change',
		       'i915:i915_request_add',
		       'i915:i915_request_submit',
		       'i915:i915_request_in',
		       'i915:i915_request_out',
		       'i915:intel_engine_notify',
		       'i915:i915_request_wait_begin',
		       'i915:i915_request_wait_end' );

	return unless scalar(@_);

	if ($_[0] eq '--trace') {
		shift @_;

		unshift @_, join(',', @events);
		unshift @_, ('perf', 'record', '-a', '-c', '1', '-q', '-e');

		exec @_;
	}

	return @_;
}

sub arg_max_items
{
	my $val;

	return unless scalar(@_);

	if ($_[0] eq '--max-items' or $_[0] eq '-m') {
		shift @_;
		$val = shift @_;
	} elsif ($_[0] =~ /--max-items=(\d+)/) {
		shift @_;
		$val = $1;
	}

	$max_items = int($val) if defined $val;

	return @_;
}

sub arg_zoom_width
{
	my $val;

	return unless scalar(@_);

	if ($_[0] eq '--zoom-width-ms' or $_[0] eq '-z') {
		shift @_;
		$val = shift @_;
	} elsif ($_[0] =~ /--zoom-width-ms=(\d+)/) {
		shift @_;
		$val = $1;
	}

	$width_us = int($val) * 1000 if defined $val;

	return @_;
}

sub arg_split_requests
{
	return unless scalar(@_);

	if ($_[0] eq '--split-requests' or $_[0] eq '-s') {
		shift @_;
		$correct_durations = 1;
	}

	return @_;
}

sub arg_ignore_ring
{
	my $val;

	return unless scalar(@_);

	if ($_[0] eq '--ignore-ring' or $_[0] eq '-i') {
		shift @_;
		$val = shift @_;
	} elsif ($_[0] =~ /--ignore-ring=(\d+)/) {
		shift @_;
		$val = $1;
	}

	$ignore_ring{$val} = 1 if defined $val;

	return @_;
}

sub arg_skip_box
{
	my $val;

	return unless scalar(@_);

	if ($_[0] eq '--skip-box' or $_[0] eq '-x') {
		shift @_;
		$val = shift @_;
	} elsif ($_[0] =~ /--skip-box=(\d+)/) {
		shift @_;
		$val = $1;
	}

	$skip_box{$val} = 1 if defined $val;

	return @_;
}

@args = @ARGV;
while (@args) {
	my $left = scalar(@args);

	@args = arg_help(@args);
	@args = arg_html(@args);
	@args = arg_avg_delay_stats(@args);
	@args = arg_squash_ctx_id(@args);
	@args = arg_gpu_timeline(@args);
	@args = arg_trace(@args);
	@args = arg_max_items(@args);
	@args = arg_zoom_width(@args);
	@args = arg_split_requests(@args);
	@args = arg_ignore_ring(@args);
	@args = arg_skip_box(@args);

	last if $left == scalar(@args);
}

die if scalar(@args);

@ARGV = @args;

sub db_key
{
	my ($ring, $ctx, $seqno) = @_;

	return $ring . '/' . $ctx . '/' . $seqno;
}

sub global_key
{
	my ($ring, $seqno) = @_;

	return $ring . '/' . $seqno;
}

sub sanitize_ctx
{
	my ($ctx, $ring) = @_;

	$ctx = $ctx - $ring if $squash_context_id;

	if (exists $ctxdb{$ctx}) {
		return $ctx . '.' . $ctxdb{$ctx};
	} else {
		return $ctx;
	}
}

sub ts
{
	my ($us) = @_;
	my ($d, $h, $m, $s);

	$s = int($us / 1000000);
	$us = $us % 1000000;

	$m = int($s / 60);
	$s = $s % 60;

	$h = int($m / 60);
	$m = $m % 60;

	$d = 1 + int($h / 24);
	$h = $h % 24;

	return sprintf('2017-01-%02u %02u:%02u:%02u.%06u',
		       int($d), int($h), int($m), int($s), int($us));
}

# Main input loop - parse lines and build the internal representation of the
# trace using a hash of requests and some auxilliary data structures.
my $prev_freq = 0;
my $prev_freq_ts = 0;
while (<>) {
	my @fields;
	my $tp_name;
	my %tp;
	my ($time, $ctx, $ring, $seqno, $orig_ctx, $key);

	chomp;
	@fields = split ' ';

	chop $fields[3];
	$time = int($fields[3] * 1000000.0 + 0.5);

	$tp_name = $fields[4];

	splice @fields, 0, 5;

	foreach my $f (@fields) {
		my ($k, $v);

		next unless $f =~ m/=/;
		($k, $v) = ($`, $');
		$k = 'global' if $k eq 'global_seqno';
		chop $v if substr($v, -1, 1) eq ',';
		$tp{$k} = $v;
	}

	next if exists $tp{'ring'} and exists $ignore_ring{$tp{'ring'}};

	if (exists $tp{'ring'} and exists $tp{'seqno'}) {
		$ring = $tp{'ring'};
		$seqno = $tp{'seqno'};

		if (exists $tp{'ctx'}) {
			$ctx = $tp{'ctx'};
			$orig_ctx = $ctx;
			$ctx = sanitize_ctx($ctx, $ring);
			$key = db_key($ring, $ctx, $seqno);
		}
	}

	if ($tp_name eq 'i915:i915_request_wait_begin:') {
		my %rw;

		next if exists $reqwait{$key};

		$rw{'key'} = $key;
		$rw{'ring'} = $ring;
		$rw{'seqno'} = $seqno;
		$rw{'ctx'} = $ctx;
		$rw{'start'} = $time;
		$reqwait{$key} = \%rw;
	} elsif ($tp_name eq 'i915:i915_request_wait_end:') {
		next unless exists $reqwait{$key};

		$reqwait{$key}->{'end'} = $time;
	} elsif ($tp_name eq 'i915:i915_request_add:') {
		if (exists $queue{$key}) {
			$ctxdb{$orig_ctx}++;
			$ctx = sanitize_ctx($orig_ctx, $ring);
			$key = db_key($ring, $ctx, $seqno);
		}

		$queue{$key} = $time;
	} elsif ($tp_name eq 'i915:i915_request_submit:') {
		die if exists $submit{$key};
		die unless exists $queue{$key};

		$submit{$key} = $time;
	} elsif ($tp_name eq 'i915:i915_request_in:') {
		my %req;

		die if exists $db{$key};
		die unless exists $queue{$key};
		die unless exists $submit{$key};

		$req{'start'} = $time;
		$req{'ring'} = $ring;
		$req{'seqno'} = $seqno;
		$req{'ctx'} = $ctx;
		$req{'name'} = $ctx . '/' . $seqno;
		$req{'global'} = $tp{'global'};
		$req{'port'} = $tp{'port'};
		$req{'queue'} = $queue{$key};
		$req{'submit-delay'} = $submit{$key} - $queue{$key};
		$req{'execute-delay'} = $req{'start'} - $submit{$key};
		$rings{$ring} = $gid++ unless exists $rings{$ring};
		$ringmap{$rings{$ring}} = $ring;
		$db{$key} = \%req;
	} elsif ($tp_name eq 'i915:i915_request_out:') {
		my $gkey = global_key($ring, $tp{'global'});

		die unless exists $db{$key};
		die unless exists $db{$key}->{'start'};
		die if exists $db{$key}->{'end'};

		$db{$key}->{'end'} = $time;
		if (exists $notify{$gkey}) {
			$db{$key}->{'notify'} = $notify{$gkey};
		} else {
			# No notify so far. Maybe it will arrive later which
			# will be handled in the sanitation loop below.
			$db{$key}->{'notify'} = $db{$key}->{'end'};
			$db{$key}->{'no-notify'} = 1;
		}
		$db{$key}->{'duration'} = $db{$key}->{'notify'} - $db{$key}->{'start'};
		$db{$key}->{'context-complete-delay'} = $db{$key}->{'end'} - $db{$key}->{'notify'};
	} elsif ($tp_name eq 'i915:intel_engine_notify:') {
		$notify{global_key($ring, $seqno)} = $time;
	} elsif ($tp_name eq 'i915:intel_gpu_freq_change:') {
		push @freqs, [$prev_freq_ts, $time, $prev_freq] if $prev_freq;
		$prev_freq_ts = $time;
		$prev_freq = $tp{'new_freq'};
	}
}

# Sanitation pass to fixup up out of order notify and context complete, and to
# fine the largest seqno to be used for timeline sorting purposes.
my $max_seqno = 0;
foreach my $key (keys %db) {
	my $gkey = global_key($db{$key}->{'ring'}, $db{$key}->{'global'});

	die unless exists $db{$key}->{'start'};

	$max_seqno = $db{$key}->{'seqno'} if $db{$key}->{'seqno'} > $max_seqno;

	unless (exists $db{$key}->{'end'}) {
		# Context complete not received.
		if (exists $notify{$gkey}) {
			# No context complete due req merging - use notify.
			$db{$key}->{'notify'} = $notify{$gkey};
			$db{$key}->{'end'} = $db{$key}->{'notify'};
			$db{$key}->{'no-end'} = 1;
		} else {
			# No notify and no context complete - mark it.
			$db{$key}->{'no-end'} = 1;
			$db{$key}->{'end'} = $db{$key}->{'start'} + 999;
			$db{$key}->{'notify'} = $db{$key}->{'end'};
			$db{$key}->{'incomplete'} = 1;
		}

		$db{$key}->{'duration'} = $db{$key}->{'notify'} - $db{$key}->{'start'};
		$db{$key}->{'context-complete-delay'} = $db{$key}->{'end'} - $db{$key}->{'notify'};
	} else {
		# Notify arrived after context complete.
		if (exists $db{$key}->{'no-notify'} and exists $notify{$gkey}) {
			delete $db{$key}->{'no-notify'};
			$db{$key}->{'notify'} = $notify{$gkey};
			$db{$key}->{'duration'} = $db{$key}->{'notify'} - $db{$key}->{'start'};
			$db{$key}->{'context-complete-delay'} = $db{$key}->{'end'} - $db{$key}->{'notify'};
		}
	}
}

# Fix up incompletes
my $key_count = scalar(keys %db);
foreach my $key (keys %db) {
	next unless exists $db{$key}->{'incomplete'};

	# End the incomplete batch at the time next one starts
	my $ring = $db{$key}->{'ring'};
	my $ctx = $db{$key}->{'ctx'};
	my $seqno = $db{$key}->{'seqno'};
	my $next_key;
	my $i = 1;

	do {
		$next_key = db_key($ring, $ctx, $seqno + $i);
		$i++;
	} until ((exists $db{$next_key} and not exists $db{$next_key}->{'incomplete'})
		 or $i > $key_count);  # ugly stop hack

	if (exists $db{$next_key}) {
		$db{$key}->{'notify'} = $db{$next_key}->{'end'};
		$db{$key}->{'end'} = $db{$key}->{'notify'};
		$db{$key}->{'duration'} = $db{$key}->{'notify'} - $db{$key}->{'start'};
		$db{$key}->{'context-complete-delay'} = $db{$key}->{'end'} - $db{$key}->{'notify'};
	}
}

# GPU time accounting
my (%running, %runnable, %queued, %batch_avg, %batch_total_avg, %batch_count);
my (%submit_avg, %execute_avg, %ctxsave_avg);
my $last_ts = 0;
my $first_ts;

my @sorted_keys = sort {$db{$a}->{'start'} <=> $db{$b}->{'start'}} keys %db;
my $re_sort = 0;

die "Database changed size?!" unless scalar(@sorted_keys) == $key_count;

foreach my $key (@sorted_keys) {
	my $ring = $db{$key}->{'ring'};
	my $end = $db{$key}->{'end'};

	$first_ts = $db{$key}->{'queue'} if not defined $first_ts or $db{$key}->{'queue'} < $first_ts;
	$last_ts = $end if $end > $last_ts;

	$running{$ring} += $end - $db{$key}->{'start'} unless exists $db{$key}->{'no-end'};
	$runnable{$ring} += $db{$key}->{'execute-delay'};
	$queued{$ring} += $db{$key}->{'start'} - $db{$key}->{'execute-delay'} - $db{$key}->{'queue'};

	$batch_count{$ring}++;

	# correct duration of merged batches
	if ($correct_durations and exists $db{$key}->{'no-end'}) {
		my $start = $db{$key}->{'start'};
		my $ctx = $db{$key}->{'ctx'};
		my $seqno = $db{$key}->{'seqno'};
		my $next_key;
		my $i = 1;

		do {
			$next_key = db_key($ring, $ctx, $seqno + $i);
			$i++;
		} until (exists $db{$next_key} or $i > $key_count);  # ugly stop hack

		# 20us tolerance
		if (exists $db{$next_key} and $db{$next_key}->{'start'} < $start + 20) {
			$re_sort = 1;
			$db{$next_key}->{'start'} = $start + $db{$key}->{'duration'};
			$db{$next_key}->{'start'} = $db{$next_key}->{'end'} if $db{$next_key}->{'start'} > $db{$next_key}->{'end'};
			$db{$next_key}->{'duration'} = $db{$next_key}->{'notify'} - $db{$next_key}->{'start'};
			$end = $db{$key}->{'notify'};
			die if $db{$next_key}->{'start'} > $db{$next_key}->{'end'};
		}
		die if $db{$key}->{'start'} > $db{$key}->{'end'};
	}
	$batch_avg{$ring} += $db{$key}->{'duration'};
	$batch_total_avg{$ring} += $end - $db{$key}->{'start'};

	$submit_avg{$ring} += $db{$key}->{'submit-delay'};
	$execute_avg{$ring} += $db{$key}->{'execute-delay'};
	$ctxsave_avg{$ring} += $db{$key}->{'end'} - $db{$key}->{'notify'};
}

@sorted_keys = sort {$db{$a}->{'start'} <=> $db{$b}->{'start'}} keys %db if $re_sort;

foreach my $ring (keys %batch_avg) {
	$batch_avg{$ring} /= $batch_count{$ring};
	$batch_total_avg{$ring} /= $batch_count{$ring};
	$submit_avg{$ring} /= $batch_count{$ring};
	$execute_avg{$ring} /= $batch_count{$ring};
	$ctxsave_avg{$ring} /= $batch_count{$ring};
}

# Calculate engine idle time
my %flat_busy;
foreach my $gid (sort keys %rings) {
	my $ring = $ringmap{$rings{$gid}};
	my (@s_, @e_);

	# Extract all GPU busy intervals and sort them.
	foreach my $key (@sorted_keys) {
		next unless $db{$key}->{'ring'} == $ring;
		push @s_, $db{$key}->{'start'};
		push @e_, $db{$key}->{'end'};
		die if $db{$key}->{'start'} > $db{$key}->{'end'};
	}

	die unless $#s_ == $#e_;

	# Flatten the intervals.
	for my $i (1..$#s_) {
		last if $i >= @s_; # End of array.
		die if $e_[$i] < $s_[$i];
		if ($s_[$i] <= $e_[$i - 1]) {
			# Current entry overlaps with the previous one. We need
			# to merge end of the previous interval from the list
			# with the start of the current one.
			if ($e_[$i] >= $e_[$i - 1]) {
				splice @e_, $i - 1, 1;
			} else {
				splice @e_, $i, 1;
			}
			splice @s_, $i, 1;
			# Continue with the same element when list got squashed.
			redo;
		}
	}

	# Add up all busy times.
	my $total = 0;
	for my $i (0..$#s_) {
		die if $e_[$i] < $s_[$i];

		$total = $total + ($e_[$i] - $s_[$i]);
	}

	$flat_busy{$ring} = $total;
}

# Calculate overall GPU idle time
my @gpu_intervals;
my (@s_, @e_);

# Extract all GPU busy intervals and sort them.
foreach my $key (@sorted_keys) {
	push @s_, $db{$key}->{'start'};
	push @e_, $db{$key}->{'end'};
	die if $db{$key}->{'start'} > $db{$key}->{'end'};
}

die unless $#s_ == $#e_;

# Flatten the intervals (copy & paste of the flattening loop above)
for my $i (1..$#s_) {
	last if $i >= @s_;
	die if $e_[$i] < $s_[$i];
	die if $s_[$i] < $s_[$i - 1];
	if ($s_[$i] <= $e_[$i - 1]) {
		if ($e_[$i] >= $e_[$i - 1]) {
			splice @e_, $i - 1, 1;
		} else {
			splice @e_, $i, 1;
		}
		splice @s_, $i, 1;
		redo;
	}
}

# Add up all busy times.
my $total = 0;
for my $i (0..$#s_) {
	die if $e_[$i] < $s_[$i];

	$total = $total + ($e_[$i] - $s_[$i]);
}

# Generate data for the GPU timeline if requested
if ($gpu_timeline) {
	for my $i (0..$#s_) {
		push @gpu_intervals, [ $s_[$i], $e_[$i] ];
	}
}

$flat_busy{'gpu-busy'} = $total / ($last_ts - $first_ts) * 100.0;
$flat_busy{'gpu-idle'} = (1.0 - $total / ($last_ts - $first_ts)) * 100.0;

# Add up all request waits per engine
my %reqw;
foreach my $key (keys %reqwait) {
	$reqw{$reqwait{$key}->{'ring'}} += $reqwait{$key}->{'end'} - $reqwait{$key}->{'start'};
}

say sprintf('GPU: %.2f%% idle, %.2f%% busy',
	     $flat_busy{'gpu-idle'}, $flat_busy{'gpu-busy'}) unless $html;

print <<ENDHTML if $html;
<!DOCTYPE HTML>
<html>
<head>
  <title>i915 GT timeline</title>

  <style type="text/css">
    body, html {
      font-family: sans-serif;
    }
  </style>

  <script src="node_modules/vis/dist/vis.js"></script>
  <link href="node_modules/vis//dist/vis.css" rel="stylesheet" type="text/css" />
</head>
<body>

<button onclick="toggleStackSubgroups()">Toggle stacking</button>

<p>
pink = requests executing on the GPU<br>
grey = runnable requests waiting for a slot on GPU<br>
blue = requests waiting on fences and dependencies before they are runnable<br>
</p>
<p>
Boxes are in format 'ctx-id/seqno'.
</p>
<p>
Use Ctrl+scroll-action to zoom-in/out and scroll-action or dragging to move around the timeline.
</p>
<p>
<b>GPU idle: $flat_busy{'gpu-idle'}%</b>
<br>
<b>GPU busy: $flat_busy{'gpu-busy'}%</b>
</p>
<div id="visualization"></div>

<script type="text/javascript">
  var container = document.getElementById('visualization');

  var groups = new vis.DataSet([
ENDHTML

#   var groups = new vis.DataSet([
# 	{id: 1, content: 'g0'},
# 	{id: 2, content: 'g1'}
#   ]);

sub html_stats
{
	my ($stats, $group, $id) = @_;
	my $name;

	$name = 'Ring' . $group;
	$name .= '<br><small><br>';
	$name .= sprintf('%.2f', $stats->{'idle'}) . '% idle<br><br>';
	$name .= sprintf('%.2f', $stats->{'busy'}) . '% busy<br>';
	$name .= sprintf('%.2f', $stats->{'runnable'}) . '% runnable<br>';
	$name .= sprintf('%.2f', $stats->{'queued'}) . '% queued<br><br>';
	$name .= sprintf('%.2f', $stats->{'wait'}) . '% wait<br><br>';
	$name .= $stats->{'count'} . ' batches<br>';
	$name .= sprintf('%.2f', $stats->{'avg'}) . 'us avg batch<br>';
	$name .= sprintf('%.2f', $stats->{'total-avg'}) . 'us avg engine batch<br>';
	$name .= '</small>';

	print "\t{id: $id, content: '$name'},\n";
}

sub stdio_stats
{
	my ($stats, $group, $id) = @_;
	my $str;

	$str = 'Ring' . $group . ': ';
	$str .= $stats->{'count'} . ' batches, ';
	$str .= sprintf('%.2f (%.2f) avg batch us, ', $stats->{'avg'}, $stats->{'total-avg'});
	$str .= sprintf('%.2f', $stats->{'idle'}) . '% idle, ';
	$str .= sprintf('%.2f', $stats->{'busy'}) . '% busy, ';
	$str .= sprintf('%.2f', $stats->{'runnable'}) . '% runnable, ';
	$str .= sprintf('%.2f', $stats->{'queued'}) . '% queued, ';
	$str .= sprintf('%.2f', $stats->{'wait'}) . '% wait';
	if ($avg_delay_stats) {
		$str .= ', submit/execute/save-avg=(';
		$str .= sprintf('%.2f/%.2f/%.2f)', $stats->{'submit'}, $stats->{'execute'}, $stats->{'save'});
	}

	say $str;
}

print "\t{id: 0, content: 'Freq'},\n" if $html;
print "\t{id: 1, content: 'GPU'},\n" if $gpu_timeline;

my $engine_start_id = $gpu_timeline ? 2 : 1;

foreach my $group (sort keys %rings) {
	my $name;
	my $ring = $ringmap{$rings{$group}};
	my $id = $engine_start_id + $rings{$group};
	my $elapsed = $last_ts - $first_ts;
	my %stats;

	$stats{'idle'} = (1.0 - $flat_busy{$ring} / $elapsed) * 100.0;
	$stats{'busy'} = $running{$ring} / $elapsed * 100.0;
	$stats{'runnable'} = $runnable{$ring} / $elapsed * 100.0;
	$stats{'queued'} = $queued{$ring} / $elapsed * 100.0;
	$reqw{$ring} = 0 unless exists $reqw{$ring};
	$stats{'wait'} = $reqw{$ring} / $elapsed * 100.0;
	$stats{'count'} = $batch_count{$ring};
	$stats{'avg'} = $batch_avg{$ring};
	$stats{'total-avg'} = $batch_total_avg{$ring};
	$stats{'submit'} = $submit_avg{$ring};
	$stats{'execute'} = $execute_avg{$ring};
	$stats{'save'} = $ctxsave_avg{$ring};

	if ($html) {
		html_stats(\%stats, $group, $id);
	} else {
		stdio_stats(\%stats, $group, $id);
	}
}

exit 0 unless $html;

print <<ENDHTML;
  ]);

  var items = new vis.DataSet([
ENDHTML

my $i = 0;
foreach my $key (sort {$db{$a}->{'queue'} <=> $db{$b}->{'queue'}} keys %db) {
	my ($name, $ctx, $seqno) = ($db{$key}->{'name'}, $db{$key}->{'ctx'}, $db{$key}->{'seqno'});
	my ($queue, $start, $notify, $end) = ($db{$key}->{'queue'}, $db{$key}->{'start'}, $db{$key}->{'notify'}, $db{$key}->{'end'});
	my $submit = $queue + $db{$key}->{'submit-delay'};
	my ($content, $style);
	my $group = $engine_start_id + $rings{$db{$key}->{'ring'}};
	my $type = ' type: \'range\',';
	my $startend;
	my $skey;

	# submit to execute
	unless (exists $skip_box{'queue'}) {
		$skey = 2 * $max_seqno * $ctx + 2 * $seqno;
		$style = 'color: black; background-color: lightblue;';
		$content = "$name<br>$db{$key}->{'submit-delay'}us <small>($db{$key}->{'execute-delay'}us)</small>";
		$startend = 'start: \'' . ts($queue) . '\', end: \'' . ts($submit) . '\'';
		print "\t{id: $i, key: $skey, $type group: $group, subgroup: 1, subgroupOrder: 1, content: '$content', $startend, style: \'$style\'},\n";
		$i++;
	}

	# execute to start
	unless (exists $skip_box{'ready'}) {
		$skey = 2 * $max_seqno * $ctx + 2 * $seqno + 1;
		$style = 'color: black; background-color: lightgrey;';
		$content = "<small>$name<br>$db{$key}->{'execute-delay'}us</small>";
		$startend = 'start: \'' . ts($submit) . '\', end: \'' . ts($start) . '\'';
		print "\t{id: $i, key: $skey, $type group: $group, subgroup: 1, subgroupOrder: 2, content: '$content', $startend, style: \'$style\'},\n";
		$i++;
	}

	# start to user interrupt
	unless (exists $skip_box{'execute'}) {
		$skey = -2 * $max_seqno * $ctx - 2 * $seqno - 1;
		if (exists $db{$key}->{'incomplete'}) {
			$style = 'color: white; background-color: red;';
		} else {
			$style = 'color: black; background-color: pink;';
		}
		$content = "$name <small>$db{$key}->{'port'}</small>";
		$content .= ' <small><i>???</i></small> ' if exists $db{$key}->{'incomplete'};
		$content .= ' <small><i>++</i></small> ' if exists $db{$key}->{'no-end'};
		$content .= ' <small><i>+</i></small> ' if exists $db{$key}->{'no-notify'};
		$content .= "<br>$db{$key}->{'duration'}us <small>($db{$key}->{'context-complete-delay'}us)</small>";
		$startend = 'start: \'' . ts($start) . '\', end: \'' . ts($notify) . '\'';
		print "\t{id: $i, key: $skey, $type group: $group, subgroup: 2, subgroupOrder: 3, content: '$content', $startend, style: \'$style\'},\n";
		$i++;
	}

	# user interrupt to context complete
	unless (exists $skip_box{'ctxsave'}) {
		$skey = -2 * $max_seqno * $ctx - 2 * $seqno;
		$style = 'color: black; background-color: orange;';
		my $ctxsave = $db{$key}->{'end'} - $db{$key}->{'notify'};
		$content = "<small>$name<br>${ctxsave}us</small>";
		$content .= ' <small><i>???</i></small> ' if exists $db{$key}->{'incomplete'};
		$content .= ' <small><i>++</i></small> ' if exists $db{$key}->{'no-end'};
		$content .= ' <small><i>+</i></small> ' if exists $db{$key}->{'no-notify'};
		$startend = 'start: \'' . ts($notify) . '\', end: \'' . ts($end) . '\'';
		print "\t{id: $i, key: $skey, $type group: $group, subgroup: 2, subgroupOrder: 4, content: '$content', $startend, style: \'$style\'},\n";
		$i++;
	}

	$last_ts = $end;

	last if $i > $max_items;
}

foreach my $item (@freqs) {
	my ($start, $end, $freq) = @$item;
	my $startend;

	next if $start > $last_ts;

	$start = $first_ts if $start < $first_ts;
	$end = $last_ts if $end > $last_ts;
	$startend = 'start: \'' . ts($start) . '\', end: \'' . ts($end) . '\'';
	print "\t{id: $i, type: 'range', group: 0, content: '$freq', $startend},\n";
	$i++;
}

if ($gpu_timeline) {
	foreach my $item (@gpu_intervals) {
		my ($start, $end) = @$item;
		my $startend;

		next if $start > $last_ts;

		$start = $first_ts if $start < $first_ts;
		$end = $last_ts if $end > $last_ts;
		$startend = 'start: \'' . ts($start) . '\', end: \'' . ts($end) . '\'';
		print "\t{id: $i, type: 'range', group: 1, $startend},\n";
		$i++;
	}
}

my $end_ts = ts($first_ts + $width_us);
$first_ts = ts($first_ts);

print <<ENDHTML;
  ]);

  function customOrder (a, b) {
  // order by id
    return a.subgroupOrder - b.subgroupOrder;
  }

  // Configuration for the Timeline
  var options = { groupOrder: 'content',
		  horizontalScroll: true,
		  stack: true,
		  stackSubgroups: false,
		  zoomKey: 'ctrlKey',
		  orientation: 'top',
		  order: customOrder,
		  start: '$first_ts',
		  end: '$end_ts'};

  // Create a Timeline
  var timeline = new vis.Timeline(container, items, groups, options);

    function toggleStackSubgroups() {
        options.stackSubgroups = !options.stackSubgroups;
        timeline.setOptions(options);
    }
ENDHTML

print <<ENDHTML;
</script>
</body>
</html>
ENDHTML
