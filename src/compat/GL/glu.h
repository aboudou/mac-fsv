/* GL/glu.h - the two GLU entry points used by fsv (see minigl.c) */

#ifndef MACFSV_GLU_H
#define MACFSV_GLU_H

#include "gl.h"

#ifdef __cplusplus
extern "C" {
#endif

void gluPickMatrix( GLdouble x, GLdouble y, GLdouble width, GLdouble height, GLint viewport[4] );
GLint gluBuild2DMipmaps( GLenum target, GLint internal_format, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *data );

#ifdef __cplusplus
}
#endif

#endif
