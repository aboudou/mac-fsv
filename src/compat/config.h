/* config.h - hand-written configuration for mac-fsv (replaces autoconf) */

#ifndef MACFSV_CONFIG_H
#define MACFSV_CONFIG_H

#define PACKAGE "fsv"
#define VERSION "0.9"
#define MACFSV_VERSION "1.0"

#define HAVE_SCANDIR 1
#define HAVE_FNMATCH 1
#define HAVE_GETCWD 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_ST_BLOCKS 1
#define HAVE_STRFTIME 1
#define HAVE_FILE_COMMAND 1
#define FILE_COMMAND "/usr/bin/file %s"

#endif
