/* GL/gl.h */

/* minigl: the subset of OpenGL 1.1 used by fsv, implemented on top of
 * Metal (see minigl.c and minigl_metal.m). Supports immediate mode,
 * display lists, the fixed-function lighting model used by fsv, wide and
 * stippled lines, polygon "line" mode with edge flags, linear fog, a
 * single texture-mapped font, and GL_SELECT picking. */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#ifndef MACFSV_GL_H
#define MACFSV_GL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef unsigned int	GLenum;
typedef unsigned char	GLboolean;
typedef unsigned int	GLbitfield;
typedef void		GLvoid;
typedef signed char	GLbyte;
typedef short		GLshort;
typedef int		GLint;
typedef unsigned char	GLubyte;
typedef unsigned short	GLushort;
typedef unsigned int	GLuint;
typedef int		GLsizei;
typedef float		GLfloat;
typedef float		GLclampf;
typedef double		GLdouble;
typedef double		GLclampd;

#define GL_FALSE			0
#define GL_TRUE				1
#define GL_NO_ERROR			0

/* Primitives */
#define GL_POINTS			0x0000
#define GL_LINES			0x0001
#define GL_LINE_LOOP			0x0002
#define GL_LINE_STRIP			0x0003
#define GL_TRIANGLES			0x0004
#define GL_TRIANGLE_STRIP		0x0005
#define GL_TRIANGLE_FAN			0x0006
#define GL_QUADS			0x0007
#define GL_QUAD_STRIP			0x0008
#define GL_POLYGON			0x0009

/* Matrix modes */
#define GL_MODELVIEW			0x1700
#define GL_PROJECTION			0x1701
#define GL_TEXTURE			0x1702

/* Display lists */
#define GL_COMPILE			0x1300
#define GL_COMPILE_AND_EXECUTE		0x1301

/* Capabilities */
#define GL_LINE_STIPPLE			0x0B24
#define GL_CULL_FACE			0x0B44
#define GL_LIGHTING			0x0B50
#define GL_COLOR_MATERIAL		0x0B57
#define GL_FOG				0x0B60
#define GL_DEPTH_TEST			0x0B71
#define GL_NORMALIZE			0x0BA1
#define GL_ALPHA_TEST			0x0BC0
#define GL_DITHER			0x0BD0
#define GL_BLEND			0x0BE2
#define GL_TEXTURE_2D			0x0DE1
#define GL_POLYGON_OFFSET_FILL		0x8037
#define GL_LIGHT0			0x4000

/* Comparison functions */
#define GL_NEVER			0x0200
#define GL_LESS				0x0201
#define GL_EQUAL			0x0202
#define GL_LEQUAL			0x0203
#define GL_GREATER			0x0204
#define GL_NOTEQUAL			0x0205
#define GL_GEQUAL			0x0206
#define GL_ALWAYS			0x0207

/* Faces / polygon modes / shading */
#define GL_FRONT			0x0404
#define GL_BACK				0x0405
#define GL_FRONT_AND_BACK		0x0408
#define GL_POINT			0x1B00
#define GL_LINE				0x1B01
#define GL_FILL				0x1B02
#define GL_FLAT				0x1D00
#define GL_SMOOTH			0x1D01

/* Lighting */
#define GL_AMBIENT			0x1200
#define GL_DIFFUSE			0x1201
#define GL_SPECULAR			0x1202
#define GL_POSITION			0x1203
#define GL_AMBIENT_AND_DIFFUSE		0x1602

/* Fog */
#define GL_FOG_START			0x0B63
#define GL_FOG_END			0x0B64
#define GL_FOG_MODE			0x0B65
#define GL_EXP				0x0800
#define GL_LINEAR			0x2601

/* Blending */
#define GL_SRC_ALPHA			0x0302
#define GL_ONE_MINUS_SRC_ALPHA		0x0303

/* Buffers */
#define GL_DEPTH_BUFFER_BIT		0x00000100
#define GL_COLOR_BUFFER_BIT		0x00004000
#define GL_FRONT_LEFT			0x0400
#define GL_COLOR			0x1800

/* Queries */
#define GL_VIEWPORT			0x0BA2
#define GL_MODELVIEW_MATRIX		0x0BA6
#define GL_PROJECTION_MATRIX		0x0BA7

/* Render modes */
#define GL_RENDER			0x1C00
#define GL_FEEDBACK			0x1C01
#define GL_SELECT			0x1C02

/* Textures */
#define GL_TEXTURE_BORDER_COLOR		0x1004
#define GL_TEXTURE_MAG_FILTER		0x2800
#define GL_TEXTURE_MIN_FILTER		0x2801
#define GL_TEXTURE_WRAP_S		0x2802
#define GL_TEXTURE_WRAP_T		0x2803
#define GL_NEAREST			0x2600
#define GL_LINEAR_MIPMAP_LINEAR		0x2703
#define GL_NEAREST_MIPMAP_LINEAR	0x2702
#define GL_CLAMP			0x2900
#define GL_UNPACK_ALIGNMENT		0x0CF5
#define GL_LUMINANCE			0x1909
#define GL_INTENSITY4			0x804A
#define GL_UNSIGNED_BYTE		0x1401


/* Primitive specification */
void glBegin( GLenum mode );
void glEnd( void );
void glVertex2d( GLdouble x, GLdouble y );
void glVertex3d( GLdouble x, GLdouble y, GLdouble z );
void glNormal3d( GLdouble nx, GLdouble ny, GLdouble nz );
void glColor3f( GLfloat r, GLfloat g, GLfloat b );
void glColor3fv( const GLfloat *v );
void glColor4f( GLfloat r, GLfloat g, GLfloat b, GLfloat a );
void glTexCoord2d( GLdouble s, GLdouble t );
void glEdgeFlag( GLboolean flag );

/* State */
void glEnable( GLenum cap );
void glDisable( GLenum cap );
void glDepthFunc( GLenum func );
void glPolygonMode( GLenum face, GLenum mode );
void glPolygonOffset( GLfloat factor, GLfloat units );
void glLineWidth( GLfloat width );
void glLineStipple( GLint factor, GLushort pattern );
void glShadeModel( GLenum mode );
void glAlphaFunc( GLenum func, GLclampf ref );
void glBlendFunc( GLenum sfactor, GLenum dfactor );
void glColorMaterial( GLenum face, GLenum mode );
void glLightfv( GLenum light, GLenum pname, const GLfloat *params );
void glFogf( GLenum pname, GLfloat param );
void glFogi( GLenum pname, GLint param );
void glClearColor( GLclampf r, GLclampf g, GLclampf b, GLclampf a );
void glClear( GLbitfield mask );
void glViewport( GLint x, GLint y, GLsizei width, GLsizei height );
void glGetIntegerv( GLenum pname, GLint *params );
void glGetDoublev( GLenum pname, GLdouble *params );
GLenum glGetError( void );
void glFlush( void );

/* Matrices */
void glMatrixMode( GLenum mode );
void glLoadIdentity( void );
void glLoadMatrixd( const GLdouble *m );
void glMultMatrixd( const GLdouble *m );
void glPushMatrix( void );
void glPopMatrix( void );
void glRotated( GLdouble angle, GLdouble x, GLdouble y, GLdouble z );
void glTranslated( GLdouble x, GLdouble y, GLdouble z );
void glScaled( GLdouble x, GLdouble y, GLdouble z );
void glFrustum( GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble near_val, GLdouble far_val );
void glOrtho( GLdouble left, GLdouble right, GLdouble bottom, GLdouble top, GLdouble near_val, GLdouble far_val );

/* Display lists */
GLuint glGenLists( GLsizei range );
void glDeleteLists( GLuint list, GLsizei range );
void glNewList( GLuint list, GLenum mode );
void glEndList( void );
void glCallList( GLuint list );

/* Selection */
void glSelectBuffer( GLsizei size, GLuint *buffer );
GLint glRenderMode( GLenum mode );
void glInitNames( void );
void glLoadName( GLuint name );
void glPushName( GLuint name );
void glPopName( void );

/* Textures */
void glGenTextures( GLsizei n, GLuint *textures );
void glBindTexture( GLenum target, GLuint texture );
void glTexParameteri( GLenum target, GLenum pname, GLint param );
void glTexParameterfv( GLenum target, GLenum pname, const GLfloat *params );
void glPixelStorei( GLenum pname, GLint param );
void glTexImage2D( GLenum target, GLint level, GLint internal_format, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *pixels );

/* minigl extension: present the frame rendered since the last glClear( ) */
void mglSwapBuffers( void );

#ifdef __cplusplus
}
#endif

#endif /* MACFSV_GL_H */


/* end GL/gl.h */
