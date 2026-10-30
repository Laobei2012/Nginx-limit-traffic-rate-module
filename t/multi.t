# Several limit_traffic_rate directives (different zones) in one block.
#
# A limited 100000-byte download at 20k takes about 4 seconds, an
# unlimited one a few milliseconds (">= 3.2" means limited, "< 1.0" means
# not limited).  A limit shared by two clients makes the slower one need
# clearly more than 7 seconds.

use lib 't/lib';
use Test::Nginx::Socket 'no_plan';
use LimitRate;
use List::Util ();

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: several zones in one block are accepted
--- http_config
    limit_traffic_rate_zone perip  $binary_remote_addr 1m;
    limit_traffic_rate_zone global $server_name 1m;
--- config
    location /ok {
        limit_traffic_rate perip  100k;
        limit_traffic_rate global 10m;
        return 200 "ok\n";
    }
--- request
GET /ok
--- response_body
ok
--- no_error_log
[emerg]



=== TEST 2: the same zone twice in one block is a duplicate
--- http_config
    limit_traffic_rate_zone perip  $binary_remote_addr 1m;
    limit_traffic_rate_zone global $server_name 1m;
--- config
    location /x {
        limit_traffic_rate perip  100k;
        limit_traffic_rate global 10m;
        limit_traffic_rate perip  200k;
    }
--- must_die
--- error_log
"limit_traffic_rate" directive is duplicate



=== TEST 3: perip + global, the lower global limit wins (shared by all keys)
--- http_config
    limit_traffic_rate_zone perip  $http_x_key 1m;
    limit_traffic_rate_zone global $server_name 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate perip  10m;
        limit_traffic_rate global 20k;
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
    ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($_->{bytes}, '>=', 100000, 'body') for @$r;
        # the keys differ, so only the global zone can make them slow and
        # make them share the limit
        my $slow = List::Util::max(map { $_->{elapsed} } @$r);
        Test::More::cmp_ok($slow, '>=', 7.0, 'global limit is shared by both keys');
        Test::More::cmp_ok($slow, '<=', 30, 'upper bound');
    },
}



=== TEST 4: perip + global, the lower perip limit wins (separate per key)
--- http_config
    limit_traffic_rate_zone perip  $http_x_key 1m;
    limit_traffic_rate_zone global $server_name 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate perip  20k;
        limit_traffic_rate global 10m;
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
    ],
    check => sub {
        my ($r) = @_;
        for my $c (@$r) {
            Test::More::cmp_ok($c->{bytes}, '>=', 100000, 'body');
            Test::More::cmp_ok($c->{elapsed}, '>=', 3.2, 'perip limit is applied');
            Test::More::cmp_ok($c->{elapsed}, '<=', 15, 'and not shared with the other key');
        }
    },
}



=== TEST 5: a location with its own directive replaces the inherited set
--- http_config
    limit_traffic_rate_zone slow1 $uri 1m;
    limit_traffic_rate_zone slow2 $uri 1m;
    limit_traffic_rate_zone fast  $uri 1m;
--- config
    limit_traffic_rate slow1 20k;
    limit_traffic_rate slow2 30k;
    location /ping { return 200 "ok\n"; }
    location /inherits/ { }
    location /replaces/ {
        limit_traffic_rate fast 10m;
    }
--- user_files eval
">>> inherits/f.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> replaces/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/inherits/f.bin' }, { path => '/replaces/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'inheriting location is limited');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 15, 'inheriting location upper bound');
        Test::More::cmp_ok($r->[1]{bytes}, '>=', 100000, 'body');
        Test::More::cmp_ok($r->[1]{elapsed}, '<', 1.0,
            'inherited zones are not added to the location own directive');
    },
}



=== TEST 6: an empty key value skips that zone only
--- http_config
    limit_traffic_rate_zone bykey $http_x_key 1m;
    limit_traffic_rate_zone byuri $uri 1m;
--- config
    location /ping { return 200 "ok\n"; }
    # bykey would be slow, byuri is fast: only limited when X-Key is sent
    location /d1/ {
        limit_traffic_rate bykey 20k;
        limit_traffic_rate byuri 10m;
    }
    # byuri is slow and always applies; the empty bykey must not matter
    location /d2/ {
        limit_traffic_rate bykey 10m;
        limit_traffic_rate byuri 20k;
    }
--- user_files eval
">>> d1/nokey.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> d1/key.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> d2/nokey.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [
        { path => '/d1/nokey.bin' },
        { path => '/d1/key.bin', headers => { 'X-Key' => 'k' } },
        { path => '/d2/nokey.bin' },
    ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($_->{bytes}, '>=', 100000, 'body') for @$r;
        Test::More::cmp_ok($r->[0]{elapsed}, '<', 1.0, 'empty key: zone skipped, not limited');
        Test::More::cmp_ok($r->[1]{elapsed}, '>=', 3.2, 'with key: zone applies');
        Test::More::cmp_ok($r->[1]{elapsed}, '<=', 15, 'with key: upper bound');
        Test::More::cmp_ok($r->[2]{elapsed}, '>=', 3.2, 'empty key in one zone, the other still applies');
        Test::More::cmp_ok($r->[2]{elapsed}, '<=', 15, 'other zone upper bound');
    },
}
