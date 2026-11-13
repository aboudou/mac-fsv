/* ogl.c */

/* Primary OpenGL interface */

/* fsv - 3D File System Visualizer
 * Copyright (C)1999 Daniel Richard G. <skunk@mit.edu>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */


#include "common.h"
#include "ogl.h"

#include <GL/gl.h>
#include <GL/glu.h> /* gluPickMatrix( ) */

#include "animation.h" /* redraw( ) */
#include "camera.h"
#include "geometry.h"
#include "gui.h" /* gui_viewport_size( ) */
#include "tmaptext.h" /* text_init( ) */


/* Initializes OpenGL state (mac-fsv: called by the viewport once the
 * Metal back end is ready) */
void
ogl_init( void )
{
	float light_ambient[] = { 0.2, 0.2, 0.2, 1.0 };
	float light_diffuse[] = { 0.5, 0.5, 0.5, 1.0 };
	float light_specular[] = { 0.4, 0.4, 0.4, 1.0 };
	float light_position[] = { 0.0, 0.0, 0.0, 1.0 };

	/* Set viewport size */
	ogl_resize( );

	/* Create the initial modelview matrix
	 * (right-handed coordinate system, +z = straight up,
	 * camera at origin looking in -x direction) */
	glMatrixMode( GL_MODELVIEW );
	glLoadIdentity( );
	glRotated( -90.0, 1.0, 0.0, 0.0 );
	glRotated( -90.0, 0.0, 0.0, 1.0 );
	glPushMatrix( ); /* Matrix will stay just below top of MVM stack */

	/* Set up lighting */
	glEnable( GL_LIGHTING );
	glEnable( GL_LIGHT0 );
	glLightfv( GL_LIGHT0, GL_AMBIENT, light_ambient );
	glLightfv( GL_LIGHT0, GL_DIFFUSE, light_diffuse );
	glLightfv( GL_LIGHT0, GL_SPECULAR, light_specular );
	glLightfv( GL_LIGHT0, GL_POSITION, light_position );

	/* Set up materials */
	glColorMaterial( GL_FRONT_AND_BACK, GL_AMBIENT_AND_DIFFUSE );
	glEnable( GL_COLOR_MATERIAL );

	/* Miscellaneous */
	glAlphaFunc( GL_GEQUAL, 0.0625 );
	glBlendFunc( GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA );
	glEnable( GL_CULL_FACE );
	glShadeModel( GL_FLAT );
	glEnable( GL_DEPTH_TEST );
	glDepthFunc( GL_LEQUAL );
	glEnable( GL_POLYGON_OFFSET_FILL );
	glPolygonOffset( 1.0, 1.0 );
	glClearColor( 0.0, 0.0, 0.0, 0.0 );

	/* Initialize texture-mapped text engine */
	text_init( );
}


/* Changes viewport size, after a window resize */
void
ogl_resize( void )
{
	int width, height;

	gui_viewport_size( &width, &height );
	glViewport( 0, 0, width, height );
}


/* Refreshes viewport after a window unhide, etc. */
void
ogl_refresh( void )
{
	redraw( );
}


/* Returns the viewport's current aspect ratio */
double
ogl_aspect_ratio( void )
{
	GLint viewport[4];

	glGetIntegerv( GL_VIEWPORT, viewport );

	/* aspect_ratio = width / height */
	return (double)viewport[2] / (double)viewport[3];
}


/* Sets up the projection matrix. full_reset should be TRUE unless the
 * current matrix is to be multiplied in */
static void
setup_projection_matrix( boolean full_reset )
{
	double dx, dy;

	dx = camera->near_clip * tan( 0.5 * RAD(camera->fov) );
	dy = dx / ogl_aspect_ratio( );
	glMatrixMode( GL_PROJECTION );
	if (full_reset)
		glLoadIdentity( );
	glFrustum( - dx, dx, - dy, dy, camera->near_clip, camera->far_clip );
}


/* Sets up the modelview matrix */
static void
setup_modelview_matrix( void )
{
	glMatrixMode( GL_MODELVIEW );
	/* Remember, base matrix lives just below top of stack */
	glPopMatrix( );
	glPushMatrix( );

	switch (globals.fsv_mode) {
		case FSV_SPLASH:
		break;

		case FSV_DISCV:
		glTranslated( - camera->distance, 0.0, 0.0 );
		glRotated( 90.0, 0.0, 1.0, 0.0 );
		glRotated( 90.0, 0.0, 0.0, 1.0 );
		glTranslated( - DISCV_CAMERA(camera)->target.x, - DISCV_CAMERA(camera)->target.y, 0.0 );
		break;

		case FSV_MAPV:
		glTranslated( - camera->distance, 0.0, 0.0 );
		glRotated( camera->phi, 0.0, 1.0, 0.0 );
		glRotated( - camera->theta, 0.0, 0.0, 1.0 );
		glTranslated( - MAPV_CAMERA(camera)->target.x, - MAPV_CAMERA(camera)->target.y, - MAPV_CAMERA(camera)->target.z );
		break;

		case FSV_TREEV:
		glTranslated( - camera->distance, 0.0, 0.0 );
		glRotated( camera->phi, 0.0, 1.0, 0.0 );
		glRotated( - camera->theta, 0.0, 0.0, 1.0 );
		glTranslated( TREEV_CAMERA(camera)->target.r, 0.0, - TREEV_CAMERA(camera)->target.z );
		glRotated( 180.0 - TREEV_CAMERA(camera)->target.theta, 0.0, 0.0, 1.0 );
		break;

		SWITCH_FAIL
	}
}


/* (Re)draws the viewport
 * NOTE: Don't call this directly! Use redraw( ) */
void
ogl_draw( void )
{
	static FsvMode prev_mode = FSV_NONE;
	int err;

	geometry_highlight_node( NULL, TRUE );
	glClear( GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT );

	setup_projection_matrix( TRUE );
	setup_modelview_matrix( );
	geometry_draw( TRUE );

	/* mac-fsv: node highlight is drawn last, over the scene */
	geometry_draw_highlight( );

	/* Error check */
	err = glGetError( );
	if (err != 0)
		g_warning( "GL error: 0x%X", err );

	/* First frame after a mode switch is not drawn
	 * (with the exception of splash screen mode) */
	if (globals.fsv_mode != prev_mode) {
		prev_mode = globals.fsv_mode;
                if (globals.fsv_mode != FSV_SPLASH)
			return;
	}

	mglSwapBuffers( );
}


/* mac-fsv: finds the point of the horizontal plane z = plane_z that is
 * seen at viewport pixel (x, y) (origin at top left), using the current
 * camera. Returns FALSE if that pixel doesn't see the plane */
boolean
ogl_unproject( double x, double y, double plane_z, XYZvec *point )
{
	GLint viewport[4];
	double mv[16], pj[16], m[16], inv[16];
	double ndc_x, ndc_y, a[4], b[4], t;
	int i, j, k;

	setup_projection_matrix( TRUE );
	setup_modelview_matrix( );
	glGetIntegerv( GL_VIEWPORT, viewport );
	glGetDoublev( GL_MODELVIEW_MATRIX, mv );
	glGetDoublev( GL_PROJECTION_MATRIX, pj );

	/* m = pj * mv (column-major) */
	for (j = 0; j < 4; j++)
		for (i = 0; i < 4; i++) {
			m[j * 4 + i] = 0.0;
			for (k = 0; k < 4; k++)
				m[j * 4 + i] += pj[k * 4 + i] * mv[j * 4 + k];
		}

	/* Invert m (Gauss-Jordan, on a row-major copy) */
	{
		double aug[4][8], f;
		int r, c, piv;
		for (r = 0; r < 4; r++)
			for (c = 0; c < 4; c++) {
				aug[r][c] = m[c * 4 + r];
				aug[r][c + 4] = (r == c) ? 1.0 : 0.0;
			}
		for (c = 0; c < 4; c++) {
			piv = c;
			for (r = c + 1; r < 4; r++)
				if (ABS(aug[r][c]) > ABS(aug[piv][c]))
					piv = r;
			if (ABS(aug[piv][c]) < 1.0e-300)
				return FALSE;
			if (piv != c)
				for (k = 0; k < 8; k++) {
					f = aug[c][k];
					aug[c][k] = aug[piv][k];
					aug[piv][k] = f;
				}
			f = aug[c][c];
			for (k = 0; k < 8; k++)
				aug[c][k] /= f;
			for (r = 0; r < 4; r++) {
				if (r == c)
					continue;
				f = aug[r][c];
				for (k = 0; k < 8; k++)
					aug[r][k] -= f * aug[c][k];
			}
		}
		for (r = 0; r < 4; r++)
			for (c = 0; c < 4; c++)
				inv[c * 4 + r] = aug[r][c + 4];
	}

	/* Ray through the pixel, from the near to the far clipping plane */
	ndc_x = 2.0 * x / (double)viewport[2] - 1.0;
	ndc_y = 1.0 - 2.0 * y / (double)viewport[3];
	for (i = 0; i < 4; i++) {
		a[i] = inv[i] * ndc_x + inv[4 + i] * ndc_y - inv[8 + i] + inv[12 + i];
		b[i] = inv[i] * ndc_x + inv[4 + i] * ndc_y + inv[8 + i] + inv[12 + i];
	}
	if ((ABS(a[3]) < 1.0e-300) || (ABS(b[3]) < 1.0e-300))
		return FALSE;
	for (i = 0; i < 3; i++) {
		a[i] /= a[3];
		b[i] /= b[3];
	}

	/* Intersection with the plane */
	if (ABS(b[2] - a[2]) < 1.0e-12)
		return FALSE;
	t = (plane_z - a[2]) / (b[2] - a[2]);
	if (t < 0.0)
		return FALSE;
	point->x = a[0] + t * (b[0] - a[0]);
	point->y = a[1] + t * (b[1] - a[1]);
	point->z = plane_z;

	return TRUE;
}


/* This returns an array of names (unsigned ints) of the primitives which
 * occur under the given viewport coordinates (x,y) (where (0,0) indicates
 * the upper left corner). Return value is the number of names (hit records)
 * stored in the select buffer */
int
ogl_select( int x, int y, const GLuint **selectbuf_ptr )
{
	static GLuint selectbuf[1024];
	GLint viewport[4];
	int ogl_y, hit_count;

	glSelectBuffer( 1024, selectbuf );
	glRenderMode( GL_SELECT );

	/* Set up picking matrix */
	glGetIntegerv( GL_VIEWPORT, viewport );
	glMatrixMode( GL_PROJECTION );
	glLoadIdentity( );
	ogl_y = viewport[3] - y;
	gluPickMatrix( (double)x, (double)ogl_y, 1.0, 1.0, viewport );

	/* Draw geometry */
	setup_projection_matrix( FALSE );
	setup_modelview_matrix( );
	geometry_draw( FALSE );

	/* Get the hits */
	hit_count = glRenderMode( GL_RENDER );
	*selectbuf_ptr = selectbuf;

	/* Leave matrices in a usable state */
	setup_projection_matrix( TRUE );
	setup_modelview_matrix( );

	return hit_count;
}


/* end ogl.c */
