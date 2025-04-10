/* $OpenBSD: ui_openssl.c,v 1.22 2014/07/11 08:44:49 jsing Exp $ */
/* Written by Richard Levitte (richard@levitte.org) and others
 * for the OpenSSL project 2001.
 */
/* ====================================================================
 * Copyright (c) 2001 The OpenSSL Project.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. All advertising materials mentioning features or use of this
 *    software must display the following acknowledgment:
 *    "This product includes software developed by the OpenSSL Project
 *    for use in the OpenSSL Toolkit. (https://www.openssl.org/)"
 *
 * 4. The names "OpenSSL Toolkit" and "OpenSSL Project" must not be used to
 *    endorse or promote products derived from this software without
 *    prior written permission. For written permission, please contact
 *    openssl-core@openssl.org.
 *
 * 5. Products derived from this software may not be called "OpenSSL"
 *    nor may "OpenSSL" appear in their names without prior written
 *    permission of the OpenSSL Project.
 *
 * 6. Redistributions of any form whatsoever must retain the following
 *    acknowledgment:
 *    "This product includes software developed by the OpenSSL Project
 *    for use in the OpenSSL Toolkit (https://www.openssl.org/)"
 *
 * THIS SOFTWARE IS PROVIDED BY THE OpenSSL PROJECT ``AS IS'' AND ANY
 * EXPRESSED OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE OpenSSL PROJECT OR
 * ITS CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 * ====================================================================
 *
 * This product includes cryptographic software written by Eric Young
 * (eay@cryptsoft.com).  This product includes software written by Tim
 * Hudson (tjh@cryptsoft.com).
 *
 */

/* The lowest level part of this file was previously in crypto/des/read_pwd.c,
 * Copyright (C) 1995-1998 Eric Young (eay@cryptsoft.com)
 * All rights reserved.
 *
 * This package is an SSL implementation written
 * by Eric Young (eay@cryptsoft.com).
 * The implementation was written so as to conform with Netscapes SSL.
 *
 * This library is free for commercial and non-commercial use as long as
 * the following conditions are aheared to.  The following conditions
 * apply to all code found in this distribution, be it the RC4, RSA,
 * lhash, DES, etc., code; not just the SSL code.  The SSL documentation
 * included with this distribution is covered by the same copyright terms
 * except that the holder is Tim Hudson (tjh@cryptsoft.com).
 *
 * Copyright remains Eric Young's, and as such any Copyright notices in
 * the code are not to be removed.
 * If this package is used in a product, Eric Young should be given attribution
 * as the author of the parts of the library used.
 * This can be in the form of a textual message at program startup or
 * in documentation (online or textual) provided with the package.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. All advertising materials mentioning features or use of this software
 *    must display the following acknowledgement:
 *    "This product includes cryptographic software written by
 *     Eric Young (eay@cryptsoft.com)"
 *    The word 'cryptographic' can be left out if the rouines from the library
 *    being used are not cryptographic related :-).
 * 4. If you include any Windows specific code (or a derivative thereof) from
 *    the apps directory (application code) you must include an acknowledgement:
 *    "This product includes software written by Tim Hudson (tjh@cryptsoft.com)"
 *
 * THIS SOFTWARE IS PROVIDED BY ERIC YOUNG ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * The licence and distribution terms for any publically available version or
 * derivative of this code cannot be changed.  i.e. this code cannot simply be
 * copied and put under another distribution licence
 * [including the GNU Public Licence.]
 */

#include <sys/ioctl.h>

#include <openssl/opensslconf.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "ui_local.h"

#ifndef NX509_SIG
#define NX509_SIG 32
#endif

DWORD console_mode;
static FILE *tty_in, *tty_out;
static int is_a_tty;

/* Declare static functions */
static int read_till_nl(FILE *);
static int read_string_inner(UI *ui, UI_STRING *uis, int echo, int strip_nl);

static int read_string(UI *ui, UI_STRING *uis);
static int write_string(UI *ui, UI_STRING *uis);

static int open_console(UI *ui);
static int echo_console(UI *ui);
static int noecho_console(UI *ui);
static int close_console(UI *ui);

static const UI_METHOD ui_openssl = {
	.name = "OpenSSL default user interface",
	.ui_open_session = open_console,
	.ui_write_string = write_string,
	.ui_read_string = read_string,
	.ui_close_session = close_console,
};

/* The method with all the built-in thingies */
const UI_METHOD *
UI_OpenSSL(void)
{
	return &ui_openssl;
}

/* The following function makes sure that info and error strings are printed
   before any prompt. */
static int
write_string(UI *ui, UI_STRING *uis)
{
	switch (UI_get_string_type(uis)) {
	case UIT_ERROR:
	case UIT_INFO:
		fputs(UI_get0_output_string(uis), tty_out);
		fflush(tty_out);
		break;
	default:
		break;
	}
	return 1;
}

static int
read_string(UI *ui, UI_STRING *uis)
{
	int ok = 0;

	switch (UI_get_string_type(uis)) {
	case UIT_BOOLEAN:
		fputs(UI_get0_output_string(uis), tty_out);
		fputs(UI_get0_action_string(uis), tty_out);
		fflush(tty_out);
		return read_string_inner(ui, uis,
		    UI_get_input_flags(uis) & UI_INPUT_FLAG_ECHO, 0);
	case UIT_PROMPT:
		fputs(UI_get0_output_string(uis), tty_out);
		fflush(tty_out);
		return read_string_inner(ui, uis,
		    UI_get_input_flags(uis) & UI_INPUT_FLAG_ECHO, 1);
	case UIT_VERIFY:
		fprintf(tty_out, "Verifying - %s",
		    UI_get0_output_string(uis));
		fflush(tty_out);
		if ((ok = read_string_inner(ui, uis, UI_get_input_flags(uis) &
		    UI_INPUT_FLAG_ECHO, 1)) <= 0)
			return ok;
		if (strcmp(UI_get0_result_string(uis),
		    UI_get0_test_string(uis)) != 0) {
			fprintf(tty_out, "Verify failure\n");
			fflush(tty_out);
			return 0;
		}
		break;
	default:
		break;
	}
	return 1;
}


/* Internal functions to read a string without echoing */
static int
read_till_nl(FILE *in)
{
#define SIZE 4
	char buf[SIZE + 1];

	do {
		if (!fgets(buf, SIZE, in))
			return 0;
	} while (strchr(buf, '\n') == NULL);
	return 1;
}

static int
read_string_inner(UI *ui, UI_STRING *uis, int echo, int strip_nl)
{
	static int ps;
	int ok;
	char result[BUFSIZ];
	int maxsize = BUFSIZ - 1;
	char *p;

	ok = 0;
	ps = 0;

	ps = 1;

	if (!echo && !noecho_console(ui))
		goto error;
	ps = 2;

	result[0] = '\0';
	p = fgets(result, maxsize, tty_in);
	if (!p)
		goto error;
	if (feof(tty_in))
		goto error;
	if (ferror(tty_in))
		goto error;
	if ((p = strchr(result, '\n')) != NULL) {
		if (strip_nl)
			*p = '\0';
	} else if (!read_till_nl(tty_in))
		goto error;
	if (UI_set_result(ui, uis, result) >= 0)
		ok = 1;

error:
	if (!echo)
		fprintf(tty_out, "\n");
	if (ps >= 2 && !echo && !echo_console(ui))
		ok = 0;

	explicit_bzero(result, BUFSIZ);
	return ok;
}


/* Internal functions to open, handle and close a channel to the console.  */
static int
open_console(UI *ui)
{
	CRYPTO_w_lock(CRYPTO_LOCK_UI);
	is_a_tty = 1;

	tty_in = stdin;
	tty_out = stderr;

	HANDLE handle = GetStdHandle(STD_INPUT_HANDLE);
	if (handle != NULL && handle != INVALID_HANDLE_VALUE) {
		if (GetFileType(handle) == FILE_TYPE_CHAR)
			return GetConsoleMode(handle, &console_mode);
		else
			return 1;
	}
	return 0;
}

static int
noecho_console(UI *ui)
{
	HANDLE handle = GetStdHandle(STD_INPUT_HANDLE);
	if (handle != NULL && handle != INVALID_HANDLE_VALUE) {
		if (GetFileType(handle) == FILE_TYPE_CHAR)
			return SetConsoleMode(handle, console_mode & ~ENABLE_ECHO_INPUT);
		else
			return 1;
	}
	return 0;
}

static int
echo_console(UI *ui)
{
	HANDLE handle = GetStdHandle(STD_INPUT_HANDLE);
	if (handle != NULL && handle != INVALID_HANDLE_VALUE) {
		if (GetFileType(handle) == FILE_TYPE_CHAR)
			return SetConsoleMode(handle, console_mode);
		else
			return 1;
	}
	return 0;
}

static int
close_console(UI *ui)
{
	if (tty_in != stdin)
		fclose(tty_in);
	if (tty_out != stderr)
		fclose(tty_out);
	CRYPTO_w_unlock(CRYPTO_LOCK_UI);

	return 1;
}
