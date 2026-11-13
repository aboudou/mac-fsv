/* glib.h */

/* Minimal, self-contained replacement for the handful of GLib 1.2
 * facilities used by fsv's core (lists, n-ary trees, memory chunks,
 * string chunks and a few utility macros). This lets mac-fsv build with
 * nothing but the macOS SDK. */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#ifndef MACFSV_GLIB_H
#define MACFSV_GLIB_H

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <float.h>
#include <limits.h>

#ifdef __cplusplus
extern "C" {
#endif


/**** Basic types ****************/

typedef void *gpointer;
typedef const void *gconstpointer;
typedef char gchar;
typedef int gint;
typedef unsigned int guint;
typedef int64_t gint64;
typedef uint8_t guint8;
typedef int gboolean;
typedef double gdouble;
typedef int (*GCompareFunc)( gconstpointer a, gconstpointer b );


/**** Macros ****************/

#ifndef TRUE
#define TRUE	1
#endif
#ifndef FALSE
#define FALSE	0
#endif

#ifndef MIN
#define MIN(a,b)	(((a) < (b)) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a,b)	(((a) > (b)) ? (a) : (b))
#endif
#ifndef ABS
#define ABS(a)		(((a) < 0) ? -(a) : (a))
#endif
#ifndef CLAMP
#define CLAMP(x,lo,hi)	(((x) > (hi)) ? (hi) : (((x) < (lo)) ? (lo) : (x)))
#endif

#define GPOINTER_TO_INT(p)	((gint)(intptr_t)(p))
#define GINT_TO_POINTER(i)	((gpointer)(intptr_t)(i))

void g_log_message( const char *kind, const char *file, int line, const char *fmt, ... );

#define g_assert(expr) \
	do { if (!(expr)) { g_log_message( "assertion failed", __FILE__, __LINE__, "%s", #expr ); abort( ); } } while (0)
#define g_assert_not_reached( ) \
	do { g_log_message( "should not be reached", __FILE__, __LINE__, "%s", "" ); abort( ); } while (0)
#define g_return_val_if_fail(expr,val) \
	do { if (!(expr)) { g_log_message( "check failed", __FILE__, __LINE__, "%s", #expr ); return (val); } } while (0)
#define g_return_if_fail(expr) \
	do { if (!(expr)) { g_log_message( "check failed", __FILE__, __LINE__, "%s", #expr ); return; } } while (0)
#define g_warning(...)	g_log_message( "warning", __FILE__, __LINE__, __VA_ARGS__ )
#define g_message(...)	g_log_message( "message", __FILE__, __LINE__, __VA_ARGS__ )


/**** Memory / strings ****************/

#define g_malloc	malloc
#define g_free		free
char *g_strdup( const char *str );
char *g_dirname( const char *file_name );
const char *g_basename( const char *file_name );


/**** Doubly-linked lists ****************/

typedef struct _GList GList;
struct _GList {
	gpointer data;
	GList *next;
	GList *prev;
};

GList *g_list_alloc( void );
void g_list_free( GList *list );
void g_list_free_1( GList *list );
GList *g_list_append( GList *list, gpointer data );
GList *g_list_prepend( GList *list, gpointer data );
GList *g_list_remove( GList *list, gconstpointer data );
GList *g_list_find( GList *list, gconstpointer data );
GList *g_list_find_custom( GList *list, gconstpointer data, GCompareFunc func );
GList *g_list_last( GList *list );
GList *g_list_first( GList *list );
GList *g_list_nth( GList *list, guint n );
guint g_list_length( GList *list );
GList *g_list_sort( GList *list, GCompareFunc compare_func );


/**** N-ary trees ****************/

/* NOTE: The first three fields must match GList, since fsv sorts the
 * children of a node by casting them to a GList */
typedef struct _GNode GNode;
struct _GNode {
	gpointer data;
	GNode *next;
	GNode *prev;
	GNode *parent;
	GNode *children;
};

GNode *g_node_new( gpointer data );
void g_node_destroy( GNode *root );
void g_node_unlink( GNode *node );
GNode *g_node_insert_before( GNode *parent, GNode *sibling, GNode *node );
GNode *g_node_prepend( GNode *parent, GNode *node );
guint g_node_depth( GNode *node );
gboolean g_node_is_ancestor( GNode *node, GNode *descendant );

#define g_node_append(parent,node)	g_node_insert_before( (parent), NULL, (node) )
#define g_node_append_data(parent,data)	g_node_insert_before( (parent), NULL, g_node_new( data ) )
#define g_node_prepend_data(parent,data) g_node_prepend( (parent), g_node_new( data ) )


/**** Memory chunks ****************/

#define G_ALLOC_ONLY	1
#define G_ALLOC_AND_FREE 2

typedef struct _GMemChunk GMemChunk;

GMemChunk *g_mem_chunk_new( const char *name, int atom_size, unsigned long area_size, int type );
gpointer g_mem_chunk_alloc( GMemChunk *mem_chunk );
void g_mem_chunk_reset( GMemChunk *mem_chunk );
void g_mem_chunk_destroy( GMemChunk *mem_chunk );
void g_blow_chunks( void );

#define g_mem_chunk_create(type,pre_alloc,alloc_type) \
	g_mem_chunk_new( #type, sizeof(type), sizeof(type) * (pre_alloc), (alloc_type) )


/**** String chunks ****************/

typedef struct _GStringChunk GStringChunk;

GStringChunk *g_string_chunk_new( int size );
char *g_string_chunk_insert( GStringChunk *chunk, const char *string );
void g_string_chunk_free( GStringChunk *chunk );


#ifdef __cplusplus
}
#endif

#endif /* MACFSV_GLIB_H */


/* end glib.h */
