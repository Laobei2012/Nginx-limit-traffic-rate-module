# Inheritance of limit_traffic_rate from http{} and server{} to server{}
# and location{} (and to if{} inside a location).
#
# A limited 100000-byte download at 20k takes about 4 seconds, an
# unlimited one a few milliseconds, so ">= 3.2" means "limited" and
# "< 1.0" means "not limited".  The zones are keyed by $uri, so downloads of
# different files never share a limit and can run in parallel.

use lib 't/lib';
use Test::Nginx::Socket 'no_plan';
use LimitRate;

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: http-level directive applies to locations
--- http_config
    limit_traffic_rate_zone z $uri 1m;
    limit_traffic_rate z 20k;
--- config
    location /ping { return 200 "ok\n"; }
    location /one/ { }
    location /two/ { }
--- user_files eval
">>> one/f.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> two/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/one/f.bin' }, { path => '/two/f.bin' } ],
    check => sub {
        my ($r) = @_;
        for my $i (0, 1) {
            Test::More::cmp_ok($r->[$i]{bytes}, '>=', 100000, "client $i body");
            Test::More::cmp_ok($r->[$i]{elapsed}, '>=', 3.2, "client $i is limited");
            Test::More::cmp_ok($r->[$i]{elapsed}, '<=', 15, "client $i upper bound");
        }
    },
}



=== TEST 2: server-level directive applies to all its locations
--- http_config
    limit_traffic_rate_zone z $uri 1m;
--- config
    limit_traffic_rate z 20k;
    location /ping { return 200 "ok\n"; }
    location /one/ { }
    location /two/ { }
--- user_files eval
">>> one/f.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> two/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/one/f.bin' }, { path => '/two/f.bin' } ],
    check => sub {
        my ($r) = @_;
        for my $i (0, 1) {
            Test::More::cmp_ok($r->[$i]{bytes}, '>=', 100000, "client $i body");
            Test::More::cmp_ok($r->[$i]{elapsed}, '>=', 3.2, "client $i is limited");
            Test::More::cmp_ok($r->[$i]{elapsed}, '<=', 15, "client $i upper bound");
        }
    },
}



=== TEST 3: a location without the directive under a limited server is limited
--- http_config
    limit_traffic_rate_zone z $uri 1m;
--- config
    limit_traffic_rate z 20k;
    location /ping { return 200 "ok\n"; }
    location /plain/ {
        # no limit_traffic_rate here
        add_header X-Plain 1;
    }
--- user_files eval
">>> plain/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/plain/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($r->[0]{bytes}, '>=', 100000, 'body');
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'inherited limit is applied');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 15, 'upper bound');
    },
}



=== TEST 4: location overrides the server level with another zone and rate
--- http_config
    limit_traffic_rate_zone slowz $uri 1m;
    limit_traffic_rate_zone fastz $uri 1m;
--- config
    limit_traffic_rate slowz 20k;
    location /ping { return 200 "ok\n"; }
    location /inherits/ { }
    location /overrides/ {
        limit_traffic_rate fastz 10m;
    }
--- user_files eval
">>> inherits/f.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> overrides/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/inherits/f.bin' }, { path => '/overrides/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($_->{bytes}, '>=', 100000, 'body') for @$r;
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'inheriting location is limited');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 15, 'inheriting location upper bound');
        Test::More::cmp_ok($r->[1]{elapsed}, '<', 1.0, 'overriding location uses the fast rate');
    },
}



=== TEST 5: location overrides the http level with a lower rate
--- http_config
    limit_traffic_rate_zone z $uri 1m;
    limit_traffic_rate z 10m;
--- config
    location /ping { return 200 "ok\n"; }
    location /inherits/ { }
    location /overrides/ {
        limit_traffic_rate z 20k;
    }
--- user_files eval
">>> inherits/f.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> overrides/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/inherits/f.bin' }, { path => '/overrides/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($_->{bytes}, '>=', 100000, 'body') for @$r;
        Test::More::cmp_ok($r->[0]{elapsed}, '<', 1.0, 'inheriting location uses the http level rate');
        Test::More::cmp_ok($r->[1]{elapsed}, '>=', 3.2, 'overriding location is limited');
        Test::More::cmp_ok($r->[1]{elapsed}, '<=', 15, 'overriding location upper bound');
    },
}



=== TEST 6: server-level directive overrides the http level
--- http_config
    limit_traffic_rate_zone z $uri 1m;
    limit_traffic_rate z 10m;
--- config
    limit_traffic_rate z 20k;
    location /ping { return 200 "ok\n"; }
    location /f/ { }
--- user_files eval
">>> f/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/f/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($r->[0]{bytes}, '>=', 100000, 'body');
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'server level rate is applied');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 15, 'upper bound');
    },
}



=== TEST 7: the limit is inherited inside an if block of a location
--- http_config
    limit_traffic_rate_zone z $uri 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        limit_traffic_rate z 20k;
        if ($arg_x) {
            add_header X-If 1;
        }
    }
--- user_files eval
">>> dl/in-if.bin\n" . LimitRate::bytes_in_file(100000)
. "\n>>> dl/no-if.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/dl/in-if.bin?x=1' }, { path => '/dl/no-if.bin' } ],
    check => sub {
        my ($r) = @_;
        for my $i (0, 1) {
            Test::More::cmp_ok($r->[$i]{bytes}, '>=', 100000, "client $i body");
            Test::More::cmp_ok($r->[$i]{elapsed}, '>=', 3.2, "client $i is limited");
            Test::More::cmp_ok($r->[$i]{elapsed}, '<=', 15, "client $i upper bound");
        }
    },
}



=== TEST 8: the limit is inherited inside an if block of a limited server
--- http_config
    limit_traffic_rate_zone z $uri 1m;
--- config
    limit_traffic_rate z 20k;
    location /ping { return 200 "ok\n"; }
    location /dl/ {
        if ($arg_x) {
            add_header X-If 1;
        }
    }
--- user_files eval
">>> dl/in-if.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/dl/in-if.bin?x=1' } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($r->[0]{bytes}, '>=', 100000, 'body');
        Test::More::cmp_ok($r->[0]{elapsed}, '>=', 3.2, 'limited');
        Test::More::cmp_ok($r->[0]{elapsed}, '<=', 15, 'upper bound');
    },
}



=== TEST 9: without any directive nothing is limited
--- http_config
    limit_traffic_rate_zone z $uri 1m;
--- config
    location /ping { return 200 "ok\n"; }
    location /f/ { }
--- user_files eval
">>> f/f.bin\n" . LimitRate::bytes_in_file(100000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    clients => [ { path => '/f/f.bin' } ],
    check => sub {
        my ($r) = @_;
        Test::More::cmp_ok($r->[0]{bytes}, '>=', 100000, 'body');
        Test::More::cmp_ok($r->[0]{elapsed}, '<', 1.0, 'not limited');
    },
}
