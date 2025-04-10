/*
 * Public domain
 * stdio.h compatibility shim
 */

#ifndef LIBCRYPTOCOMPAT_STDIO_H
#define LIBCRYPTOCOMPAT_STDIO_H

#ifdef _MSC_VER
#if _MSC_VER >= 1900
#include <../ucrt/stdlib.h>
#include <../ucrt/corecrt_io.h>
#include <../ucrt/stdio.h>
#else
#include <../include/stdio.h>
#endif
#else
#include_next <stdio.h>
#endif

#ifndef HAVE_GETDELIM
#include <sys/types.h>
#define getdelim libressl_getdelim
ssize_t getdelim(char **buf, size_t *bufsiz, int delimiter, FILE *fp);
#endif

#ifndef HAVE_GETLINE
#include <sys/types.h>
#define getline libressl_getline
ssize_t getline(char **buf, size_t *bufsiz, FILE *fp);
#endif

#ifndef HAVE_ASPRINTF
#include <stdarg.h>
#define vasprintf libressl_vasprintf
int vasprintf(char **str, const char *fmt, va_list ap);
#define asprintf libressl_asprintf
int asprintf(char **str, const char *fmt, ...);
#endif

#ifdef _WIN32

#if defined(_MSC_VER)
#define __func__ __FUNCTION__
#endif

void posix_perror(const char *s);
FILE * posix_fopen(const char *path, const char *mode);
char * posix_fgets(char *s, int size, FILE *stream);
int posix_rename(const char *oldpath, const char *newpath);

#ifndef NO_REDEF_POSIX_FUNCTIONS
#define perror(errnum) posix_perror(errnum)
#define fopen(path, mode) posix_fopen(path, mode)
#define fgets(s, size, stream) posix_fgets(s, size, stream)
#define rename(oldpath, newpath) posix_rename(oldpath, newpath)
#endif

#if defined(_MSC_VER) && _MSC_VER < 1900
#define snprintf _snprintf
#endif

#endif

#endif
