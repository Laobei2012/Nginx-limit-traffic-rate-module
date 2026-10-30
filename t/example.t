# README example 1: at most 8 connections per client IP (limit_conn) and
# 4MB/s in total (limit_traffic_rate).  The 9th parallel connection is
# rejected with 503.

use lib 't/lib';
use Test::Nginx::Socket 'no_plan';
use LimitRate;
use List::Util ();

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: README example config is accepted and serves a file
--- http_config
    limit_conn_zone           $binary_remote_addr zone=addr:10m;
    limit_traffic_rate_zone   rate $binary_remote_addr 32m;
--- config
    location /download/ {
        limit_conn          addr 8;
        limit_traffic_rate  rate 4m;
    }
--- user_files eval
">>> download/small.txt\nhello\n"
--- request
GET /download/small.txt
--- response_body
hello
--- no_error_log
[emerg]
[error]



=== TEST 2: 8 parallel connections are served, the 9th gets 503
--- http_config
    limit_conn_zone           $binary_remote_addr zone=addr:10m;
    limit_traffic_rate_zone   rate $binary_remote_addr 32m;
--- config
    location /ping { return 200 "ok\n"; }
    location /download/ {
        limit_conn          addr 8;
        limit_traffic_rate  rate 4m;
    }
--- user_files eval
">>> download/big.bin\n" . LimitRate::bytes_in_file(1500000)
--- request
GET /ping
--- response_body
ok
--- timing eval
{
    # 8 x 1.5MB at a shared 4MB/s keeps the connections open for seconds
    clients => [ ({ path => '/download/big.bin', timeout => 60 }) x 9 ],
    check => sub {
        my ($r) = @_;
        my @ok  = grep { $_->{status} == 200 } @$r;
        my @rej = grep { $_->{status} == 503 } @$r;
        Test::More::is(scalar(@ok), 8, '8 connections are served');
        Test::More::is(scalar(@rej), 1, 'the 9th connection gets 503');
        Test::More::cmp_ok($_->{bytes}, '>=', 1500000, 'served body is complete') for @ok;
        # 12MB in total at 4MB/s: clearly slower than an unlimited transfer
        Test::More::cmp_ok(List::Util::max(map { $_->{elapsed} } @ok), '>=', 1.5,
                           'the served connections share the traffic limit');
    },
}
