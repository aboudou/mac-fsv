/* minigl.c */

/* minigl front end: OpenGL 1.1 state machine, primitive assembly,
 * display lists and GL_SELECT picking. Rasterization is delegated to
 * the Metal back end (minigl_metal.m).
 *
 * Design notes:
 *  - Primitives are assembled at glEnd( ) into triangles (provoking
 *    vertex first, so flat shading matches GL), polygon edges (used when
 *    glPolygonMode is GL_LINE, honoring edge flags) and line segments.
 *  - Display lists are "flattened": nested glCallList( )s and matrix
 *    operations are baked into the list's geometry (relative to the
 *    modelview matrix in effect at glNewList( )), and primitives are
 *    grouped by the state changes made inside the list. A list call
 *    then costs only a few draw calls, whatever its depth. Rendering
 *    state that a list does not set itself is inherited at call time,
 *    as in GL (fsv draws the same list filled, then as "cel lines").
 *  - Picking is done on the CPU: primitives are clipped against the
 *    pick volume and hit records are produced as in GL_SELECT mode. */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#include "GL/gl.h"
#include "GL/glu.h"
#include "minigl_internal.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>


#define MAX_MATRIX_DEPTH	32
#define MAX_NAMES		8
#define MAX_COMPILE_DEPTH	8
#define PI			3.14159265358979323846


/**** Dynamic arrays ****************/

typedef struct {
	void *data;
	size_t n;
	size_t cap;
	size_t esize;
} Vec;

typedef int Int2[2];
typedef int Int3[3];
typedef int Int4[4];

#define VEC_INIT(type)		{ NULL, 0, 0, sizeof(type) }
#define VEC_AT(v,type,i)	(((type *)(v).data)[i])

static void *
vec_push( Vec *v, size_t count )
{
	size_t new_cap;
	void *p;

	if ((v->n + count) > v->cap) {
		new_cap = (v->cap > 0) ? (2 * v->cap) : 256;
		while (new_cap < (v->n + count))
			new_cap *= 2;
		v->data = realloc( v->data, new_cap * v->esize );
		if (v->data == NULL) {
			fprintf( stderr, "minigl: out of memory\n" );
			abort( );
		}
		v->cap = new_cap;
	}
	p = (char *)v->data + v->n * v->esize;
	v->n += count;

	return p;
}

static void
vec_free( Vec *v )
{
	free( v->data );
	v->data = NULL;
	v->n = 0;
	v->cap = 0;
}


/**** Matrix math (column-major, as in GL) ****************/

static void
m4_identity( double *m )
{
	memset( m, 0, 16 * sizeof(double) );
	m[0] = m[5] = m[10] = m[15] = 1.0;
}

/* r = a * b (r may alias a or b) */
static void
m4_mul( double *r, const double *a, const double *b )
{
	double t[16];
	int i, j, k;

	for (j = 0; j < 4; j++) {
		for (i = 0; i < 4; i++) {
			double s = 0.0;
			for (k = 0; k < 4; k++)
				s += a[k * 4 + i] * b[j * 4 + k];
			t[j * 4 + i] = s;
		}
	}
	memcpy( r, t, sizeof(t) );
}

static int
m4_invert( double *inv, const double *m )
{
	double t[16], det;
	int i;

	t[0] = m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10];
	t[4] = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10];
	t[8] = m[4]*m[9]*m[15] - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9];
	t[12] = -m[4]*m[9]*m[14] + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9];
	t[1] = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10];
	t[5] = m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10];
	t[9] = -m[0]*m[9]*m[15] + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9];
	t[13] = m[0]*m[9]*m[14] - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9];
	t[2] = m[1]*m[6]*m[15] - m[1]*m[7]*m[14] - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7] - m[13]*m[3]*m[6];
	t[6] = -m[0]*m[6]*m[15] + m[0]*m[7]*m[14] + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7] + m[12]*m[3]*m[6];
	t[10] = m[0]*m[5]*m[15] - m[0]*m[7]*m[13] - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7] - m[12]*m[3]*m[5];
	t[14] = -m[0]*m[5]*m[14] + m[0]*m[6]*m[13] + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6] + m[12]*m[2]*m[5];
	t[3] = -m[1]*m[6]*m[11] + m[1]*m[7]*m[10] + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7] + m[9]*m[3]*m[6];
	t[7] = m[0]*m[6]*m[11] - m[0]*m[7]*m[10] - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7] - m[8]*m[3]*m[6];
	t[11] = -m[0]*m[5]*m[11] + m[0]*m[7]*m[9] + m[4]*m[1]*m[11] - m[4]*m[3]*m[9] - m[8]*m[1]*m[7] + m[8]*m[3]*m[5];
	t[15] = m[0]*m[5]*m[10] - m[0]*m[6]*m[9] - m[4]*m[1]*m[10] + m[4]*m[2]*m[9] + m[8]*m[1]*m[6] - m[8]*m[2]*m[5];

	det = m[0] * t[0] + m[1] * t[4] + m[2] * t[8] + m[3] * t[12];
	if (fabs( det ) < 1.0e-300) {
		m4_identity( inv );
		return 0;
	}
	det = 1.0 / det;
	for (i = 0; i < 16; i++)
		inv[i] = t[i] * det;

	return 1;
}

/* Inverse transpose of the upper-left 3x3 block (row-major n[3][3]) */
static void
m4_normal_matrix( double n[9], const double *m )
{
	double a = m[0], b = m[4], c = m[8];
	double d = m[1], e = m[5], f = m[9];
	double g = m[2], h = m[6], i = m[10];
	double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
	double D = -(b * i - c * h), E = a * i - c * g, F = -(a * h - b * g);
	double G = b * f - c * e, H = -(a * f - c * d), I = a * e - b * d;
	double det = a * A + b * B + c * C;

	if (fabs( det ) < 1.0e-300)
		det = 1.0;
	det = 1.0 / det;
	/* inverse = adj^T / det; inverse transpose = adj / det */
	n[0] = A * det; n[1] = B * det; n[2] = C * det;
	n[3] = D * det; n[4] = E * det; n[5] = F * det;
	n[6] = G * det; n[7] = H * det; n[8] = I * det;
}

static void
m4_xform( double out[4], const double *m, double x, double y, double z )
{
	out[0] = m[0] * x + m[4] * y + m[8] * z + m[12];
	out[1] = m[1] * x + m[5] * y + m[9] * z + m[13];
	out[2] = m[2] * x + m[6] * y + m[10] * z + m[14];
	out[3] = m[3] * x + m[7] * y + m[11] * z + m[15];
}


/**** State ****************/

typedef struct {
	int depth;
	GLuint names[MAX_NAMES];
} NameStack;

/* Bits identifying the fields of MGLState */
enum {
	F_LIGHTING	= 1 << 0,
	F_LIGHT0	= 1 << 1,
	F_CULL		= 1 << 2,
	F_DEPTH_TEST	= 1 << 3,
	F_TEXTURE2D	= 1 << 4,
	F_BLEND		= 1 << 5,
	F_ALPHA_TEST	= 1 << 6,
	F_FOG		= 1 << 7,
	F_LINE_STIPPLE	= 1 << 8,
	F_POLY_OFFSET	= 1 << 9,
	F_FLAT		= 1 << 10,
	F_DEPTH_FUNC	= 1 << 11,
	F_POLY_MODE	= 1 << 12,
	F_TEXTURE	= 1 << 13,
	F_STIPPLE	= 1 << 14,
	F_ALPHA_FUNC	= 1 << 15,
	F_LINE_WIDTH	= 1 << 16,
	F_FOG_PARAMS	= 1 << 17
};

/* Input vertex (between glBegin( ) and glEnd( )) */
typedef struct {
	double	p[3];
	float	n[3];
	float	c[4];
	float	t[2];
	int	e;
} InVert;

static struct {
	MGLState st;
	GLenum matrix_mode;
	double mv[MAX_MATRIX_DEPTH][16];
	int mv_depth;
	double pj[MAX_MATRIX_DEPTH][16];
	int pj_depth;
	unsigned int mv_serial;
	unsigned int pj_serial;
	float color[4];
	float normal[3];
	float tex[2];
	int edge_flag;
	int viewport[4];
	float clear_color[4];
	GLenum render_mode;
	NameStack names;
	GLuint next_texture;
	int initialized;
} G;

#define CUR_MV	(G.mv[G.mv_depth])
#define CUR_PJ	(G.pj[G.pj_depth])


static void
init_state( void )
{
	if (G.initialized)
		return;

	memset( &G, 0, sizeof(G) );
	G.st.depth_func = GL_LESS;
	G.st.polygon_mode = GL_FILL;
	G.st.stipple_factor = 1;
	G.st.stipple_pattern = 0xFFFF;
	G.st.alpha_func = GL_ALWAYS;
	G.st.line_width = 1.0f;
	G.st.fog_start = 0.0f;
	G.st.fog_end = 1.0f;
	G.matrix_mode = GL_MODELVIEW;
	m4_identity( G.mv[0] );
	m4_identity( G.pj[0] );
	G.color[0] = G.color[1] = G.color[2] = G.color[3] = 1.0f;
	G.normal[2] = 1.0f;
	G.edge_flag = 1;
	G.render_mode = GL_RENDER;
	G.next_texture = 1;
	G.viewport[2] = G.viewport[3] = 1;
	G.initialized = 1;
}


static void
apply_delta( MGLState *dst, uint32_t mask, const MGLState *src )
{
	if (mask & F_LIGHTING) dst->lighting = src->lighting;
	if (mask & F_LIGHT0) dst->light0 = src->light0;
	if (mask & F_CULL) dst->cull = src->cull;
	if (mask & F_DEPTH_TEST) dst->depth_test = src->depth_test;
	if (mask & F_TEXTURE2D) dst->texture2d = src->texture2d;
	if (mask & F_BLEND) dst->blend = src->blend;
	if (mask & F_ALPHA_TEST) dst->alpha_test = src->alpha_test;
	if (mask & F_FOG) dst->fog = src->fog;
	if (mask & F_LINE_STIPPLE) dst->line_stipple = src->line_stipple;
	if (mask & F_POLY_OFFSET) dst->poly_offset = src->poly_offset;
	if (mask & F_FLAT) dst->flat = src->flat;
	if (mask & F_DEPTH_FUNC) dst->depth_func = src->depth_func;
	if (mask & F_POLY_MODE) dst->polygon_mode = src->polygon_mode;
	if (mask & F_TEXTURE) dst->texture = src->texture;
	if (mask & F_STIPPLE) {
		dst->stipple_factor = src->stipple_factor;
		dst->stipple_pattern = src->stipple_pattern;
	}
	if (mask & F_ALPHA_FUNC) {
		dst->alpha_func = src->alpha_func;
		dst->alpha_ref = src->alpha_ref;
	}
	if (mask & F_LINE_WIDTH) dst->line_width = src->line_width;
	if (mask & F_FOG_PARAMS) {
		dst->fog_start = src->fog_start;
		dst->fog_end = src->fog_end;
	}
}


/**** Display list data ****************/

typedef struct {
	uint32_t mask;		/* state set inside the list... */
	MGLState vals;		/* ...and the values it was set to */
	/* Geometry, in list space */
	Vec tris;		/* MGLTriVertex */
	Vec edges;		/* MGLLineSeg */
	Vec lines;		/* MGLLineSeg */
	Vec tri_names;		/* uint32_t per triangle (index into list's name stacks) */
	Vec line_names;		/* uint32_t per line segment */
	/* Finalized storage */
	void *buffer;
	const unsigned char *contents;
	size_t num_tris, num_edges, num_lines;
	size_t off_tris, off_edges, off_lines;
} ListGroup;

typedef struct {
	int valid;
	int compiling;
	ListGroup *groups;
	int num_groups;
	int cap_groups;
	Vec stacks;		/* NameStack */
	/* Lasting effects of the list on GL state */
	uint32_t final_mask;
	MGLState final_vals;
	int sets_color;
	float color[4];
	int sets_normal;
	float normal[3];
	int sets_names;
	NameStack names;
} DList;

typedef struct {
	DList *dl;
	GLenum mode;
	double base_inv[16];
	double R[16];		/* list-space <- object-space transform */
	double Rn[9];
	unsigned int R_serial;
	int R_identity;
	uint32_t mask;
	MGLState vals;
	int last_stack;
} CompileCtx;

static DList **dlists = NULL;
static GLuint num_dlists = 0;

static CompileCtx cstack[MAX_COMPILE_DEPTH];
static int cdepth = 0;


/* TRUE if commands should be executed (not just compiled) */
static int
executing( void )
{
	int i;

	for (i = 0; i < cdepth; i++)
		if (cstack[i].mode == GL_COMPILE)
			return 0;

	return 1;
}


#define STATE_OP(bit, field, value) \
	do { \
		int i_; \
		if (executing( )) \
			G.st.field = (value); \
		for (i_ = 0; i_ < cdepth; i_++) { \
			cstack[i_].mask |= (bit); \
			cstack[i_].vals.field = (value); \
		} \
	} while (0)


/**** Frame being rendered ****************/

static Vec frame_draws = VEC_INIT(MGLDraw);
static Vec frame_tris = VEC_INIT(MGLTriVertex);
static Vec frame_lines = VEC_INIT(MGLLineSeg);
static unsigned int frame_clear_mask = 0;

static float cur_mv_f[16], cur_pj_f[16];
static unsigned int cur_mv_f_serial = ~0u, cur_pj_f_serial = ~0u;


static void
update_float_matrices( void )
{
	int i;

	if (cur_mv_f_serial != G.mv_serial) {
		for (i = 0; i < 16; i++)
			cur_mv_f[i] = (float)CUR_MV[i];
		cur_mv_f_serial = G.mv_serial;
	}
	if (cur_pj_f_serial != G.pj_serial) {
		for (i = 0; i < 16; i++)
			cur_pj_f[i] = (float)CUR_PJ[i];
		cur_pj_f_serial = G.pj_serial;
	}
}


static void
add_draw( const MGLState *st, int kind, void *buffer, size_t offset, uint32_t count )
{
	MGLDraw *d;
	size_t esize;

	if (count == 0)
		return;

	update_float_matrices( );

	/* Merge with previous draw if possible */
	if ((buffer == NULL) && (frame_draws.n > 0)) {
		d = &VEC_AT(frame_draws, MGLDraw, frame_draws.n - 1);
		esize = (kind == MGL_DRAW_TRIS) ? sizeof(MGLTriVertex) : sizeof(MGLLineSeg);
		if ((d->buffer == NULL) && (d->kind == kind) && ((d->offset + d->count * esize) == offset) && !memcmp( &d->st, st, sizeof(MGLState) ) && !memcmp( d->mv, cur_mv_f, sizeof(cur_mv_f) ) && !memcmp( d->proj, cur_pj_f, sizeof(cur_pj_f) )) {
			d->count += count;
			return;
		}
	}

	d = vec_push( &frame_draws, 1 );
	d->st = *st;
	memcpy( d->mv, cur_mv_f, sizeof(cur_mv_f) );
	memcpy( d->proj, cur_pj_f, sizeof(cur_pj_f) );
	d->kind = kind;
	d->buffer = buffer;
	d->offset = offset;
	d->count = count;
}


/**** Selection (picking) ****************/

static GLuint *sel_buffer = NULL;
static GLsizei sel_size = 0;
static GLsizei sel_pos = 0;
static GLint sel_hits = 0;
static int sel_overflow = 0;
static int hit_pending = 0;
static double hit_minz, hit_maxz;
static NameStack hit_names;


static int
names_equal( const NameStack *a, const NameStack *b )
{
	int i;

	if (a->depth != b->depth)
		return 0;
	for (i = 0; i < a->depth; i++)
		if (a->names[i] != b->names[i])
			return 0;

	return 1;
}


static void
sel_flush( void )
{
	int i;

	if (!hit_pending)
		return;
	hit_pending = 0;

	if ((sel_pos + 3 + hit_names.depth) > sel_size) {
		sel_overflow = 1;
		return;
	}
	sel_buffer[sel_pos++] = (GLuint)hit_names.depth;
	sel_buffer[sel_pos++] = (GLuint)(hit_minz * 4294967295.0);
	sel_buffer[sel_pos++] = (GLuint)(hit_maxz * 4294967295.0);
	for (i = 0; i < hit_names.depth; i++)
		sel_buffer[sel_pos++] = hit_names.names[i];
	++sel_hits;
}


static void
sel_hit( double zmin, double zmax, const NameStack *ns )
{
	zmin = (zmin < 0.0) ? 0.0 : ((zmin > 1.0) ? 1.0 : zmin);
	zmax = (zmax < 0.0) ? 0.0 : ((zmax > 1.0) ? 1.0 : zmax);

	if (hit_pending && !names_equal( &hit_names, ns ))
		sel_flush( );

	if (!hit_pending) {
		hit_pending = 1;
		hit_names = *ns;
		hit_minz = zmin;
		hit_maxz = zmax;
	}
	else {
		if (zmin < hit_minz)
			hit_minz = zmin;
		if (zmax > hit_maxz)
			hit_maxz = zmax;
	}
}


/* Signed distance of a clip-space point to one of the six frustum planes */
static double
plane_dist( const double *v, int plane )
{
	switch (plane) {
		case 0: return v[3] + v[0];
		case 1: return v[3] - v[0];
		case 2: return v[3] + v[1];
		case 3: return v[3] - v[1];
		case 4: return v[3] + v[2];
		default: return v[3] - v[2];
	}
}


/* Tests a triangle (clip-space coordinates) against the pick volume */
static void
sel_test_tri( double c[3][4], int cull, const NameStack *ns )
{
	double buf_a[12][4], buf_b[12][4];
	double (*in)[4] = buf_a, (*out)[4] = buf_b, (*tmp)[4];
	double d0, d1, k, area, zmin, zmax, z;
	double x0, y0, x1, y1;
	int n = 3, m, plane, i, j;

	/* Trivial rejection */
	for (plane = 0; plane < 6; plane++)
		if ((plane_dist( c[0], plane ) < 0.0) && (plane_dist( c[1], plane ) < 0.0) && (plane_dist( c[2], plane ) < 0.0))
			return;

	memcpy( in, c, 3 * sizeof(c[0]) );

	/* Sutherland-Hodgman clipping */
	for (plane = 0; plane < 6; plane++) {
		m = 0;
		for (i = 0; i < n; i++) {
			j = (i + 1) % n;
			d0 = plane_dist( in[i], plane );
			d1 = plane_dist( in[j], plane );
			if (d0 >= 0.0)
				memcpy( out[m++], in[i], sizeof(in[0]) );
			if ((d0 >= 0.0) != (d1 >= 0.0)) {
				k = d0 / (d0 - d1);
				out[m][0] = in[i][0] + k * (in[j][0] - in[i][0]);
				out[m][1] = in[i][1] + k * (in[j][1] - in[i][1]);
				out[m][2] = in[i][2] + k * (in[j][2] - in[i][2]);
				out[m][3] = in[i][3] + k * (in[j][3] - in[i][3]);
				++m;
			}
		}
		n = m;
		if (n < 3)
			return;
		tmp = in;
		in = out;
		out = tmp;
	}

	/* Face culling (counterclockwise polygons face front) */
	if (cull) {
		area = 0.0;
		for (i = 0; i < n; i++) {
			j = (i + 1) % n;
			x0 = in[i][0] / in[i][3];
			y0 = in[i][1] / in[i][3];
			x1 = in[j][0] / in[j][3];
			y1 = in[j][1] / in[j][3];
			area += x0 * y1 - x1 * y0;
		}
		if (area < 0.0)
			return;
	}

	zmin = 1.0;
	zmax = 0.0;
	for (i = 0; i < n; i++) {
		z = 0.5 * (in[i][2] / in[i][3]) + 0.5;
		if (z < zmin)
			zmin = z;
		if (z > zmax)
			zmax = z;
	}

	sel_hit( zmin, zmax, ns );
}


/* Tests a line segment (clip-space coordinates) against the pick volume */
static void
sel_test_seg( double c[2][4], const NameStack *ns )
{
	double t0 = 0.0, t1 = 1.0, d0, d1, t;
	double za, zb, wa, wb;
	int plane;

	for (plane = 0; plane < 6; plane++) {
		d0 = plane_dist( c[0], plane );
		d1 = plane_dist( c[1], plane );
		if ((d0 < 0.0) && (d1 < 0.0))
			return;
		if (d0 < 0.0) {
			t = d0 / (d0 - d1);
			if (t > t0)
				t0 = t;
		}
		else if (d1 < 0.0) {
			t = d0 / (d0 - d1);
			if (t < t1)
				t1 = t;
		}
	}
	if (t0 > t1)
		return;

	za = c[0][2] + t0 * (c[1][2] - c[0][2]);
	wa = c[0][3] + t0 * (c[1][3] - c[0][3]);
	zb = c[0][2] + t1 * (c[1][2] - c[0][2]);
	wb = c[0][3] + t1 * (c[1][3] - c[0][3]);
	za = 0.5 * za / wa + 0.5;
	zb = 0.5 * zb / wb + 0.5;

	sel_hit( (za < zb) ? za : zb, (za < zb) ? zb : za, ns );
}


/**** Primitive assembly ****************/

static Vec in_verts = VEC_INIT(InVert);
static GLenum prim_mode;
static int in_begin = 0;

static Vec a_tris = VEC_INIT(Int3);		/* vertex indices, provoking first */
static Vec a_edges = VEC_INIT(Int4);		/* a, b, provoking, polygon */
static Vec a_lines = VEC_INIT(Int2);		/* a, b (provoking = b) */
static Vec a_polys = VEC_INIT(Int2);		/* first index, count */
static Vec a_polyidx = VEC_INIT(int);


static void
add_polygon( const int *idx, int n, int prov_pos, int use_edge_flags )
{
	const InVert *v = (const InVert *)in_verts.data;
	int *p, *poly;
	int prov, poly_id, k;

	poly_id = (int)a_polys.n;
	poly = vec_push( &a_polys, 1 );
	poly[0] = (int)a_polyidx.n;
	poly[1] = n;
	p = vec_push( &a_polyidx, (size_t)n );
	memcpy( p, idx, (size_t)n * sizeof(int) );

	/* Fill triangles: fan around the provoking vertex */
	prov = idx[prov_pos];
	for (k = 1; k < (n - 1); k++) {
		p = vec_push( &a_tris, 1 );
		p[0] = prov;
		p[1] = idx[(prov_pos + k) % n];
		p[2] = idx[(prov_pos + k + 1) % n];
	}

	/* Boundary edges */
	for (k = 0; k < n; k++) {
		if (use_edge_flags && !v[idx[k]].e)
			continue;
		p = vec_push( &a_edges, 1 );
		p[0] = idx[k];
		p[1] = idx[(k + 1) % n];
		p[2] = prov;
		p[3] = poly_id;
	}
}


static void
add_line( int a, int b )
{
	int *p = vec_push( &a_lines, 1 );
	p[0] = a;
	p[1] = b;
}


static void
assemble( void )
{
	int n = (int)in_verts.n;
	int idx[4];
	int i;

	a_tris.n = 0;
	a_edges.n = 0;
	a_lines.n = 0;
	a_polys.n = 0;
	a_polyidx.n = 0;

	switch (prim_mode) {
		case GL_TRIANGLES:
		for (i = 0; (i + 2) < n; i += 3) {
			idx[0] = i; idx[1] = i + 1; idx[2] = i + 2;
			add_polygon( idx, 3, 2, 1 );
		}
		break;

		case GL_TRIANGLE_STRIP:
		for (i = 0; (i + 2) < n; i++) {
			if (i & 1) {
				idx[0] = i + 1; idx[1] = i; idx[2] = i + 2;
			}
			else {
				idx[0] = i; idx[1] = i + 1; idx[2] = i + 2;
			}
			add_polygon( idx, 3, 2, 0 );
		}
		break;

		case GL_TRIANGLE_FAN:
		for (i = 1; (i + 1) < n; i++) {
			idx[0] = 0; idx[1] = i; idx[2] = i + 1;
			add_polygon( idx, 3, 2, 0 );
		}
		break;

		case GL_QUADS:
		for (i = 0; (i + 3) < n; i += 4) {
			idx[0] = i; idx[1] = i + 1; idx[2] = i + 2; idx[3] = i + 3;
			add_polygon( idx, 4, 3, 1 );
		}
		break;

		case GL_QUAD_STRIP:
		for (i = 0; (i + 3) < n; i += 2) {
			idx[0] = i; idx[1] = i + 1; idx[2] = i + 3; idx[3] = i + 2;
			add_polygon( idx, 4, 2, 0 );
		}
		break;

		case GL_POLYGON:
		if (n >= 3) {
			int *all = malloc( (size_t)n * sizeof(int) );
			for (i = 0; i < n; i++)
				all[i] = i;
			add_polygon( all, n, 0, 1 );
			free( all );
		}
		break;

		case GL_LINES:
		for (i = 0; (i + 1) < n; i += 2)
			add_line( i, i + 1 );
		break;

		case GL_LINE_STRIP:
		for (i = 0; (i + 1) < n; i++)
			add_line( i, i + 1 );
		break;

		case GL_LINE_LOOP:
		for (i = 0; (i + 1) < n; i++)
			add_line( i, i + 1 );
		if (n > 2)
			add_line( n - 1, 0 );
		break;

		default:
		/* GL_POINTS: not supported */
		break;
	}
}


/* Vertex conversion helpers. R/Rn may be NULL (identity) */

static void
encode_normal( int8_t out[4], const float n[3], const double *Rn )
{
	double x = n[0], y = n[1], z = n[2], len;

	if (Rn != NULL) {
		x = Rn[0] * n[0] + Rn[1] * n[1] + Rn[2] * n[2];
		y = Rn[3] * n[0] + Rn[4] * n[1] + Rn[5] * n[2];
		z = Rn[6] * n[0] + Rn[7] * n[1] + Rn[8] * n[2];
	}
	len = sqrt( x * x + y * y + z * z );
	if (len > 1.0e-12) {
		x /= len;
		y /= len;
		z /= len;
	}
	out[0] = (int8_t)lrint( 127.0 * x );
	out[1] = (int8_t)lrint( 127.0 * y );
	out[2] = (int8_t)lrint( 127.0 * z );
	out[3] = 0;
}

static uint8_t
encode_color( float c )
{
	if (c <= 0.0f)
		return 0;
	if (c >= 1.0f)
		return 255;
	return (uint8_t)lrintf( 255.0f * c );
}

static uint16_t
encode_tex( float t )
{
	if (t <= 0.0f)
		return 0;
	if (t >= 1.0f)
		return 65535;
	return (uint16_t)lrintf( 65535.0f * t );
}

static void
xform_point( float out[3], const double p[3], const double *R )
{
	if (R == NULL) {
		out[0] = (float)p[0];
		out[1] = (float)p[1];
		out[2] = (float)p[2];
	}
	else {
		out[0] = (float)(R[0] * p[0] + R[4] * p[1] + R[8] * p[2] + R[12]);
		out[1] = (float)(R[1] * p[0] + R[5] * p[1] + R[9] * p[2] + R[13]);
		out[2] = (float)(R[2] * p[0] + R[6] * p[1] + R[10] * p[2] + R[14]);
	}
}

static void
make_tri_vertex( MGLTriVertex *o, const InVert *v, const double *R, const double *Rn )
{
	xform_point( o->pos, v->p, R );
	encode_normal( o->nrm, v->n, Rn );
	o->col[0] = encode_color( v->c[0] );
	o->col[1] = encode_color( v->c[1] );
	o->col[2] = encode_color( v->c[2] );
	o->col[3] = encode_color( v->c[3] );
	o->tex[0] = encode_tex( v->t[0] );
	o->tex[1] = encode_tex( v->t[1] );
}

static void
make_line_seg( MGLLineSeg *o, const InVert *a, const InVert *b, const InVert *prov, const double *R, const double *Rn )
{
	xform_point( o->a, a->p, R );
	xform_point( o->b, b->p, R );
	encode_normal( o->nrm, prov->n, Rn );
	o->col[0] = encode_color( prov->c[0] );
	o->col[1] = encode_color( prov->c[1] );
	o->col[2] = encode_color( prov->c[2] );
	o->col[3] = encode_color( prov->c[3] );
}


/* TRUE if the given assembled polygon faces front (window space) */
static int
polygon_front_facing( int poly_id, const double *mvp )
{
	const InVert *v = (const InVert *)in_verts.data;
	const int *poly = VEC_AT(a_polys, Int2, poly_id);
	const int *idx = &VEC_AT(a_polyidx, int, poly[0]);
	double c[4], x[16], y[16], area = 0.0;
	int n = poly[1], i, j;

	if (n > 16)
		n = 16;
	for (i = 0; i < n; i++) {
		m4_xform( c, mvp, v[idx[i]].p[0], v[idx[i]].p[1], v[idx[i]].p[2] );
		if (c[3] <= 0.0)
			return 1;
		x[i] = c[0] / c[3];
		y[i] = c[1] / c[3];
	}
	for (i = 0; i < n; i++) {
		j = (i + 1) % n;
		area += x[i] * y[j] - x[j] * y[i];
	}

	return area >= 0.0;
}


/* Draws the assembled primitives (immediate mode) */
static void
immediate_render( void )
{
	const InVert *v = (const InVert *)in_verts.data;
	MGLTriVertex *tv;
	MGLLineSeg *ls;
	unsigned char *front = NULL;
	double mvp[16];
	size_t i, first;
	int k, count;

	if ((G.st.polygon_mode != GL_LINE) && (a_tris.n > 0)) {
		first = frame_tris.n;
		tv = vec_push( &frame_tris, 3 * a_tris.n );
		for (i = 0; i < a_tris.n; i++) {
			const int *t = VEC_AT(a_tris, Int3, i);
			for (k = 0; k < 3; k++)
				make_tri_vertex( tv++, &v[t[k]], NULL, NULL );
		}
		add_draw( &G.st, MGL_DRAW_TRIS, NULL, first * sizeof(MGLTriVertex), (uint32_t)(3 * a_tris.n) );
	}

	if ((G.st.polygon_mode == GL_LINE) && (a_edges.n > 0)) {
		if (G.st.cull) {
			/* Back-facing polygons contribute no edges */
			m4_mul( mvp, CUR_PJ, CUR_MV );
			front = malloc( a_polys.n );
			for (i = 0; i < a_polys.n; i++)
				front[i] = (unsigned char)polygon_front_facing( (int)i, mvp );
		}
		first = frame_lines.n;
		count = 0;
		for (i = 0; i < a_edges.n; i++) {
			const int *e = VEC_AT(a_edges, Int4, i);
			if ((front != NULL) && !front[e[3]])
				continue;
			ls = vec_push( &frame_lines, 1 );
			make_line_seg( ls, &v[e[0]], &v[e[1]], &v[e[2]], NULL, NULL );
			++count;
		}
		free( front );
		add_draw( &G.st, MGL_DRAW_LINES, NULL, first * sizeof(MGLLineSeg), (uint32_t)count );
	}

	if (a_lines.n > 0) {
		first = frame_lines.n;
		ls = vec_push( &frame_lines, a_lines.n );
		for (i = 0; i < a_lines.n; i++) {
			const int *l = VEC_AT(a_lines, Int2, i);
			make_line_seg( ls++, &v[l[0]], &v[l[1]], &v[l[1]], NULL, NULL );
		}
		add_draw( &G.st, MGL_DRAW_LINES, NULL, first * sizeof(MGLLineSeg), (uint32_t)a_lines.n );
	}
}


/* Picks the assembled primitives (immediate mode) */
static void
immediate_select( void )
{
	const InVert *v = (const InVert *)in_verts.data;
	double mvp[16], c[3][4];
	size_t i;
	int k;

	m4_mul( mvp, CUR_PJ, CUR_MV );

	for (i = 0; i < a_tris.n; i++) {
		const int *t = VEC_AT(a_tris, Int3, i);
		for (k = 0; k < 3; k++)
			m4_xform( c[k], mvp, v[t[k]].p[0], v[t[k]].p[1], v[t[k]].p[2] );
		sel_test_tri( c, G.st.cull, &G.names );
	}
	for (i = 0; i < a_lines.n; i++) {
		const int *l = VEC_AT(a_lines, Int2, i);
		for (k = 0; k < 2; k++)
			m4_xform( c[k], mvp, v[l[k]].p[0], v[l[k]].p[1], v[l[k]].p[2] );
		sel_test_seg( c, &G.names );
	}
}


/**** Display list recording ****************/

static void
ctx_update_R( CompileCtx *ctx )
{
	int i;

	if (ctx->R_serial == G.mv_serial)
		return;

	m4_mul( ctx->R, ctx->base_inv, CUR_MV );
	m4_normal_matrix( ctx->Rn, ctx->R );
	ctx->R_identity = 1;
	for (i = 0; i < 16; i++) {
		double id = ((i % 5) == 0) ? 1.0 : 0.0;
		if (fabs( ctx->R[i] - id ) > 1.0e-12) {
			ctx->R_identity = 0;
			break;
		}
	}
	ctx->R_serial = G.mv_serial;
}


static ListGroup *
list_group( DList *dl, uint32_t mask, const MGLState *vals )
{
	MGLState masked_a, masked_b;
	ListGroup *g;
	int i;

	/* Compare only the fields covered by the mask */
	memset( &masked_b, 0, sizeof(masked_b) );
	apply_delta( &masked_b, mask, vals );

	for (i = dl->num_groups - 1; i >= 0; i--) {
		g = &dl->groups[i];
		if (g->mask != mask)
			continue;
		memset( &masked_a, 0, sizeof(masked_a) );
		apply_delta( &masked_a, mask, &g->vals );
		if (!memcmp( &masked_a, &masked_b, sizeof(MGLState) ))
			return g;
	}

	if (dl->num_groups == dl->cap_groups) {
		dl->cap_groups = (dl->cap_groups > 0) ? (2 * dl->cap_groups) : 4;
		dl->groups = realloc( dl->groups, (size_t)dl->cap_groups * sizeof(ListGroup) );
	}
	g = &dl->groups[dl->num_groups++];
	memset( g, 0, sizeof(ListGroup) );
	g->mask = mask;
	g->vals = masked_b;
	g->tris.esize = sizeof(MGLTriVertex);
	g->edges.esize = sizeof(MGLLineSeg);
	g->lines.esize = sizeof(MGLLineSeg);
	g->tri_names.esize = sizeof(uint32_t);
	g->line_names.esize = sizeof(uint32_t);

	return g;
}


static uint32_t
ctx_name_index( CompileCtx *ctx )
{
	DList *dl = ctx->dl;
	NameStack *ns;

	if ((ctx->last_stack >= 0) && names_equal( &VEC_AT(dl->stacks, NameStack, ctx->last_stack), &G.names ))
		return (uint32_t)ctx->last_stack;

	ns = vec_push( &dl->stacks, 1 );
	*ns = G.names;
	ctx->last_stack = (int)dl->stacks.n - 1;

	return (uint32_t)ctx->last_stack;
}


/* Records the assembled primitives into a list being compiled */
static void
record_prims( CompileCtx *ctx )
{
	const InVert *v = (const InVert *)in_verts.data;
	const double *R, *Rn;
	ListGroup *g;
	MGLTriVertex *tv;
	MGLLineSeg *ls;
	uint32_t name_idx, *np;
	int want_tris = 1, want_edges = 1;
	size_t i;
	int k;

	if ((a_tris.n == 0) && (a_lines.n == 0))
		return;

	ctx_update_R( ctx );
	R = ctx->R_identity ? NULL : ctx->R;
	Rn = ctx->R_identity ? NULL : ctx->Rn;

	if (ctx->mask & F_POLY_MODE) {
		want_tris = ctx->vals.polygon_mode != GL_LINE;
		want_edges = ctx->vals.polygon_mode == GL_LINE;
	}

	g = list_group( ctx->dl, ctx->mask, &ctx->vals );
	name_idx = ctx_name_index( ctx );

	if (want_tris && (a_tris.n > 0)) {
		tv = vec_push( &g->tris, 3 * a_tris.n );
		np = vec_push( &g->tri_names, a_tris.n );
		for (i = 0; i < a_tris.n; i++) {
			const int *t = VEC_AT(a_tris, Int3, i);
			for (k = 0; k < 3; k++)
				make_tri_vertex( tv++, &v[t[k]], R, Rn );
			np[i] = name_idx;
		}
	}

	if (want_edges && (a_edges.n > 0)) {
		ls = vec_push( &g->edges, a_edges.n );
		for (i = 0; i < a_edges.n; i++) {
			const int *e = VEC_AT(a_edges, Int4, i);
			make_line_seg( ls++, &v[e[0]], &v[e[1]], &v[e[2]], R, Rn );
		}
	}

	if (a_lines.n > 0) {
		ls = vec_push( &g->lines, a_lines.n );
		np = vec_push( &g->line_names, a_lines.n );
		for (i = 0; i < a_lines.n; i++) {
			const int *l = VEC_AT(a_lines, Int2, i);
			make_line_seg( ls++, &v[l[0]], &v[l[1]], &v[l[1]], R, Rn );
			np[i] = name_idx;
		}
	}
}


static const MGLTriVertex *
group_tris( const ListGroup *g )
{
	return (g->contents != NULL) ? (const MGLTriVertex *)(g->contents + g->off_tris) : (const MGLTriVertex *)g->tris.data;
}

static const MGLLineSeg *
group_edges( const ListGroup *g )
{
	return (g->contents != NULL) ? (const MGLLineSeg *)(g->contents + g->off_edges) : (const MGLLineSeg *)g->edges.data;
}

static const MGLLineSeg *
group_lines( const ListGroup *g )
{
	return (g->contents != NULL) ? (const MGLLineSeg *)(g->contents + g->off_lines) : (const MGLLineSeg *)g->lines.data;
}


static void
xform_float_point( float out[3], const float p[3], const double *R )
{
	double d[3];

	d[0] = p[0];
	d[1] = p[1];
	d[2] = p[2];
	xform_point( out, d, R );
}

static void
xform_packed_normal( int8_t out[4], const int8_t in[4], const double *Rn )
{
	float n[3];

	if (Rn == NULL) {
		memcpy( out, in, 4 );
		return;
	}
	n[0] = in[0] / 127.0f;
	n[1] = in[1] / 127.0f;
	n[2] = in[2] / 127.0f;
	encode_normal( out, n, Rn );
}


/* Copies (flattens) an existing list into a list being compiled */
static void
record_list_call( CompileCtx *ctx, const DList *src )
{
	const double *R, *Rn;
	const ListGroup *sg;
	ListGroup *g;
	MGLState vals;
	NameStack *ns;
	uint32_t mask, stack_base, *np;
	int want_tris, want_edges;
	size_t i;
	int gi;

	ctx_update_R( ctx );
	R = ctx->R_identity ? NULL : ctx->R;
	Rn = ctx->R_identity ? NULL : ctx->Rn;

	/* Import the source list's name stacks */
	stack_base = (uint32_t)ctx->dl->stacks.n;
	if (src->stacks.n > 0) {
		ns = vec_push( &ctx->dl->stacks, src->stacks.n );
		memcpy( ns, src->stacks.data, src->stacks.n * sizeof(NameStack) );
	}
	ctx->last_stack = -1;

	for (gi = 0; gi < src->num_groups; gi++) {
		sg = &src->groups[gi];

		mask = ctx->mask | sg->mask;
		vals = ctx->vals;
		apply_delta( &vals, sg->mask, &sg->vals );

		want_tris = want_edges = 1;
		if (mask & F_POLY_MODE) {
			want_tris = vals.polygon_mode != GL_LINE;
			want_edges = vals.polygon_mode == GL_LINE;
		}
		if (!(want_tris && sg->num_tris) && !(want_edges && sg->num_edges) && !sg->num_lines)
			continue;

		g = list_group( ctx->dl, mask, &vals );

		if (want_tris && (sg->num_tris > 0)) {
			const MGLTriVertex *st = group_tris( sg );
			MGLTriVertex *tv = vec_push( &g->tris, sg->num_tris );
			const uint32_t *sn = (const uint32_t *)sg->tri_names.data;
			for (i = 0; i < sg->num_tris; i++) {
				tv[i] = st[i];
				if (R != NULL) {
					xform_float_point( tv[i].pos, st[i].pos, R );
					xform_packed_normal( tv[i].nrm, st[i].nrm, Rn );
				}
			}
			np = vec_push( &g->tri_names, sg->num_tris / 3 );
			for (i = 0; i < (sg->num_tris / 3); i++)
				np[i] = stack_base + sn[i];
		}

		if (want_edges && (sg->num_edges > 0)) {
			const MGLLineSeg *se = group_edges( sg );
			MGLLineSeg *ls = vec_push( &g->edges, sg->num_edges );
			for (i = 0; i < sg->num_edges; i++) {
				ls[i] = se[i];
				if (R != NULL) {
					xform_float_point( ls[i].a, se[i].a, R );
					xform_float_point( ls[i].b, se[i].b, R );
					xform_packed_normal( ls[i].nrm, se[i].nrm, Rn );
				}
			}
		}

		if (sg->num_lines > 0) {
			const MGLLineSeg *sl = group_lines( sg );
			MGLLineSeg *ls = vec_push( &g->lines, sg->num_lines );
			const uint32_t *sn = (const uint32_t *)sg->line_names.data;
			for (i = 0; i < sg->num_lines; i++) {
				ls[i] = sl[i];
				if (R != NULL) {
					xform_float_point( ls[i].a, sl[i].a, R );
					xform_float_point( ls[i].b, sl[i].b, R );
					xform_packed_normal( ls[i].nrm, sl[i].nrm, Rn );
				}
			}
			np = vec_push( &g->line_names, sg->num_lines );
			for (i = 0; i < sg->num_lines; i++)
				np[i] = stack_base + sn[i];
		}
	}

	/* Lasting effects of the source list */
	ctx->mask |= src->final_mask;
	apply_delta( &ctx->vals, src->final_mask, &src->final_vals );
	if (src->sets_color) {
		ctx->dl->sets_color = 1;
		memcpy( ctx->dl->color, src->color, sizeof(src->color) );
	}
	if (src->sets_normal) {
		ctx->dl->sets_normal = 1;
		memcpy( ctx->dl->normal, src->normal, sizeof(src->normal) );
	}
	if (src->sets_names) {
		ctx->dl->sets_names = 1;
		ctx->dl->names = src->names;
	}
}


static void
free_list_contents( DList *dl )
{
	ListGroup *g;
	int i;

	for (i = 0; i < dl->num_groups; i++) {
		g = &dl->groups[i];
		vec_free( &g->tris );
		vec_free( &g->edges );
		vec_free( &g->lines );
		vec_free( &g->tri_names );
		vec_free( &g->line_names );
		if (g->buffer != NULL)
			mglb_buffer_release( g->buffer );
	}
	free( dl->groups );
	vec_free( &dl->stacks );
	memset( dl, 0, sizeof(DList) );
	dl->stacks.esize = sizeof(NameStack);
}


/* Moves a compiled list's geometry into a GPU-visible buffer */
static void
finalize_list( DList *dl )
{
	ListGroup *g;
	size_t total;
	unsigned char *bytes;
	void *contents;
	int i;

	for (i = 0; i < dl->num_groups; i++) {
		g = &dl->groups[i];
		g->num_tris = g->tris.n;
		g->num_edges = g->edges.n;
		g->num_lines = g->lines.n;
		g->off_tris = 0;
		g->off_edges = g->num_tris * sizeof(MGLTriVertex);
		g->off_lines = g->off_edges + g->num_edges * sizeof(MGLLineSeg);
		total = g->off_lines + g->num_lines * sizeof(MGLLineSeg);
		if (total == 0)
			continue;

		bytes = malloc( total );
		if (g->num_tris > 0)
			memcpy( bytes + g->off_tris, g->tris.data, g->num_tris * sizeof(MGLTriVertex) );
		if (g->num_edges > 0)
			memcpy( bytes + g->off_edges, g->edges.data, g->num_edges * sizeof(MGLLineSeg) );
		if (g->num_lines > 0)
			memcpy( bytes + g->off_lines, g->lines.data, g->num_lines * sizeof(MGLLineSeg) );

		contents = NULL;
		g->buffer = mglb_buffer_create( bytes, total, &contents );
		if ((g->buffer != NULL) && (contents != NULL)) {
			g->contents = contents;
			free( bytes );
			vec_free( &g->tris );
			vec_free( &g->edges );
			vec_free( &g->lines );
		}
		else {
			free( bytes );
			if (g->buffer != NULL) {
				mglb_buffer_release( g->buffer );
				g->buffer = NULL;
			}
		}
	}
	dl->valid = 1;
}


static void
render_list( const DList *dl )
{
	const ListGroup *g;
	MGLState eff;
	int i;

	for (i = 0; i < dl->num_groups; i++) {
		g = &dl->groups[i];
		if (g->buffer == NULL)
			continue;
		eff = G.st;
		apply_delta( &eff, g->mask, &g->vals );
		if ((eff.polygon_mode != GL_LINE) && (g->num_tris > 0))
			add_draw( &eff, MGL_DRAW_TRIS, g->buffer, g->off_tris, (uint32_t)g->num_tris );
		if ((eff.polygon_mode == GL_LINE) && (g->num_edges > 0))
			add_draw( &eff, MGL_DRAW_LINES, g->buffer, g->off_edges, (uint32_t)g->num_edges );
		if (g->num_lines > 0)
			add_draw( &eff, MGL_DRAW_LINES, g->buffer, g->off_lines, (uint32_t)g->num_lines );
	}
}


static void
select_list( const DList *dl )
{
	const NameStack *stacks = (const NameStack *)dl->stacks.data;
	const ListGroup *g;
	const MGLTriVertex *tv;
	const MGLLineSeg *ls;
	const uint32_t *names;
	MGLState eff;
	double mvp[16], c[3][4];
	size_t i;
	int gi, k;

	m4_mul( mvp, CUR_PJ, CUR_MV );

	for (gi = 0; gi < dl->num_groups; gi++) {
		g = &dl->groups[gi];
		eff = G.st;
		apply_delta( &eff, g->mask, &g->vals );

		tv = group_tris( g );
		names = (const uint32_t *)g->tri_names.data;
		for (i = 0; (i + 2) < g->num_tris; i += 3) {
			for (k = 0; k < 3; k++)
				m4_xform( c[k], mvp, tv[i + k].pos[0], tv[i + k].pos[1], tv[i + k].pos[2] );
			sel_test_tri( c, eff.cull, &stacks[names[i / 3]] );
		}

		ls = group_lines( g );
		names = (const uint32_t *)g->line_names.data;
		for (i = 0; i < g->num_lines; i++) {
			m4_xform( c[0], mvp, ls[i].a[0], ls[i].a[1], ls[i].a[2] );
			m4_xform( c[1], mvp, ls[i].b[0], ls[i].b[1], ls[i].b[2] );
			sel_test_seg( c, &stacks[names[i]] );
		}
	}
}


/**** API: primitives ****************/

void
glBegin( GLenum mode )
{
	init_state( );
	prim_mode = mode;
	in_verts.n = 0;
	in_begin = 1;
}


void
glEnd( void )
{
	int i;

	if (!in_begin)
		return;
	in_begin = 0;

	assemble( );

	if (executing( )) {
		if (G.render_mode == GL_SELECT)
			immediate_select( );
		else if (G.render_mode == GL_RENDER)
			immediate_render( );
	}

	for (i = 0; i < cdepth; i++)
		record_prims( &cstack[i] );

	in_verts.n = 0;
}


static void
emit_vertex( double x, double y, double z )
{
	InVert *v;

	if (!in_begin)
		return;
	v = vec_push( &in_verts, 1 );
	v->p[0] = x;
	v->p[1] = y;
	v->p[2] = z;
	memcpy( v->n, G.normal, sizeof(G.normal) );
	memcpy( v->c, G.color, sizeof(G.color) );
	memcpy( v->t, G.tex, sizeof(G.tex) );
	v->e = G.edge_flag;
}


void
glVertex2d( GLdouble x, GLdouble y )
{
	emit_vertex( x, y, 0.0 );
}


void
glVertex3d( GLdouble x, GLdouble y, GLdouble z )
{
	emit_vertex( x, y, z );
}


void
glNormal3d( GLdouble nx, GLdouble ny, GLdouble nz )
{
	int i;

	init_state( );
	G.normal[0] = (float)nx;
	G.normal[1] = (float)ny;
	G.normal[2] = (float)nz;
	for (i = 0; i < cdepth; i++) {
		cstack[i].dl->sets_normal = 1;
		memcpy( cstack[i].dl->normal, G.normal, sizeof(G.normal) );
	}
}


void
glColor4f( GLfloat r, GLfloat g, GLfloat b, GLfloat a )
{
	int i;

	init_state( );
	G.color[0] = r;
	G.color[1] = g;
	G.color[2] = b;
	G.color[3] = a;
	for (i = 0; i < cdepth; i++) {
		cstack[i].dl->sets_color = 1;
		memcpy( cstack[i].dl->color, G.color, sizeof(G.color) );
	}
}


void
glColor3f( GLfloat r, GLfloat g, GLfloat b )
{
	glColor4f( r, g, b, 1.0f );
}


void
glColor3fv( const GLfloat *v )
{
	glColor4f( v[0], v[1], v[2], 1.0f );
}


void
glTexCoord2d( GLdouble s, GLdouble t )
{
	G.tex[0] = (float)s;
	G.tex[1] = (float)t;
}


void
glEdgeFlag( GLboolean flag )
{
	G.edge_flag = flag ? 1 : 0;
}


/**** API: state ****************/

static void
set_capability( GLenum cap, uint8_t value )
{
	init_state( );

	switch (cap) {
		case GL_LIGHTING: STATE_OP(F_LIGHTING, lighting, value); break;
		case GL_LIGHT0: STATE_OP(F_LIGHT0, light0, value); break;
		case GL_CULL_FACE: STATE_OP(F_CULL, cull, value); break;
		case GL_DEPTH_TEST: STATE_OP(F_DEPTH_TEST, depth_test, value); break;
		case GL_TEXTURE_2D: STATE_OP(F_TEXTURE2D, texture2d, value); break;
		case GL_BLEND: STATE_OP(F_BLEND, blend, value); break;
		case GL_ALPHA_TEST: STATE_OP(F_ALPHA_TEST, alpha_test, value); break;
		case GL_FOG: STATE_OP(F_FOG, fog, value); break;
		case GL_LINE_STIPPLE: STATE_OP(F_LINE_STIPPLE, line_stipple, value); break;
		case GL_POLYGON_OFFSET_FILL: STATE_OP(F_POLY_OFFSET, poly_offset, value); break;
		default:
		/* GL_NORMALIZE (normals are always renormalized),
		 * GL_COLOR_MATERIAL (always on), GL_DITHER: ignored */
		break;
	}
}


void
glEnable( GLenum cap )
{
	set_capability( cap, 1 );
}


void
glDisable( GLenum cap )
{
	set_capability( cap, 0 );
}


void
glDepthFunc( GLenum func )
{
	init_state( );
	STATE_OP(F_DEPTH_FUNC, depth_func, func);
}


void
glPolygonMode( GLenum face, GLenum mode )
{
	(void)face;
	init_state( );
	STATE_OP(F_POLY_MODE, polygon_mode, mode);
}


void
glPolygonOffset( GLfloat factor, GLfloat units )
{
	/* fsv always uses (1, 1); the back end applies it */
	(void)factor;
	(void)units;
}


void
glLineWidth( GLfloat width )
{
	init_state( );
	STATE_OP(F_LINE_WIDTH, line_width, width);
}


void
glLineStipple( GLint factor, GLushort pattern )
{
	int i;

	init_state( );
	if (executing( )) {
		G.st.stipple_factor = (uint32_t)((factor < 1) ? 1 : factor);
		G.st.stipple_pattern = pattern;
	}
	for (i = 0; i < cdepth; i++) {
		cstack[i].mask |= F_STIPPLE;
		cstack[i].vals.stipple_factor = (uint32_t)((factor < 1) ? 1 : factor);
		cstack[i].vals.stipple_pattern = pattern;
	}
}


void
glShadeModel( GLenum mode )
{
	init_state( );
	STATE_OP(F_FLAT, flat, (mode == GL_FLAT) ? 1 : 0);
}


void
glAlphaFunc( GLenum func, GLclampf ref )
{
	int i;

	init_state( );
	if (executing( )) {
		G.st.alpha_func = func;
		G.st.alpha_ref = ref;
	}
	for (i = 0; i < cdepth; i++) {
		cstack[i].mask |= F_ALPHA_FUNC;
		cstack[i].vals.alpha_func = func;
		cstack[i].vals.alpha_ref = ref;
	}
}


void
glBlendFunc( GLenum sfactor, GLenum dfactor )
{
	/* fsv only uses (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA) */
	(void)sfactor;
	(void)dfactor;
}


void
glColorMaterial( GLenum face, GLenum mode )
{
	/* fsv uses (GL_FRONT_AND_BACK, GL_AMBIENT_AND_DIFFUSE), which
	 * the lighting model in the back end implements */
	(void)face;
	(void)mode;
}


void
glLightfv( GLenum light, GLenum pname, const GLfloat *params )
{
	/* fsv's light parameters (a headlight at the eye position,
	 * ambient 0.2, diffuse 0.5, no effective specular) are built
	 * into the back end */
	(void)light;
	(void)pname;
	(void)params;
}


void
glFogf( GLenum pname, GLfloat param )
{
	int i;

	init_state( );
	if ((pname != GL_FOG_START) && (pname != GL_FOG_END))
		return;
	if (executing( )) {
		if (pname == GL_FOG_START)
			G.st.fog_start = param;
		else
			G.st.fog_end = param;
	}
	for (i = 0; i < cdepth; i++) {
		if (!(cstack[i].mask & F_FOG_PARAMS)) {
			cstack[i].vals.fog_start = G.st.fog_start;
			cstack[i].vals.fog_end = G.st.fog_end;
		}
		cstack[i].mask |= F_FOG_PARAMS;
		if (pname == GL_FOG_START)
			cstack[i].vals.fog_start = param;
		else
			cstack[i].vals.fog_end = param;
	}
}


void
glFogi( GLenum pname, GLint param )
{
	/* Only GL_FOG_MODE = GL_LINEAR is used */
	(void)pname;
	(void)param;
}


void
glClearColor( GLclampf r, GLclampf g, GLclampf b, GLclampf a )
{
	init_state( );
	G.clear_color[0] = r;
	G.clear_color[1] = g;
	G.clear_color[2] = b;
	G.clear_color[3] = a;
}


void
glClear( GLbitfield mask )
{
	init_state( );
	if (G.render_mode != GL_RENDER)
		return;

	/* Clearing the color buffer begins a new frame */
	if (mask & GL_COLOR_BUFFER_BIT) {
		frame_draws.n = 0;
		frame_tris.n = 0;
		frame_lines.n = 0;
		frame_clear_mask = 0;
	}
	frame_clear_mask |= mask;
}


void
glViewport( GLint x, GLint y, GLsizei width, GLsizei height )
{
	init_state( );
	G.viewport[0] = x;
	G.viewport[1] = y;
	G.viewport[2] = (width > 0) ? width : 1;
	G.viewport[3] = (height > 0) ? height : 1;
}


void
glGetIntegerv( GLenum pname, GLint *params )
{
	init_state( );
	if (pname == GL_VIEWPORT)
		memcpy( params, G.viewport, sizeof(G.viewport) );
}


void
glGetDoublev( GLenum pname, GLdouble *params )
{
	init_state( );
	if (pname == GL_MODELVIEW_MATRIX)
		memcpy( params, CUR_MV, 16 * sizeof(double) );
	else if (pname == GL_PROJECTION_MATRIX)
		memcpy( params, CUR_PJ, 16 * sizeof(double) );
}


GLenum
glGetError( void )
{
	return GL_NO_ERROR;
}


void
glFlush( void )
{
}


void
mglSwapBuffers( void )
{
	MGLFrame frame;

	init_state( );

	frame.clear_mask = frame_clear_mask;
	memcpy( frame.clear_color, G.clear_color, sizeof(G.clear_color) );
	memcpy( frame.viewport, G.viewport, sizeof(G.viewport) );
	frame.draws = (const MGLDraw *)frame_draws.data;
	frame.num_draws = frame_draws.n;
	frame.tris = (const MGLTriVertex *)frame_tris.data;
	frame.num_tris = frame_tris.n;
	frame.lines = (const MGLLineSeg *)frame_lines.data;
	frame.num_lines = frame_lines.n;

	mglb_frame_submit( &frame );

	frame_draws.n = 0;
	frame_tris.n = 0;
	frame_lines.n = 0;
	frame_clear_mask = 0;
}


/**** API: matrices ****************/

static double *
cur_matrix( void )
{
	return (G.matrix_mode == GL_PROJECTION) ? CUR_PJ : CUR_MV;
}

static void
matrix_changed( void )
{
	if (G.matrix_mode == GL_PROJECTION)
		++G.pj_serial;
	else
		++G.mv_serial;
}


void
glMatrixMode( GLenum mode )
{
	init_state( );
	G.matrix_mode = (mode == GL_PROJECTION) ? GL_PROJECTION : GL_MODELVIEW;
}


void
glLoadIdentity( void )
{
	init_state( );
	m4_identity( cur_matrix( ) );
	matrix_changed( );
}


void
glLoadMatrixd( const GLdouble *m )
{
	init_state( );
	memcpy( cur_matrix( ), m, 16 * sizeof(double) );
	matrix_changed( );
}


void
glMultMatrixd( const GLdouble *m )
{
	double *cm;

	init_state( );
	cm = cur_matrix( );
	m4_mul( cm, cm, m );
	matrix_changed( );
}


void
glPushMatrix( void )
{
	init_state( );
	if (G.matrix_mode == GL_PROJECTION) {
		if (G.pj_depth < (MAX_MATRIX_DEPTH - 1)) {
			memcpy( G.pj[G.pj_depth + 1], G.pj[G.pj_depth], 16 * sizeof(double) );
			++G.pj_depth;
		}
	}
	else {
		if (G.mv_depth < (MAX_MATRIX_DEPTH - 1)) {
			memcpy( G.mv[G.mv_depth + 1], G.mv[G.mv_depth], 16 * sizeof(double) );
			++G.mv_depth;
		}
	}
}


void
glPopMatrix( void )
{
	init_state( );
	if (G.matrix_mode == GL_PROJECTION) {
		if (G.pj_depth > 0)
			--G.pj_depth;
	}
	else {
		if (G.mv_depth > 0)
			--G.mv_depth;
	}
	matrix_changed( );
}


void
glRotated( GLdouble angle, GLdouble x, GLdouble y, GLdouble z )
{
	double m[16], c, s, len, a;

	len = sqrt( x * x + y * y + z * z );
	if (len < 1.0e-12)
		return;
	x /= len;
	y /= len;
	z /= len;
	a = angle * (PI / 180.0);
	c = cos( a );
	s = sin( a );

	m[0] = x * x * (1 - c) + c;
	m[1] = y * x * (1 - c) + z * s;
	m[2] = x * z * (1 - c) - y * s;
	m[3] = 0.0;
	m[4] = x * y * (1 - c) - z * s;
	m[5] = y * y * (1 - c) + c;
	m[6] = y * z * (1 - c) + x * s;
	m[7] = 0.0;
	m[8] = x * z * (1 - c) + y * s;
	m[9] = y * z * (1 - c) - x * s;
	m[10] = z * z * (1 - c) + c;
	m[11] = 0.0;
	m[12] = m[13] = m[14] = 0.0;
	m[15] = 1.0;

	glMultMatrixd( m );
}


void
glTranslated( GLdouble x, GLdouble y, GLdouble z )
{
	double m[16];

	m4_identity( m );
	m[12] = x;
	m[13] = y;
	m[14] = z;
	glMultMatrixd( m );
}


void
glScaled( GLdouble x, GLdouble y, GLdouble z )
{
	double m[16];

	m4_identity( m );
	m[0] = x;
	m[5] = y;
	m[10] = z;
	glMultMatrixd( m );
}


void
glFrustum( GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f )
{
	double m[16];

	memset( m, 0, sizeof(m) );
	m[0] = 2.0 * n / (r - l);
	m[5] = 2.0 * n / (t - b);
	m[8] = (r + l) / (r - l);
	m[9] = (t + b) / (t - b);
	m[10] = -(f + n) / (f - n);
	m[11] = -1.0;
	m[14] = -2.0 * f * n / (f - n);
	glMultMatrixd( m );
}


void
glOrtho( GLdouble l, GLdouble r, GLdouble b, GLdouble t, GLdouble n, GLdouble f )
{
	double m[16];

	m4_identity( m );
	m[0] = 2.0 / (r - l);
	m[5] = 2.0 / (t - b);
	m[10] = -2.0 / (f - n);
	m[12] = -(r + l) / (r - l);
	m[13] = -(t + b) / (t - b);
	m[14] = -(f + n) / (f - n);
	glMultMatrixd( m );
}


/**** API: display lists ****************/

static DList *
get_list( GLuint id )
{
	if ((id == 0) || (id >= num_dlists))
		return NULL;
	return dlists[id];
}


GLuint
glGenLists( GLsizei range )
{
	GLuint first, i;
	GLsizei run = 0;

	init_state( );
	if (range <= 0)
		return 0;

	if (num_dlists == 0)
		num_dlists = 1; /* ID 0 is never used */

	/* Look for a free run of IDs */
	for (first = 1, i = 1; i < num_dlists; i++) {
		if (dlists[i] == NULL) {
			if (run == 0)
				first = i;
			if (++run == range)
				break;
		}
		else
			run = 0;
	}
	if (run < range) {
		first = (run > 0) ? first : num_dlists;
		dlists = realloc( dlists, (size_t)(first + (GLuint)range) * sizeof(DList *) );
		for (i = num_dlists; i < (first + (GLuint)range); i++)
			dlists[i] = NULL;
		num_dlists = first + (GLuint)range;
	}

	for (i = first; i < (first + (GLuint)range); i++) {
		dlists[i] = calloc( 1, sizeof(DList) );
		dlists[i]->stacks.esize = sizeof(NameStack);
	}

	return first;
}


void
glDeleteLists( GLuint list, GLsizei range )
{
	GLuint i;
	DList *dl;

	for (i = list; i < (list + (GLuint)range); i++) {
		dl = get_list( i );
		if ((dl == NULL) || dl->compiling)
			continue;
		free_list_contents( dl );
		free( dl );
		dlists[i] = NULL;
	}
}


void
glNewList( GLuint list, GLenum mode )
{
	CompileCtx *ctx;
	DList *dl;

	init_state( );
	if (cdepth >= MAX_COMPILE_DEPTH)
		return;

	if ((list == 0) || (list >= num_dlists) || (dlists[list] == NULL)) {
		/* Allow lists that were not obtained from glGenLists( ) */
		if (list == 0)
			return;
		if (list >= num_dlists) {
			GLuint i;
			dlists = realloc( dlists, (size_t)(list + 1) * sizeof(DList *) );
			for (i = num_dlists; i <= list; i++)
				dlists[i] = NULL;
			num_dlists = list + 1;
		}
		dlists[list] = calloc( 1, sizeof(DList) );
		dlists[list]->stacks.esize = sizeof(NameStack);
	}

	dl = dlists[list];
	if (dl->compiling)
		return;
	free_list_contents( dl );
	dl->compiling = 1;

	ctx = &cstack[cdepth++];
	memset( ctx, 0, sizeof(CompileCtx) );
	ctx->dl = dl;
	ctx->mode = mode;
	m4_invert( ctx->base_inv, CUR_MV );
	ctx->R_serial = G.mv_serial - 1;
	ctx->last_stack = -1;
}


void
glEndList( void )
{
	CompileCtx *ctx;
	DList *dl;

	if (cdepth == 0)
		return;

	ctx = &cstack[--cdepth];
	dl = ctx->dl;
	dl->final_mask = ctx->mask;
	dl->final_vals = ctx->vals;
	dl->sets_names = 1;
	dl->names = G.names;
	dl->compiling = 0;

	finalize_list( dl );
}


void
glCallList( GLuint list )
{
	DList *dl;
	int i;

	init_state( );
	dl = get_list( list );
	if ((dl == NULL) || !dl->valid || dl->compiling)
		return;

	if (executing( )) {
		if (G.render_mode == GL_SELECT)
			select_list( dl );
		else if (G.render_mode == GL_RENDER)
			render_list( dl );

		/* Lasting effects on GL state */
		apply_delta( &G.st, dl->final_mask, &dl->final_vals );
		if (dl->sets_color)
			memcpy( G.color, dl->color, sizeof(G.color) );
		if (dl->sets_normal)
			memcpy( G.normal, dl->normal, sizeof(G.normal) );
		if (dl->sets_names) {
			if ((G.render_mode == GL_SELECT) && !names_equal( &G.names, &dl->names ))
				sel_flush( );
			G.names = dl->names;
		}
	}

	for (i = 0; i < cdepth; i++)
		record_list_call( &cstack[i], dl );
}


/**** API: selection ****************/

void
glSelectBuffer( GLsizei size, GLuint *buffer )
{
	sel_buffer = buffer;
	sel_size = size;
}


GLint
glRenderMode( GLenum mode )
{
	GLint result = 0;

	init_state( );

	if (G.render_mode == GL_SELECT) {
		sel_flush( );
		result = sel_overflow ? -1 : sel_hits;
	}

	G.render_mode = mode;
	if (mode == GL_SELECT) {
		sel_pos = 0;
		sel_hits = 0;
		sel_overflow = 0;
		hit_pending = 0;
	}

	return result;
}


static void
names_changing( void )
{
	if (G.render_mode == GL_SELECT)
		sel_flush( );
}


void
glInitNames( void )
{
	init_state( );
	names_changing( );
	G.names.depth = 0;
}


void
glLoadName( GLuint name )
{
	init_state( );
	names_changing( );
	if (G.names.depth > 0)
		G.names.names[G.names.depth - 1] = name;
}


void
glPushName( GLuint name )
{
	init_state( );
	names_changing( );
	if (G.names.depth < MAX_NAMES)
		G.names.names[G.names.depth++] = name;
}


void
glPopName( void )
{
	init_state( );
	names_changing( );
	if (G.names.depth > 0)
		--G.names.depth;
}


/**** API: textures ****************/

void
glGenTextures( GLsizei n, GLuint *textures )
{
	GLsizei i;

	init_state( );
	for (i = 0; i < n; i++)
		textures[i] = G.next_texture++;
}


void
glBindTexture( GLenum target, GLuint texture )
{
	(void)target;
	init_state( );
	STATE_OP(F_TEXTURE, texture, texture);
}


void
glTexParameteri( GLenum target, GLenum pname, GLint param )
{
	/* fsv's font texture parameters (clamp, nearest-mipmap-linear
	 * minification, nearest magnification) are built into the back end */
	(void)target;
	(void)pname;
	(void)param;
}


void
glTexParameterfv( GLenum target, GLenum pname, const GLfloat *params )
{
	(void)target;
	(void)pname;
	(void)params;
}


void
glPixelStorei( GLenum pname, GLint param )
{
	(void)pname;
	(void)param;
}


void
glTexImage2D( GLenum target, GLint level, GLint internal_format, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *pixels )
{
	(void)target;
	(void)border;
	init_state( );
	if ((level != 0) || (format != GL_LUMINANCE) || (type != GL_UNSIGNED_BYTE))
		return;
	mglb_texture_create( G.st.texture, width, height, pixels, 0, internal_format == GL_INTENSITY4 );
}


/**** GLU ****************/

void
gluPickMatrix( GLdouble x, GLdouble y, GLdouble width, GLdouble height, GLint viewport[4] )
{
	if ((width <= 0.0) || (height <= 0.0))
		return;

	glTranslated( ((double)viewport[2] - 2.0 * (x - (double)viewport[0])) / width, ((double)viewport[3] - 2.0 * (y - (double)viewport[1])) / height, 0.0 );
	glScaled( (double)viewport[2] / width, (double)viewport[3] / height, 1.0 );
}


GLint
gluBuild2DMipmaps( GLenum target, GLint internal_format, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *data )
{
	(void)target;
	init_state( );
	if ((format != GL_LUMINANCE) || (type != GL_UNSIGNED_BYTE))
		return 1;
	mglb_texture_create( G.st.texture, width, height, data, 1, internal_format == GL_INTENSITY4 );

	return 0;
}


/* end minigl.c */
