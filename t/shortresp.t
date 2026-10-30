# Behaviour of the byte accounting and of the interaction with the core
# directives (limit_rate, limit_rate_after) and with internal redirects.
#
# Timing numbers in the comments were measured; the asserted bounds are
# deliberately looser: a tight lower bound proves the limit works, the
# upper bound is loose for slow CI runners.

use lib 't/lib';
use Test::Nginx::Socket 'no_plan';
use LimitRate;
use List::Util ();

repeat_each(1);
worker_connections(1024);
run_tests();

__DATA__

=== TEST 1: many short responses stay near the limit
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate rate 400k;
    }
--- user_files eval
">>> dl/small.bin\n" . LimitRate::bytes_in_file(32768)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ ({ path => '/dl/small.bin' }) x 50 ],
    check => sub {
        my ($r) = @_;
        Test::More::is(scalar(grep { $_->{status} == 200 && $_->{bytes} >= 32768 } @$r), 50, 'all served');
        my $total = List::Util::max(map { $_->{elapsed} } @$r);
        # 50 * 32768 = 1.6MB at 400k/s: nominally 4s, measured ~5s
        Test::More::cmp_ok($total, '>=', 3.0, 'short responses are limited (expect ~5s, unlimited ~0s)');
        Test::More::cmp_ok($total, '<=', 25, 'upper bound');
    },
}



=== TEST 2: core limit_rate / $limit_rate below the module rate wins
--- http_config
    limit_traffic_rate_zone rate $http_x_key 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /core/ {
        limit_rate 10k;
        limit_traffic_rate rate 10m;
    }
    location /var/ {
        set $limit_rate 10k;
        limit_traffic_rate rate 10m;
    }
    location /module/ {
        limit_rate 10m;
        limit_traffic_rate rate 10k;
    }
    location /fast/ {
        limit_rate 10m;
        limit_traffic_rate rate 10m;
    }
--- user_files eval
">>> core/f.bin\n" . LimitRate::bytes_in_file(50000)
. "\n>>> var/f.bin\n" . LimitRate::bytes_in_file(50000)
. "\n>>> module/f.bin\n" . LimitRate::bytes_in_file(50000)
. "\n>>> fast/f.bin\n" . LimitRate::bytes_in_file(50000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [
        { path => '/core/f.bin',   headers => { 'X-Key' => 'a' } },
        { path => '/var/f.bin',    headers => { 'X-Key' => 'b' } },
        { path => '/module/f.bin', headers => { 'X-Key' => 'c' } },
        { path => '/fast/f.bin',   headers => { 'X-Key' => 'd' } },
    ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($_->{bytes}, '>=', 50000, 'body') for @$r;
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'limit_rate 10k wins over module 10m');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 15, 'limit_rate upper bound');
        Test::More::cmp_ok($r->[1]{elapsed}, '>=', 3.2, '$limit_rate 10k wins over module 10m');
        Test::More::cmp_ok($r->[1]{elapsed}, '<=', 15, '$limit_rate upper bound');
        Test::More::cmp_ok($r->[2]{elapsed}, '>=', 3.2, 'module 10k wins over limit_rate 10m');
        Test::More::cmp_ok($r->[2]{elapsed}, '<=', 15, 'module upper bound');
        Test::More::cmp_ok($r->[3]{elapsed}, '<', 1.0, 'both high: not limited');
    },
}



=== TEST 3: limit_rate_after: the first bytes are fast, the rest is limited
--- http_config
    limit_traffic_rate_zone rate $http_x_key 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_rate_after 40k;
        limit_traffic_rate rate 10k;
    }
--- user_files eval
">>> dl/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/dl/f.bin', mark => 35000, headers => { 'X-Key' => 'a' } } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($r->[0]{bytes}, '>=', 100000, 'body');
        Test::More::cmp_ok($r->[0]{mark}, '<', 1.0, 'the first 35000 bytes are not delayed');
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 4.0, 'the rest is limited');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 20, 'upper bound');
    },
}



=== TEST 4: the saved-up burst is capped at about one second
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /ping { return 200 "ok\n"; }
    # a slow client (core limit 2k) keeps the key alive and leaves almost
    # all of the 50k/s unused
    location /slow/ {
        limit_rate 2k;
        limit_traffic_rate rate 50k;
    }
    location /burst/ {
        limit_traffic_rate rate 50k;
    }
--- user_files eval
">>> slow/f.bin\n" . LimitRate::bytes_in_file(200000)
. "\n>>> burst/f.bin\n" . LimitRate::bytes_in_file(20000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [
        { path => '/slow/f.bin', hold => 13 },
        # after 7s ~340k of bandwidth would be saved up if it were not
        # capped, so 14 * 20000 = 280k would pass without any delay; with
        # the cap about 50k pass at once and the rest takes ~5s
        { path => '/burst/f.bin', delay => 7, repeat => 14 },
    ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($r->[1]{bytes}, '>=', 280000, 'burst body');
        Test::More::cmp_ok($r->[1]{elapsed}, '>=', 4.0,
                           'the idle period did not buy more than ~1s of burst');
        Test::More::cmp_ok($r->[1]{elapsed}, '<=', 25, 'upper bound');
    },
}



=== TEST 5: no crash for responses that bypass the preaccess handler
--- http_config
    limit_traffic_rate_zone z $binary_remote_addr 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate z 20k;
    }
    # these run in the rewrite phase or are redirected: the request is not
    # (or not in this location) registered in the zone, although the key
    # already has a node because of the slow download
    location /ret {
        limit_traffic_rate z 20k;
        return 200 "returned\n";
    }
    location /rw {
        limit_traffic_rate z 20k;
        rewrite ^ /plain.txt redirect;
    }
    location /e/ {
        limit_traffic_rate z 20k;
        error_page 404 = /dl/small.bin;
    }
    location /s/ {
        limit_traffic_rate z 20k;
        ssi on;
    }
--- user_files eval
">>> dl/big.bin\n" . LimitRate::bytes_in_file(200000)
. "\n>>> dl/small.bin\n" . LimitRate::bytes_in_file(3000)
. "\n>>> s/page.html\nbefore <!--# include virtual=\"/dl/small.bin\" --> after\n"
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [
        { path => '/dl/big.bin', hold => 6 },
        { path => '/ret',          delay => 1 },
        { path => '/rw',           delay => 1 },
        { path => '/e/missing',    delay => 1 },
        { path => '/s/page.html',  delay => 1 },
    ],
    check => sub {
        my ($r) = @_;
        Test::More::is($r->[1]{status}, 200, 'return 200');
        Test::More::is($r->[2]{status}, 302, 'rewrite ... redirect');
        Test::More::is($r->[3]{status}, 200, 'error_page 404 = to a limited location');
        Test::More::cmp_ok($r->[3]{bytes}, '>=', 3000, 'error_page body');
        Test::More::is($r->[4]{status}, 200, 'SSI include of a limited location');
        Test::More::cmp_ok($r->[4]{bytes}, '>=', 3000, 'SSI body');
        Test::More::cmp_ok($_->{elapsed}, '<=', 30, 'finished') for @$r[1..4];
        LimitRate::no_crash_in_log();

        # nginx is still alive and serving
        my $after = LimitRate::fetch_parallel({ path => '/ret' })->[0];
        Test::More::is($after->{status}, 200, 'nginx still serves requests');
    },
}



=== TEST 6: two zones, internal redirect: no double registration
--- http_config
    limit_traffic_rate_zone z1 $http_x_key 1m;
    limit_traffic_rate_zone z2 $http_x_key 1m;
--- config
    location /ping { return 200 "ok\n"; }
    # /a/missing is registered in z1 and z2 here, then redirected to /b/f.bin
    # which has the same two directives
    location /a/ {
        limit_traffic_rate z1 20k;
        limit_traffic_rate z2 20k;
        error_page 404 = /b/f.bin;
    }
    location /b/ {
        limit_traffic_rate z1 20k;
        limit_traffic_rate z2 20k;
    }
--- user_files eval
">>> b/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/a/missing', headers => { 'X-Key' => 'k' } } ],
    check => sub {
        my ($r) = @_;
        Test::More::is($r->[0]{status}, 200, 'status');
        Test::More::cmp_ok($r->[0]{bytes}, '>=', 100000, 'body');
        # one download at 20k takes ~4s; counted twice it would be ~8s
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'limited');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 5.0, 'not counted twice');
    },
}
