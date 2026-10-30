#!/bin/sh
# Wrapper for nginx binaries older than 1.19.5, which have no "-e <file>"
# option; Test::Nginx 0.32 always passes it.  It is dropped here: with
# "-p <prefix>" nginx writes startup messages to <prefix>/logs/error.log,
# which is the file Test::Nginx passes anyway.
#
#   NGX_REAL_BINARY=/path/to/nginx TEST_NGINX_BINARY=t/nginx-no-e.sh prove -r t/
set -eu
: "${NGX_REAL_BINARY:?set NGX_REAL_BINARY to the real nginx binary}"
args=
while [ $# -gt 0 ]; do
    if [ "$1" = "-e" ]; then
        shift 2
        continue
    fi
    args="$args '$(printf %s "$1" | sed "s/'/'\\\\''/g")'"
    shift
done
eval "exec \"\$NGX_REAL_BINARY\" $args"
