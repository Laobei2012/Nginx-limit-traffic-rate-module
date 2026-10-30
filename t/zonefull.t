# A full shared memory zone: requests that do not fit are rejected with 503,
# the worker does not crash, and the zone recovers when the connections end.
#
# The smallest zone (32k) holds only a few dozen nodes for 1004-byte keys.
# 150 clients with distinct keys keep their downloads (at 1k/s) open at the
# same time, so most of them find the zone full (node allocation fails).
#
# The second test uses one key for 1200 clients: the node exists, but the
# per-request records no longer fit (request allocation fails; about 630
# fit).  The clients hold their connections for 10s so that they overlap
# even when starting 1200 processes is slow.

use lib 't/lib';
use Test::Nginx::Socket 'no_plan';
use LimitRate;

repeat_each(1);
worker_connections(4096);
run_tests();

__DATA__

=== TEST 1: tiny zone, many long distinct keys: 503, no crash, recovery
--- http_config
    limit_traffic_rate_zone tiny $http_x_key 32k;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate tiny 1k;
    }
--- user_files eval
">>> dl/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ map { { path => '/dl/f.bin', hold => 4,
                         headers => { 'X-Key' => sprintf('%04d', $_) . ('k' x 1000) } } }
                 1 .. 150 ],
    check => sub {
        my ($r) = @_;
        my $n503 = scalar grep { $_->{status} == 503 } @$r;
        my $n200 = scalar grep { $_->{status} == 200 } @$r;
        Test::More::cmp_ok($n200, '>=', 1, 'some requests fit in the zone');
        Test::More::cmp_ok($n503, '>=', 1, 'requests that do not fit get 503');
        Test::More::is($n200 + $n503, 150, 'no other status');

        # the held connections were closed by the clients; once nginx has
        # noticed (the delayed writes fail), the zone is usable again
        my $status = 0;
        for my $try (1 .. 20) {
            my $one = LimitRate::fetch_parallel({ path => '/dl/f.bin', hold => 1,
                headers => { 'X-Key' => 'recovery-' . $try } })->[0];
            $status = $one->{status};
            last if $status == 200;
            select(undef, undef, undef, 1);
        }
        Test::More::is($status, 200, 'the zone recovers after the connections end');

        LimitRate::no_crash_in_log();
    },
}



=== TEST 2: tiny zone, one key, 1200 connections: 503, no crash, recovery
--- http_config
    limit_traffic_rate_zone tiny $http_x_key 32k;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate tiny 1k;
    }
--- user_files eval
">>> dl/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ map { { path => '/dl/f.bin', hold => 10,
                         headers => { 'X-Key' => 'same' } } } 1 .. 1200 ],
    check => sub {
        my ($r) = @_;
        my $n503 = scalar grep { $_->{status} == 503 } @$r;
        my $n200 = scalar grep { $_->{status} == 200 } @$r;
        # a few clients may have received only part of the status line when
        # they gave up: with a rate this low nginx sends a response header
        # a few bytes at a time.  A reset connection has no bytes at all.
        my $bad  = scalar grep { $_->{status} == 0 && $_->{bytes} == 0 } @$r;
        Test::More::diag("200=$n200 503=$n503 no-response=$bad");
        Test::More::cmp_ok($n503, '>=', 1, 'requests that do not fit get 503');
        Test::More::cmp_ok($n200, '>=', 1, 'some requests are served');
        Test::More::is($bad, 0, 'no connection was reset or left without a response');

        # (a new key: the bytes already sent for 'same' are over its limit,
        # so a new request for that key would be delayed on purpose)
        my $status = 0;
        for my $try (1 .. 20) {
            my $one = LimitRate::fetch_parallel({ path => '/dl/f.bin', hold => 1,
                headers => { 'X-Key' => 'recovery-' . $try } })->[0];
            $status = $one->{status};
            last if $status == 200;
            select(undef, undef, undef, 1);
        }
        Test::More::is($status, 200, 'the zone recovers after the connections end');

        LimitRate::no_crash_in_log();
    },
}



=== TEST 3: idle nodes are reclaimed when the zone is full
--- http_config
    limit_traffic_rate_zone tiny $http_x_key 32k;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate tiny 20k;
    }
--- user_files eval
">>> dl/f.bin\n" . LimitRate::bytes_in_file(20000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    # every client downloads once and finishes; its node then stays in the
    # zone as an idle node.  150 such nodes do not fit in 32k, so allocation
    # has to reclaim idle nodes instead of answering 503.
    clients => [ map { { path => '/dl/f.bin', timeout => 30,
                         headers => { 'X-Key' => sprintf('%04d', $_) . ('k' x 1000) } } }
                 1 .. 150 ],
    check => sub {
        my ($r) = @_;
        my $n503 = scalar grep { $_->{status} == 503 } @$r;
        my $n200 = scalar grep { $_->{status} == 200 } @$r;
        Test::More::is($n503, 0, 'no 503: idle nodes are reclaimed');
        Test::More::is($n200, 150, 'all requests are served');
        LimitRate::no_crash_in_log();
    },
}
