/* gui.h */

/* mac-fsv: interface between fsv's core and the Cocoa user interface.
 * (In fsv, this header declared the GTK+ helper library; only the parts
 * the core needs remain, plus the hooks that replace GTK+ calls.) */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#ifdef FSV_GUI_H
	#error
#endif
#define FSV_GUI_H


/* Mouse cursors for gui_cursor( ) */
enum {
	GUI_CURSOR_DEFAULT = -1,
	GUI_CURSOR_DOUBLE_ARROW,	/* dolly */
	GUI_CURSOR_FLEUR,		/* revolve */
	GUI_CURSOR_WATCH,
	GUI_CURSOR_X
};


/* Processes pending user interface events (keeps the interface
 * responsive during long operations) */
void gui_update( void );

/* Starts calling animation_loop( ) once per display refresh */
void gui_request_animation( void );

/* Viewport size, in pixels */
void gui_viewport_size( int *width, int *height );

/* Sets the viewport mouse cursor */
void gui_cursor( int glyph );

/* Mirrors a camera scrollbar adjustment (see camera.h) to the screen */
#ifdef FSV_CAMERA_H
void gui_scrollbar_update( int axis, const ScrollAdjustment *adj );
#else
struct _ScrollAdjustment;
void gui_scrollbar_update( int axis, const struct _ScrollAdjustment *adj );
#endif


/* end gui.h */
