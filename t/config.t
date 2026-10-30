# Configuration parsing: valid configuration and every error path of the
# limit_traffic_rate_zone / limit_traffic_rate directives.

use lib 't/lib';
use Test::Nginx::Socket 'no_plan';
use LimitRate;     # also handles load_module for dynamic builds

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: valid zone and rate
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /ok {
        limit_traffic_rate rate 20k;
        return 200 "ok\n";
    }
--- request
GET /ok
--- response_body
ok
--- no_error_log
[emerg]
[alert]



=== TEST 2: rate with k/m suffixes and plain bytes are accepted
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /a { limit_traffic_rate rate 512;  return 200 "a\n"; }
    location /b { limit_traffic_rate rate 20k;  return 200 "b\n"; }
    location /c { limit_traffic_rate rate 4m;   return 200 "c\n"; }
--- request
GET /c
--- response_body
c
--- no_error_log
[emerg]



=== TEST 3: invalid rate "abc" is reported with its own value
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /x {
        limit_traffic_rate rate abc;
    }
--- must_die
--- error_log
invalid size of limit_traffic_rate "abc"



=== TEST 4: rate 0 is rejected
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /x {
        limit_traffic_rate rate 0;
    }
--- must_die
--- error_log
invalid size of limit_traffic_rate "0"



=== TEST 5: duplicate directive in one block
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /x {
        limit_traffic_rate rate 20k;
        limit_traffic_rate rate 30k;
    }
--- must_die
--- error_log
"limit_traffic_rate" directive is duplicate



=== TEST 6: limit_traffic_rate with too few arguments
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /x {
        limit_traffic_rate rate;
    }
--- must_die
--- error_log
invalid number of arguments in "limit_traffic_rate" directive



=== TEST 7: limit_traffic_rate with too many arguments
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /x {
        limit_traffic_rate rate 20k extra;
    }
--- must_die
--- error_log
invalid number of arguments in "limit_traffic_rate" directive



=== TEST 8: limit_traffic_rate_zone with too few arguments
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr;
--- config
    location /x { return 200; }
--- must_die
--- error_log
invalid number of arguments in "limit_traffic_rate_zone" directive



=== TEST 9: limit_traffic_rate_zone with too many arguments
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m extra;
--- config
    location /x { return 200; }
--- must_die
--- error_log
invalid number of arguments in "limit_traffic_rate_zone" directive



=== TEST 10: undefined zone
--- config
    location /x {
        limit_traffic_rate nosuchzone 20k;
    }
--- must_die
--- error_log
zero size shared memory zone "nosuchzone"



=== TEST 11: zone variable without a leading $
--- http_config
    limit_traffic_rate_zone rate remote_addr 1m;
--- config
    location /x { return 200; }
--- must_die
--- error_log
invalid variable name "remote_addr"



=== TEST 12: zone size smaller than 8 pages
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 4k;
--- config
    location /x { return 200; }
--- must_die
--- error_log
limit_traffic_rate_zone "rate" is too small



=== TEST 13: zone size that is not a size
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr bogus;
--- config
    location /x { return 200; }
--- must_die
--- error_log
invalid size of limit_traffic_rate_zone "bogus"



=== TEST 14: zone name defined twice
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /x { return 200; }
--- must_die
--- error_log
limit_traffic_rate_zone "rate" is already bound to variable "binary_remote_addr"



=== TEST 15: limit_traffic_rate_zone is only allowed in http{}
--- http_config
--- config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
    location /x { return 200; }
--- must_die
--- error_log
"limit_traffic_rate_zone" directive is not allowed here
