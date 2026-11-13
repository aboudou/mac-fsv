/* glib.c */

/* Minimal GLib replacement (see glib.h) */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#include "glib.h"

#include <stdarg.h>


void
g_log_message( const char *kind, const char *file, int line, const char *fmt, ... )
{
	va_list ap;

	fprintf( stderr, "mac-fsv: %s (%s:%d): ", kind, file, line );
	va_start( ap, fmt );
	vfprintf( stderr, fmt, ap );
	va_end( ap );
	fprintf( stderr, "\n" );
	fflush( stderr );
}


static void *
g_xmalloc( size_t size )
{
	void *p = malloc( size );
	if (p == NULL) {
		fprintf( stderr, "mac-fsv: out of memory\n" );
		abort( );
	}
	return p;
}


/**** Strings ****************/

char *
g_strdup( const char *str )
{
	char *s;

	if (str == NULL)
		return NULL;
	s = g_xmalloc( strlen( str ) + 1 );
	strcpy( s, str );
	return s;
}


/* Returns the directory components of a file name (newly allocated) */
char *
g_dirname( const char *file_name )
{
	const char *base;
	size_t len;
	char *dir;

	base = strrchr( file_name, '/' );
	if (base == NULL)
		return g_strdup( "." );
	while ((base > file_name) && (*base == '/'))
		--base;
	len = (size_t)(base - file_name) + 1;
	if ((len == 1) && (file_name[0] == '/'))
		return g_strdup( "/" );
	dir = g_xmalloc( len + 1 );
	memcpy( dir, file_name, len );
	dir[len] = '\0';
	return dir;
}


/* Returns pointer to the last component of a file name */
const char *
g_basename( const char *file_name )
{
	const char *base;

	base = strrchr( file_name, '/' );
	if (base != NULL)
		return base + 1;
	return file_name;
}


/**** Lists ****************/

GList *
g_list_alloc( void )
{
	GList *l = g_xmalloc( sizeof(GList) );
	l->data = NULL;
	l->next = NULL;
	l->prev = NULL;
	return l;
}


void
g_list_free( GList *list )
{
	GList *next;

	while (list != NULL) {
		next = list->next;
		free( list );
		list = next;
	}
}


void
g_list_free_1( GList *list )
{
	free( list );
}


GList *
g_list_last( GList *list )
{
	if (list != NULL)
		while (list->next != NULL)
			list = list->next;
	return list;
}


GList *
g_list_first( GList *list )
{
	if (list != NULL)
		while (list->prev != NULL)
			list = list->prev;
	return list;
}


GList *
g_list_append( GList *list, gpointer data )
{
	GList *new_list, *last;

	new_list = g_list_alloc( );
	new_list->data = data;
	if (list == NULL)
		return new_list;
	last = g_list_last( list );
	last->next = new_list;
	new_list->prev = last;
	return list;
}


/* Like GLib's, this works when given a link in the middle of a list:
 * the new link is inserted just before it */
GList *
g_list_prepend( GList *list, gpointer data )
{
	GList *new_list;

	new_list = g_list_alloc( );
	new_list->data = data;
	if (list != NULL) {
		if (list->prev != NULL) {
			list->prev->next = new_list;
			new_list->prev = list->prev;
		}
		list->prev = new_list;
		new_list->next = list;
	}
	return new_list;
}


GList *
g_list_remove( GList *list, gconstpointer data )
{
	GList *tmp = list;

	while (tmp != NULL) {
		if (tmp->data == data) {
			if (tmp->prev != NULL)
				tmp->prev->next = tmp->next;
			if (tmp->next != NULL)
				tmp->next->prev = tmp->prev;
			if (list == tmp)
				list = list->next;
			free( tmp );
			break;
		}
		tmp = tmp->next;
	}
	return list;
}


GList *
g_list_find( GList *list, gconstpointer data )
{
	while (list != NULL) {
		if (list->data == data)
			break;
		list = list->next;
	}
	return list;
}


GList *
g_list_find_custom( GList *list, gconstpointer data, GCompareFunc func )
{
	while (list != NULL) {
		if (!func( list->data, data ))
			return list;
		list = list->next;
	}
	return NULL;
}


GList *
g_list_nth( GList *list, guint n )
{
	while ((n-- > 0) && (list != NULL))
		list = list->next;
	return list;
}


guint
g_list_length( GList *list )
{
	guint length = 0;

	while (list != NULL) {
		++length;
		list = list->next;
	}
	return length;
}


/* Stable merge sort (same algorithm as GLib) */
static GList *
g_list_sort_merge( GList *l1, GList *l2, GCompareFunc compare_func )
{
	GList list, *l, *lprev;

	l = &list;
	lprev = NULL;

	while ((l1 != NULL) && (l2 != NULL)) {
		if (compare_func( l1->data, l2->data ) <= 0) {
			l->next = l1;
			l = l->next;
			l->prev = lprev;
			lprev = l;
			l1 = l1->next;
		}
		else {
			l->next = l2;
			l = l->next;
			l->prev = lprev;
			lprev = l;
			l2 = l2->next;
		}
	}
	l->next = (l1 != NULL) ? l1 : l2;
	l->next->prev = l;

	list.next->prev = NULL;
	return list.next;
}


GList *
g_list_sort( GList *list, GCompareFunc compare_func )
{
	GList *l1, *l2;

	if ((list == NULL) || (list->next == NULL))
		return list;

	l1 = list;
	l2 = list->next;
	while ((l2 = l2->next) != NULL) {
		if ((l2 = l2->next) == NULL)
			break;
		l1 = l1->next;
	}
	l2 = l1->next;
	l1->next = NULL;

	return g_list_sort_merge( g_list_sort( list, compare_func ), g_list_sort( l2, compare_func ), compare_func );
}


/**** N-ary trees ****************/

GNode *
g_node_new( gpointer data )
{
	GNode *node = g_xmalloc( sizeof(GNode) );

	node->data = data;
	node->next = NULL;
	node->prev = NULL;
	node->parent = NULL;
	node->children = NULL;
	return node;
}


static void
g_nodes_free( GNode *node )
{
	GNode *next;

	while (node != NULL) {
		next = node->next;
		if (node->children != NULL)
			g_nodes_free( node->children );
		free( node );
		node = next;
	}
}


void
g_node_unlink( GNode *node )
{
	if (node->prev != NULL)
		node->prev->next = node->next;
	else if (node->parent != NULL)
		node->parent->children = node->next;
	node->parent = NULL;
	if (node->next != NULL) {
		node->next->prev = node->prev;
		node->next = NULL;
	}
	node->prev = NULL;
}


void
g_node_destroy( GNode *root )
{
	if (root->parent != NULL || root->prev != NULL || root->next != NULL)
		g_node_unlink( root );
	if (root->children != NULL)
		g_nodes_free( root->children );
	free( root );
}


GNode *
g_node_insert_before( GNode *parent, GNode *sibling, GNode *node )
{
	GNode *last;

	node->parent = parent;

	if (sibling != NULL) {
		if (sibling->prev != NULL) {
			node->prev = sibling->prev;
			node->prev->next = node;
			node->next = sibling;
			sibling->prev = node;
		}
		else {
			node->parent->children = node;
			node->next = sibling;
			sibling->prev = node;
		}
	}
	else {
		if (parent->children != NULL) {
			last = parent->children;
			while (last->next != NULL)
				last = last->next;
			node->prev = last;
			last->next = node;
		}
		else
			node->parent->children = node;
	}

	return node;
}


GNode *
g_node_prepend( GNode *parent, GNode *node )
{
	return g_node_insert_before( parent, parent->children, node );
}


guint
g_node_depth( GNode *node )
{
	guint depth = 0;

	while (node != NULL) {
		++depth;
		node = node->parent;
	}
	return depth;
}


/* TRUE if node is an ancestor of descendant */
gboolean
g_node_is_ancestor( GNode *node, GNode *descendant )
{
	if ((node == NULL) || (descendant == NULL))
		return FALSE;

	while (descendant != NULL) {
		if (descendant->parent == node)
			return TRUE;
		descendant = descendant->parent;
	}
	return FALSE;
}


/**** Memory chunks ****************/

struct _GMemChunk {
	size_t atom_size;
	size_t area_size;
	char **areas;
	size_t num_areas;
	size_t cap_areas;
	size_t used;	/* bytes used in last area */
};


GMemChunk *
g_mem_chunk_new( const char *name, int atom_size, unsigned long area_size, int type )
{
	GMemChunk *mc = g_xmalloc( sizeof(GMemChunk) );

	(void)name;
	(void)type;
	/* Keep atoms suitably aligned */
	mc->atom_size = ((size_t)atom_size + 15) & ~(size_t)15;
	mc->area_size = MAX(65536, (size_t)area_size);
	mc->area_size = (mc->area_size / mc->atom_size) * mc->atom_size;
	mc->areas = NULL;
	mc->num_areas = 0;
	mc->cap_areas = 0;
	mc->used = 0;
	return mc;
}


gpointer
g_mem_chunk_alloc( GMemChunk *mc )
{
	char *p;

	if ((mc->num_areas == 0) || ((mc->used + mc->atom_size) > mc->area_size)) {
		if (mc->num_areas == mc->cap_areas) {
			mc->cap_areas = MAX(16, 2 * mc->cap_areas);
			mc->areas = realloc( mc->areas, mc->cap_areas * sizeof(char *) );
			if (mc->areas == NULL)
				abort( );
		}
		mc->areas[mc->num_areas++] = g_xmalloc( mc->area_size );
		mc->used = 0;
	}

	p = mc->areas[mc->num_areas - 1] + mc->used;
	mc->used += mc->atom_size;
	memset( p, 0, mc->atom_size );

	return p;
}


void
g_mem_chunk_reset( GMemChunk *mc )
{
	size_t i;

	for (i = 0; i < mc->num_areas; i++)
		free( mc->areas[i] );
	mc->num_areas = 0;
	mc->used = 0;
}


void
g_mem_chunk_destroy( GMemChunk *mc )
{
	g_mem_chunk_reset( mc );
	free( mc->areas );
	free( mc );
}


void
g_blow_chunks( void )
{
	/* Nothing to do */
}


/**** String chunks ****************/

struct _GStringChunk {
	size_t block_size;
	char **blocks;
	size_t num_blocks;
	size_t cap_blocks;
	size_t used;
	size_t cur_size;
};


GStringChunk *
g_string_chunk_new( int size )
{
	GStringChunk *sc = g_xmalloc( sizeof(GStringChunk) );

	sc->block_size = (size_t)MAX(size, 4096);
	sc->blocks = NULL;
	sc->num_blocks = 0;
	sc->cap_blocks = 0;
	sc->used = 0;
	sc->cur_size = 0;
	return sc;
}


char *
g_string_chunk_insert( GStringChunk *sc, const char *string )
{
	size_t len = strlen( string ) + 1;
	size_t bsize;
	char *p;

	if ((sc->num_blocks == 0) || ((sc->used + len) > sc->cur_size)) {
		if (sc->num_blocks == sc->cap_blocks) {
			sc->cap_blocks = MAX(16, 2 * sc->cap_blocks);
			sc->blocks = realloc( sc->blocks, sc->cap_blocks * sizeof(char *) );
			if (sc->blocks == NULL)
				abort( );
		}
		bsize = MAX(sc->block_size, len);
		sc->blocks[sc->num_blocks++] = g_xmalloc( bsize );
		sc->cur_size = bsize;
		sc->used = 0;
	}

	p = sc->blocks[sc->num_blocks - 1] + sc->used;
	memcpy( p, string, len );
	sc->used += len;

	return p;
}


void
g_string_chunk_free( GStringChunk *sc )
{
	size_t i;

	for (i = 0; i < sc->num_blocks; i++)
		free( sc->blocks[i] );
	free( sc->blocks );
	free( sc );
}


/* end glib.c */
