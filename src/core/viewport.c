/* viewport.c */

/* Viewport routines */

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
#include "viewport.h"

#include <GL/gl.h> /* GLuint */

#include "about.h"
#include "camera.h"
#include "dialog.h" /* context_menu( ) */
#include "filelist.h" /* filelist_show_entry( ) */
#include "geometry.h"
#include "gui.h"
#include "ogl.h"
#include "window.h"


/* Sensitivity factor used for manual camera control */
#define MOUSE_SENSITIVITY 0.5


/* The node table, used to find a node by its ID number */
static GNode **node_table = NULL;

/* The currently highlighted (indicated) node */
static GNode *indicated_node = NULL;

/* Previous mouse pointer coordinates */
static int prev_x = 0, prev_y = 0;

/* mac-fsv: drag-to-pan state (a left drag beyond a few pixels pans the
 * view instead of selecting the node under the pointer) */
#define DRAG_PAN_THRESHOLD 8
static int press_x = 0, press_y = 0;
static boolean drag_panning = FALSE;


/* Receives a newly created node table from scanfs( ) */
void
viewport_pass_node_table( GNode **new_node_table )
{
	if (node_table != NULL)
		xfree( node_table );

	node_table = new_node_table;
}


/* This returns the node (if any) that is visible at viewport location
 * (x,y) (where (0,0) indicates the upper-left corner). The ID number of
 * the particular face being pointed at is stored in face_id */
static GNode *
node_at_location( int x, int y, unsigned int *face_id )
{
	const GLuint *hit_records;
	unsigned int name_count, z1, z2, name1, name2;
	unsigned int min_z1;
	unsigned int node_id = 0;
	int hit_count;
	int i = 0;

	*face_id = 0;

	hit_count = ogl_select( x, y, &hit_records );
	if (hit_count > 0) {
		/* Process selection hit records: find nearest hit
		 * (i.e. hit with smallest window-coordinate z value) */
		min_z1 = 4294967295U; /* 2^32 - 1 */
		while (hit_count > 0) {
			name_count = hit_records[i++];
			z1 = hit_records[i++];
			z2 = hit_records[i++];
			name1 = hit_records[i++];
			if (name_count == 2)
				name2 = hit_records[i++];
			else
				name2 = 0; /* default */
			if (z1 < min_z1) {
				node_id = name1;
				*face_id = name2;
				min_z1 = z1;
			}
			z2 = z2; /* z2 not used */
			--hit_count;
		}

		if (node_id != 0)
			return node_table[node_id];
	}

	return NULL;
}


/* This handles all mouse events for the viewport.
 * mac-fsv: formerly a GTK+ event callback; the Cocoa view translates its
 * events into the GDK-like terms used here. Coordinates are in pixels,
 * with the origin at the top left of the viewport */
void
viewport_event( ViewportEventType type, int x, int y, int button, unsigned int state )
{
	GNode *node;
	double dx, dy;
	unsigned int face_id;
	boolean btn1, btn2, btn3;
	boolean ctrl_key;

	if (type == VIEWPORT_BUTTON_PRESS) {
		/* Exit the About presentation if it is up */
		if (about( ABOUT_END )) {
			indicated_node = NULL;
			return;
		}
	}

	/* If we're in splash screen mode, proceed no further */
	if ((globals.fsv_mode == FSV_SPLASH) || (globals.fsv_mode == FSV_NONE))
		return;

	/* Mouse-related events */
	switch (type) {
		case VIEWPORT_BUTTON_PRESS:
		btn1 = button == 1;
		btn2 = button == 2;
		btn3 = button == 3;
		ctrl_key = state & VIEWPORT_CONTROL_MASK;
		if (camera_moving( )) {
			/* Yipe! Impatient user */
			camera_pan_finish( );
			indicated_node = NULL;
		}
		else if (!ctrl_key) {
			if (btn2)
				indicated_node = NULL;
			else
				indicated_node = node_at_location( x, y, &face_id );
			if (indicated_node == NULL) {
				geometry_highlight_node( NULL, FALSE );
				window_statusbar( SB_RIGHT, "" );
			}
			else {
				if (geometry_should_highlight( indicated_node, face_id ) || btn1)
					geometry_highlight_node( indicated_node, btn1 );
				else
					geometry_highlight_node( NULL, FALSE );
				window_statusbar( SB_RIGHT, node_absname( indicated_node ) );
				if (btn3) {
					/* Bring up context-sensitive menu */
					node = indicated_node;
					filelist_show_entry( node );
					context_menu( node );
					/* (the menu is modal; the button release
					 * has been consumed) */
					indicated_node = NULL;
					gui_cursor( GUI_CURSOR_DEFAULT );
				}
			}
		}
		prev_x = x;
		prev_y = y;
		press_x = x;
		press_y = y;
		drag_panning = FALSE;
		break;

		case VIEWPORT_BUTTON_RELEASE:
		btn1 = state & VIEWPORT_BUTTON1_MASK;
		ctrl_key = state & VIEWPORT_CONTROL_MASK;
		if (btn1 && !ctrl_key && !drag_panning && !camera_moving( ) && (indicated_node != NULL))
			camera_look_at( indicated_node );
		drag_panning = FALSE;
		gui_cursor( GUI_CURSOR_DEFAULT );
		break;

		case VIEWPORT_MOTION:
		btn1 = state & VIEWPORT_BUTTON1_MASK;
		btn2 = state & VIEWPORT_BUTTON2_MASK;
		btn3 = state & VIEWPORT_BUTTON3_MASK;
		ctrl_key = state & VIEWPORT_CONTROL_MASK;
		if (!camera_moving( )) {
			if (btn2) {
				/* Dolly the camera */
				gui_cursor( GUI_CURSOR_DOUBLE_ARROW );
				dy = MOUSE_SENSITIVITY * (y - prev_y);
				camera_dolly( - dy );
				indicated_node = NULL;
			}
			else if (ctrl_key && btn1) {
				/* Revolve the camera */
				gui_cursor( GUI_CURSOR_FLEUR );
				dx = MOUSE_SENSITIVITY * (x - prev_x);
				dy = MOUSE_SENSITIVITY * (y - prev_y);
				camera_revolve( dx, dy );
				indicated_node = NULL;
			}
			else if (!ctrl_key && btn1 && (drag_panning || ((ABS(x - press_x) + ABS(y - press_y)) > DRAG_PAN_THRESHOLD))) {
				/* Pan the camera (mac-fsv) */
				drag_panning = TRUE;
				gui_cursor( GUI_CURSOR_FLEUR );
				camera_drag_pan( (double)prev_x, (double)prev_y, (double)x, (double)y );
				indicated_node = NULL;
			}
			else if (!ctrl_key && (btn1 || btn3)) {
				/* Pointless dragging */
				if (indicated_node != NULL) {
					node = node_at_location( x, y, &face_id );
					if (node != indicated_node)
						indicated_node = NULL;
				}
			}
			else
				indicated_node = node_at_location( x, y, &face_id );
			/* Update node highlighting */
			if (indicated_node == NULL) {
				geometry_highlight_node( NULL, FALSE );
				window_statusbar( SB_RIGHT, "" );
			}
			else {
				if (geometry_should_highlight( indicated_node, face_id ) || btn1)
					geometry_highlight_node( indicated_node, btn1 );
				else
					geometry_highlight_node( NULL, FALSE);
				window_statusbar( SB_RIGHT, node_absname( indicated_node ) );
			}
			prev_x = x;
			prev_y = y;
		}
		break;

		case VIEWPORT_LEAVE:
		/* The mouse has left the viewport */
		geometry_highlight_node( NULL, FALSE );
		window_statusbar( SB_RIGHT, "" );
		gui_cursor( GUI_CURSOR_DEFAULT );
		indicated_node = NULL;
		break;

		default:
		/* Ignore event */
		break;
	}
}


/* mac-fsv: scroll wheel / trackpad zoom (dollies the camera) */
void
viewport_dolly( double dk )
{
	if ((globals.fsv_mode == FSV_SPLASH) || (globals.fsv_mode == FSV_NONE))
		return;
	if (about( ABOUT_CHECK ) || camera_moving( ))
		return;

	camera_dolly( dk );
	indicated_node = NULL;
	geometry_highlight_node( NULL, FALSE );
	window_statusbar( SB_RIGHT, "" );
}


/* end viewport.c */
