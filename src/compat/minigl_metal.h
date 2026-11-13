/* minigl_metal.h - Metal back end set-up (Objective-C side) */

#import <MetalKit/MetalKit.h>

/* Binds the back end to the view it renders into. Must be called before
 * any GL call that creates GPU resources */
void mglb_init( MTKView *view );

/* GL line widths are given in pixels; this scales them (e.g. by the
 * backing scale factor, so lines keep their original 1999 proportions) */
void mglb_set_line_scale( float scale );
