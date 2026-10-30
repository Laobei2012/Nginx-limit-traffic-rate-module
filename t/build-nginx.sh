#!/bin/sh
# Build nginx with this module for the test suite, either statically
# (--add-module, the default) or as a dynamic module (--add-dynamic-module,
# nginx >= 1.9.11).
#
# Usage: t/build-nginx.sh <nginx-source-dir> <install-prefix> [static|dynamic]
#
# A dynamic build installs <install-prefix>/modules/
# ngx_http_limit_traffic_rate_filter_module.so; run the tests with
# LTR_DYNAMIC_MODULE set to that path.
#
# nginx and the module are compiled with -Werror, so any compiler warning
# fails the build.  --with-pcre enables PCRE for the rewrite module (which
# is built by default).  NGX_EXTRA_CONFIGURE may hold additional ./configure
# options.
set -eu

SRC=$1
PREFIX=$2
LINK=${3:-static}
MODULE_DIR=$(cd "$(dirname "$0")/.." && pwd)

case $LINK in
    static)  ADD=--add-module ;;
    dynamic) ADD=--add-dynamic-module ;;
    *) echo "unknown link mode: $LINK" >&2; exit 2 ;;
esac

cd "$SRC"
./configure \
    --prefix="$PREFIX" \
    --with-cc-opt=-Werror \
    --with-pcre \
    $ADD="$MODULE_DIR" \
    ${NGX_EXTRA_CONFIGURE:-}
make -j"$(nproc)"
make install
