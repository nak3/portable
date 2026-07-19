#!/bin/sh
#
# Copyright (c) 2026 Kenjiro Nakayama
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

set -e

if [ -z "$srcdir" ]; then
	srcdir=.
fi

if [ -z "$PERL" ]; then
	PERL=perl
fi

case "$srcdir" in
/*)
	certs_path="$srcdir/certs"
	callback_pl="$srcdir/callback.pl"
	make_dir_roots="$srcdir/make-dir-roots.pl"
	;;
*)
	certs_path="`pwd`/$srcdir/certs"
	callback_pl="`pwd`/$srcdir/callback.pl"
	make_dir_roots="`pwd`/$srcdir/make-dir-roots.pl"
	;;
esac

if [ $# -ge 1 ]; then
	callback_bin=$1
else
	callback_bin="`pwd`/callback"
	if [ -e ./callback.exe ]; then
		callback_bin="`pwd`/callback.exe"
	fi
fi

if [ $# -ge 2 ]; then
	expirecallback_bin=$2
else
	expirecallback_bin="`pwd`/expirecallback"
	if [ -e ./expirecallback.exe ]; then
		expirecallback_bin="`pwd`/expirecallback.exe"
	fi
fi

if [ $# -ge 3 ]; then
	callbackfailures_bin=$3
else
	callbackfailures_bin="`pwd`/callbackfailures"
	if [ -e ./callbackfailures.exe ]; then
		callbackfailures_bin="`pwd`/callbackfailures.exe"
	fi
fi

if [ $# -ge 4 ]; then
	openssl_dir=`dirname "$4"`
elif [ -d ../apps/openssl ]; then
	openssl_dir="`pwd`/../apps/openssl"
else
	openssl_dir="`pwd`/../apps"
fi

PATH="$openssl_dir:$PATH"
export PATH

workdir=x509_callback-certs

cleanup()
{
	rm -rf "$workdir"
}
trap cleanup EXIT

rm -rf "$workdir"
mkdir "$workdir"

"$PERL" "$make_dir_roots" "$certs_path" "$workdir"

(
	cd "$workdir"
	"$callback_bin" "$certs_path"
	"$PERL" "$callback_pl" callback.out
	"$expirecallback_bin" "$certs_path"
	"$callbackfailures_bin" "$certs_path"
)
