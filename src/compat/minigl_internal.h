/* minigl_internal.h */

/* Data structures shared between the minigl front end (minigl.c, plain C)
 * and its Metal back end (minigl_metal.m) */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#ifndef MACFSV_MINIGL_INTERNAL_H
#define MACFSV_MINIGL_INTERNAL_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif


/* Triangle vertex (24 bytes). Triangles are always stored with their GL
 * "provoking" vertex first; flat shading takes normal and color from it */
typedef struct {
	float		pos[3];
	int8_t		nrm[4];
	uint8_t		col[4];
	uint16_t	tex[2];
} MGLTriVertex;

/* Line segment (32 bytes). Normal and color are those of the provoking
 * vertex (the second endpoint, or the polygon's for polygon edges) */
typedef struct {
	float		a[3];
	float		b[3];
	int8_t		nrm[4];
	uint8_t		col[4];
} MGLLineSeg;

/* Rendering state that affects rasterization. Kept free of padding
 * holes so that it can be compared with memcmp( ) */
typedef struct {
	uint8_t		lighting;
	uint8_t		light0;
	uint8_t		cull;
	uint8_t		depth_test;
	uint8_t		texture2d;
	uint8_t		blend;
	uint8_t		alpha_test;
	uint8_t		fog;
	uint8_t		line_stipple;
	uint8_t		poly_offset;
	uint8_t		flat;
	uint8_t		pad0;
	uint32_t	depth_func;
	uint32_t	polygon_mode;
	uint32_t	texture;
	uint32_t	stipple_factor;
	uint32_t	stipple_pattern;
	uint32_t	alpha_func;
	float		line_width;
	float		fog_start;
	float		fog_end;
	float		alpha_ref;
} MGLState;

enum {
	MGL_DRAW_TRIS,
	MGL_DRAW_LINES
};

/* One draw call of a frame */
typedef struct {
	MGLState	st;
	float		mv[16];		/* column-major */
	float		proj[16];	/* column-major */
	int		kind;		/* MGL_DRAW_TRIS / MGL_DRAW_LINES */
	void		*buffer;	/* back end buffer, or NULL for the frame's transient arrays */
	size_t		offset;		/* byte offset into buffer (or into transient array) */
	uint32_t	count;		/* vertex count (tris) or segment count (lines) */
} MGLDraw;

typedef struct {
	unsigned int	clear_mask;	/* GL_*_BUFFER_BIT */
	float		clear_color[4];
	int		viewport[4];
	const MGLDraw	*draws;
	size_t		num_draws;
	const MGLTriVertex *tris;
	size_t		num_tris;	/* vertices */
	const MGLLineSeg *lines;
	size_t		num_lines;	/* segments */
} MGLFrame;


/* Back end interface (implemented in minigl_metal.m). */
void *mglb_buffer_create( const void *bytes, size_t length, void **contents );
void mglb_buffer_release( void *buffer );
void mglb_texture_create( unsigned int id, int width, int height, const uint8_t *luminance, int mipmapped, int quantize4 );
void mglb_frame_submit( const MGLFrame *frame );


#ifdef __cplusplus
}
#endif

#endif /* MACFSV_MINIGL_INTERNAL_H */


/* end minigl_internal.h */
