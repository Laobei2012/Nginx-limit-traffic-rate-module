# Dynamic module build (nginx >= 1.9.11, --add-dynamic-module).
#
# Only runs when LTR_DYNAMIC_MODULE points to the built .so (see t/README);
# the other test files then get "load_module" added automatically.

use lib 't/lib';
use Test::Nginx::Socket;
use LimitRate;

if (!$ENV{LTR_DYNAMIC_MODULE}) {
    plan skip_all => 'LTR_DYNAMIC_MODULE is not set (static build)';
}

plan tests => 6;
repeat_each(1);
run_tests();

__DATA__

=== TEST 1: the .so loads and its directives work
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



=== TEST 2: without load_module the directives are unknown
--- no_load_module
--- http_config
    limit_traffic_rate_zone rate $binary_remote_addr 1m;
--- config
    location /ok { return 200 "ok\n"; }
--- must_die
--- error_log
unknown directive "limit_traffic_rate_zone"
