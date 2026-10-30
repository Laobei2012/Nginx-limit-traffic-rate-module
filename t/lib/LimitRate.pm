package LimitRate;

# Helpers shared by the timing tests of ngx_http_limit_traffic_rate_filter_module.
#
# Test::Nginx::Socket sends one request per test block and has no notion of
# elapsed time or parallel clients.  This module adds an optional "--- timing"
# section to a block:
#
#   --- timing eval
#   {
#       clients => [ { path => '/big.bin', headers => { 'X-Key' => 'a' } },
#                    { path => '/big.bin', headers => { 'X-Key' => 'b' } } ],
#       check   => sub { my ($res) = @_; ... Test::More assertions ... },
#   }
#
# After Test::Nginx has started nginx and run the block's normal request
# checks, all "clients" are started at the same moment (one forked process
# each, raw HTTP/1.0 over a socket) and "check" is called with an array
# reference of result hashes, in the order of "clients":
#
#   { status => 200, bytes => <body length>, elapsed => <seconds, float> }
#
# A client may set  delay => <seconds>  to start later than the others and
# hold => <seconds>  to close the connection after that long even if the
# response is not complete (bytes then counts what was received).
#
# repeat => N  sends N sequential requests (see fetch_sequence).
#
# mark => <bytes>  additionally records in "mark" the time at which that many
# bytes (headers included) had been received.
#
# Every client reads the response to EOF.
#
# Usage in a .t file (after "use Test::Nginx::Socket"):
#
#   use lib 't/lib';
#   use LimitRate;          # installs the hook
#
# and call  LimitRate::bytes_in_file($n)  to build a user_files body.
#
# Note: with several files in one "user_files" section, Test::Nginx adds a
# newline after each file's content, so a file followed by another one is
# one byte longer than requested; compare sizes with ">=".

use strict;
use warnings;

use IO::Socket::INET;
use IO::Select;
use POSIX ();
use Time::HiRes qw(time sleep);
use Test::More ();
use Test::Nginx::Util ();
use Test::Nginx::Socket ();

my $orig_helper;

# Dynamic module builds: when LTR_DYNAMIC_MODULE is set to the path of the
# built .so, every block gets "load_module <path>;" in its main_config,
# unless the block has a "--- no_load_module" section.
sub import {
    return if $orig_helper;
    if ($ENV{LTR_DYNAMIC_MODULE}) {
        Test::Nginx::Util::add_block_preprocessor(sub {
            my ($block) = @_;
            return if $block->can('no_load_module') && defined $block->no_load_module;
            my $mc = $block->main_config;
            $block->set_value('main_config',
                "load_module $ENV{LTR_DYNAMIC_MODULE};\n" . (defined $mc ? $mc : ''));
        });
    }
    $orig_helper = $Test::Nginx::Util::RunTestHelper;
    $Test::Nginx::Util::RunTestHelper = sub {
        my ($block, @rest) = @_;
        $orig_helper->($block, @rest);
        my $t = $block->can('timing') ? $block->timing : undef;
        run_timing($block, $t) if $t;
    };
}

# Fail if error.log shows a worker crash.  The message is written by the
# master when it reaps the worker, so give it a moment.
sub no_crash_in_log {
    my ($what) = @_;
    select(undef, undef, undef, 1.2);
    open my $fh, '<', $Test::Nginx::Util::ErrLogFile or die "error.log: $!";
    my $log = do { local $/; <$fh> };
    close $fh;
    Test::More::unlike($log, qr/exited on signal|segmentation fault/i,
                       $what || 'no worker crash in error.log');
}

# A body of exactly $n bytes (printable, so it is easy to write to a file).
sub bytes_in_file {
    my ($n) = @_;
    return 'x' x $n;
}

sub fetch {
    my ($spec) = @_;

    my $port = $Test::Nginx::Util::ServerPortForClient || 1984;
    my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1',
                                     PeerPort => $port,
                                     Proto    => 'tcp',
                                     Timeout  => 10)
        or return { status => 0, bytes => 0, elapsed => 0, error => "connect: $!" };

    my $hdrs = $spec->{headers} || {};
    my $req = "GET $spec->{path} HTTP/1.0\r\nHost: localhost\r\n"
            . join('', map { "$_: $hdrs->{$_}\r\n" } sort keys %$hdrs)
            . "\r\n";

    my $t0 = time();
    print $sock $req;

    my ($buf, $head, $got, $mark_at) = ('', '', 0, undef);
    # "hold" = give up reading (and close the connection) after that many
    # seconds; used to keep many connections open for a while.
    my $deadline = $t0 + ($spec->{hold} || $spec->{timeout} || 60);
    my $sel = IO::Select->new($sock);
    while (time() < $deadline) {
        next unless $sel->can_read(0.2);
        my $n = sysread($sock, $buf, 65536);
        last if !defined $n || $n == 0;
        $head .= $buf if length($head) < 4096;   # only the headers matter
        $got += $n;
        if (defined $spec->{mark} && !defined $mark_at && $got >= $spec->{mark}) {
            $mark_at = time() - $t0;
        }
    }
    my $elapsed = time() - $t0;

    my ($status) = $head =~ m{\AHTTP/\d\.\d (\d+)};
    my $hdr_end = index($head, "\r\n\r\n");
    my $body_bytes = $got - ($hdr_end >= 0 ? $hdr_end + 4 : 0);

    return { status => $status || 0, bytes => $body_bytes, elapsed => $elapsed,
             mark => $mark_at };
}

# repeat => N: N requests one after the other on new connections; the
# result is the sum of the bytes, the total elapsed time and the first
# status that is not 200 (or 200).
sub fetch_sequence {
    my ($spec) = @_;
    my ($status, $bytes, $err) = (200, 0, undef);
    my $t0 = time();
    for (1 .. $spec->{repeat}) {
        my $r = fetch($spec);
        $bytes += $r->{bytes};
        $status = $r->{status} if $r->{status} != 200 && $status == 200;
        $err ||= $r->{error};
    }
    return { status => $status, bytes => $bytes, elapsed => time() - $t0,
             error => $err };
}

sub fetch_parallel {
    my (@specs) = @_;

    my @kids;
    for my $i (0 .. $#specs) {
        pipe(my $rd, my $wr) or die "pipe: $!";
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            close $rd;
            # whatever happens, report something and leave without running
            # the parent's END blocks / Test::More cleanup
            eval {
                sleep($specs[$i]{delay}) if $specs[$i]{delay};
                my $r = $specs[$i]{repeat} ? fetch_sequence($specs[$i])
                                           : fetch($specs[$i]);
                print $wr join(' ', $r->{status}, $r->{bytes}, $r->{elapsed},
                               (defined $r->{mark} ? $r->{mark} : -1),
                               ($r->{error} || '')), "\n";
                1;
            } or do {
                my $e = $@ || 'unknown error';
                $e =~ s/\s+/ /g;
                print $wr "0 0 0 -1 $e\n";
            };
            close $wr;
            POSIX::_exit(0);
        }
        close $wr;
        push @kids, [ $pid, $rd ];
    }

    my @res;
    for my $k (@kids) {
        my ($pid, $rd) = @$k;
        my $line = <$rd>;
        close $rd;
        waitpid($pid, 0);
        my ($status, $bytes, $elapsed, $mark, $err) =
            split ' ', ($line || "0 0 0 -1 child-died"), 5;
        push @res, { status => $status, bytes => $bytes, elapsed => $elapsed,
                     mark => ($mark >= 0 ? $mark : undef), error => $err };
    }
    return \@res;
}

sub run_timing {
    my ($block, $t) = @_;
    my $res = fetch_parallel(@{ $t->{clients} });
    Test::More::diag(sprintf("timing: %s",
        join(', ', map { sprintf("%s/%d bytes/%.2fs", $_->{status}, $_->{bytes},
                                 $_->{elapsed}) } @$res)));

    $t->{check}->($res);
}

1;
