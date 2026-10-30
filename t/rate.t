# Rate enforcement.  All downloads are 100000 bytes with a 20k rate limit.
# Nominally one download takes 5 seconds; measured it is about 4 seconds
# (nginx lets a first burst through), an unlimited one takes milliseconds.
#
# Bounds are deliberately asymmetric: a tight lower bound proves that the
# limit is applied (an unlimited download over loopback is ~1000x faster),
# the upper bound is loose so that slow CI runners do not cause failures.

use lib 't/lib';
use Test::Nginx::Socket 'no_plan';
use LimitRate;
use List::Util ();

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: a single download takes about size/rate
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate rate 20k;
    }
--- user_files eval
">>> dl/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/dl/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::is($r->[0]{status}, 200, 'status');
        Test::More::is($r->[0]{bytes}, 100000, 'whole body received');
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'rate limit is applied (expect ~4s)');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 15, 'not much slower than the limit');
    },
}



=== TEST 2: two parallel downloads with the same key share the limit
--- http_config
    limit_traffic_rate_zone rate $http_x_key 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate rate 20k;
    }
--- user_files eval
">>> dl/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ ({ path => '/dl/f.bin', headers => { 'X-Key' => 'same' } }) x 2 ],
    check => sub {
        my ($r) = @_;
        for my $i (0, 1) {
            Test::More::is($r->[$i]{status}, 200, "client $i status");
            Test::More::is($r->[$i]{bytes}, 100000, "client $i body");
        }
        # 200000 bytes in total at 20k/s: the slower one needs ~9s (>= 7s asserted)
        my $slow = List::Util::max(map { $_->{elapsed} } @$r);
        Test::More::cmp_ok($slow, '>=', 7.0, 'limit is shared (a single download takes ~4s)');
        Test::More::cmp_ok($slow, '<=', 30, 'finishes in reasonable time');
    },
}



=== TEST 3: different keys get separate limits
--- http_config
    limit_traffic_rate_zone rate $http_x_key 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate rate 20k;
    }
--- user_files eval
">>> dl/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [
        { path => '/dl/f.bin', headers => { 'X-Key' => 'a' } },
        { path => '/dl/f.bin', headers => { 'X-Key' => 'b' } },
        { path => '/dl/f.bin', headers => { 'X-Key' => 'b' } },
    ],
    check => sub {
        my ($r) = @_;
        my ($ka, @kb) = @$r;
        Test::More::is($_->{status}, 200, 'status') for @$r;
        Test::More::is($_->{bytes}, 100000, 'body') for @$r;
        # a alone: ~4s.  b1 + b2 share one limit and take much longer.
        Test::More::cmp_ok($ka->{elapsed}, '>=', 3.2, 'key a is limited (expect ~4s)');
        Test::More::cmp_ok($ka->{elapsed}, '<=', 15, 'key a upper bound');
        my $bfast = List::Util::min(map { $_->{elapsed} } @kb);
        Test::More::cmp_ok($ka->{elapsed}, '<', 0.85 * $bfast,
               'key a is not slowed down by the two key b downloads');
    },
}



=== TEST 4: a location without the directive is not limited
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /limited/ {
        limit_traffic_rate rate 20k;
    }
    location /free/ {
    }
--- user_files eval
">>> free/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/free/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::is($r->[0]{status}, 200, 'status');
        Test::More::is($r->[0]{bytes}, 100000, 'body');
        Test::More::cmp_ok($r->[0]{elapsed}, '<', 1.0, 'unlimited location is fast');
    },
}
