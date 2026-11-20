#!/usr/bin/env bash
# valid_domain, valid_email and is_placeholder_email.

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"
load_setup

for d in example.com omeka.example.edu a.b a-b.c-d.org xn--bcher-kva.example \
    omeka2.uni-bayreuth.de 1x.example.com; do
    assert_true "valid_domain accepts '${d}'" valid_domain "${d}"
done

# ask_https lowercases before validating, so upper case is rejected here.
for d in "" localhost Example.com "http://example.com" "example.com/" \
    "example.com:443" -a.com a-.com a..com .a.com a.com. "a b.com" \
    "*.example.com" exa_mple.com "omeka.example.edu'" 'omeka.example.edu"' \
    "omeka.example.edu;rm" $'omeka.example.edu\nevil.com'; do
    assert_false "valid_domain rejects '${d}'" valid_domain "${d}"
done

for e in a@b.co admin@example.com first.last+tag@uni.example.edu \
    Admin.Name@Uni-Bayreuth.DE; do
    assert_true "valid_email accepts '${e}'" valid_email "${e}"
done

for e in "" a@b @b.com a@ a@@b.com "a b@c.com" "a@b c.com" "a'b@c.com" \
    'a"b@c.com' "a@b'.com" $'a@b.com\nX=1' a@.com.; do
    assert_false "valid_email rejects '${e}'" valid_email "${e}"
done

for e in admin@example.com ops@EXAMPLE.ORG x@example.net; do
    assert_true "is_placeholder_email: ${e}" is_placeholder_email "${e}"
done
for e in admin@example.edu admin@example.com.au admin@myexample.com webmaster@uni.de; do
    assert_false "is_placeholder_email: not ${e}" is_placeholder_email "${e}"
done

finish
