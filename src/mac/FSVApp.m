/* FSVApp.m */

/* mac-fsv: application entry point, menus, and the glue that replaces
 * GTK+'s main loop */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import "FSVApp.h"

#include <GL/gl.h>

#include "xmaps/fsv-icon.xpm"


FSVMainWindowController *FSVMain = nil;

/* Root directory and mode given on the command line, if any */
static NSString *cli_root_dir = nil;
static FsvMode cli_mode = FSV_NONE;

/* TRUE while a long operation (filesystem scan) runs on the main thread */
static BOOL long_operation = NO;


/**** Helpers ****************/

NSString *
FSVString( const char *str )
{
	NSString *s;

	if (str == NULL)
		return @"";
	s = [NSString stringWithUTF8String:str];
	if (s == nil)
		s = [NSString stringWithCString:str encoding:NSISOLatin1StringEncoding];

	return (s != nil) ? s : @"";
}


NSImage *
FSVMiniIcon( NodeType type )
{
	static NSImage *icons[NUM_NODE_TYPES];

	if ((type <= NODE_METANODE) || (type >= NUM_NODE_TYPES))
		return nil;
	if (icons[type] == nil)
		icons[type] = FSVImageFromXPM( node_type_mini_xpms[type] );

	return icons[type];
}


NSImage *
FSVIcon( NodeType type )
{
	static NSImage *icons[NUM_NODE_TYPES];

	if ((type <= NODE_METANODE) || (type >= NUM_NODE_TYPES))
		return nil;
	if (icons[type] == nil)
		icons[type] = FSVImageFromXPM( node_type_xpms[type] );

	return icons[type];
}


NSColor *
FSVColorFromRGB( const RGBcolor *color )
{
	return [NSColor colorWithSRGBRed:color->r green:color->g blue:color->b alpha:1.0];
}


RGBcolor
FSVRGBFromColor( NSColor *color )
{
	NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
	RGBcolor rgb = { 0.0f, 0.0f, 0.0f };

	if (c != nil) {
		rgb.r = (float)c.redComponent;
		rgb.g = (float)c.greenComponent;
		rgb.b = (float)c.blueComponent;
	}

	return rgb;
}


/**** Main loop glue (gui.h) ****************/

/* Keeps the interface responsive during long operations. (GTK+'s
 * version ran the main loop until no events were pending.) */
void
gui_update( void )
{
	static double t_prev = 0.0;
	NSEvent *event;
	double t_now;

	t_now = xgettime( );
	if ((t_now - t_prev) < (1.0 / 50.0))
		return;
	t_prev = t_now;

	[FSVMain flushPendingUpdates];

	if (long_operation) {
		for (;;) {
			event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES];
			if (event == nil)
				break;
			[NSApp sendEvent:event];
		}
		[NSApp updateWindows];
		[FSVMain.viewport tickIfDue];
	}

	[FSVMain.window displayIfNeeded];
	[CATransaction flush];
}


/* Debugging aid: replays a scenario given in MACFSV_SCRIPT, e.g.
 * "expandall:llvm-mos-v23.2.0;wait:4;lookat:llvm-mos-v23.2.0/bin;wait:3;
 *  revolve:3;scroll:3;quit". Paths are relative to the root */
static GNode *
script_node( NSString *rel )
{
	return node_named( [FSVString( node_absname( root_dnode ) ) stringByAppendingPathComponent:rel].fileSystemRepresentation );
}

static void
run_script( NSArray<NSString *> *steps, NSUInteger i )
{
	NSArray<NSString *> *parts;
	NSString *cmd, *arg;
	double delay = 0.5;
	GNode *node;

	if (i >= steps.count)
		return;
	parts = [steps[i] componentsSeparatedByString:@":"];
	cmd = parts[0];
	arg = (parts.count > 1) ? parts[1] : @"";
	NSLog( @"script: %@", steps[i] );

	if ([cmd isEqualToString:@"wait"])
		delay = arg.doubleValue;
	else if ([cmd isEqualToString:@"lookat"] && ((node = script_node( arg )) != NULL))
		camera_look_at( node );
	else if ([cmd isEqualToString:@"expandall"] && ((node = script_node( arg )) != NULL) && NODE_IS_DIR(node))
		colexp( node, COLEXP_EXPAND_RECURSIVE );
	else if ([cmd isEqualToString:@"treev"])
		fsv_set_mode( FSV_TREEV );
	else if ([cmd isEqualToString:@"mapv"])
		fsv_set_mode( FSV_MAPV );
	else if ([cmd isEqualToString:@"pan"]) {
		/* pan:dx,dy,seconds - drags at 60 Hz by (dx, dy) pixels per step */
		NSArray<NSString *> *v = [arg componentsSeparatedByString:@","];
		double dx = v[0].doubleValue, dy = v[1].doubleValue, secs = v[2].doubleValue;
		__block int k = 0;
		__block double px, py;
		int count = (int)(60.0 * secs), w, h;
		gui_viewport_size( &w, &h );
		px = 0.5 * w;
		py = 0.5 * h;
		NSTimer *timer = [NSTimer timerWithTimeInterval:(1.0 / 60.0) repeats:YES block:^(NSTimer *tm) {
			camera_drag_pan( px, py, px + dx, py + dy );
			px += dx;
			py += dy;
			if (++k >= count)
				[tm invalidate];
		}];
		timer.tolerance = 0.0;
		[[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
		delay = secs + 0.5;
	}
	else if ([cmd isEqualToString:@"mark"] || [cmd isEqualToString:@"probe"]) {
		/* mark: remembers the world point under the screen center (the
		 * camera target); probe: logs where that point now is on screen */
		static double world[3];
		if ([cmd isEqualToString:@"mark"]) {
			if (globals.fsv_mode == FSV_MAPV) {
				world[0] = MAPV_CAMERA(camera)->target.x;
				world[1] = MAPV_CAMERA(camera)->target.y;
				world[2] = MAPV_CAMERA(camera)->target.z;
			}
			else {
				world[0] = TREEV_CAMERA(camera)->target.r * cos( RAD(TREEV_CAMERA(camera)->target.theta) );
				world[1] = TREEV_CAMERA(camera)->target.r * sin( RAD(TREEV_CAMERA(camera)->target.theta) );
				world[2] = TREEV_CAMERA(camera)->target.z;
			}
		}
		{
			double mv[16], pj[16], e[4], c[4];
			int vp[4], i;
			glGetDoublev( GL_MODELVIEW_MATRIX, mv );
			glGetDoublev( GL_PROJECTION_MATRIX, pj );
			glGetIntegerv( GL_VIEWPORT, vp );
			for (i = 0; i < 4; i++)
				e[i] = mv[i] * world[0] + mv[4 + i] * world[1] + mv[8 + i] * world[2] + mv[12 + i];
			for (i = 0; i < 4; i++)
				c[i] = pj[i] * e[0] + pj[4 + i] * e[1] + pj[8 + i] * e[2] + pj[12 + i] * e[3];
			NSLog( @"%@: screen %.0f, %.0f (viewport %d x %d), camera theta %.1f phi %.1f", cmd, (0.5 * c[0] / c[3] + 0.5) * vp[2], (0.5 - 0.5 * c[1] / c[3]) * vp[3], vp[2], vp[3], camera->theta, camera->phi );
		}
	}
	else if ([cmd isEqualToString:@"snap"]) {
		/* snap:name - saves a capture of the window to $MACFSV_SNAPDIR */
		const char *dir = getenv( "MACFSV_SNAPDIR" );
		if (dir != NULL) {
			NSString *cmdline = [NSString stringWithFormat:@"/usr/sbin/screencapture -x -o -l %ld '%s/%@.png'", (long)FSVMain.window.windowNumber, dir, arg];
			system( cmdline.UTF8String );
		}
	}
	else if ([cmd isEqualToString:@"revolve"] || [cmd isEqualToString:@"scroll"] || [cmd isEqualToString:@"hover"]) {
		/* Drives the camera like mouse drags would, at 60 Hz */
		BOOL revolve = [cmd isEqualToString:@"revolve"], hover = [cmd isEqualToString:@"hover"];
		int count = (int)(60.0 * arg.doubleValue);
		__block int k = 0;
		NSTimer *timer = [NSTimer timerWithTimeInterval:(1.0 / 60.0) repeats:YES block:^(NSTimer *tm) {
			static int calls = 0;
			static double t_sec = 0.0;
			double t = xgettime( );
			++calls;
			if ((t - t_sec) >= 1.0) {
				NSLog( @"script input: %d calls/s", calls );
				calls = 0;
				t_sec = t;
			}
			if (revolve)
				camera_revolve( 2.0, 0.3 * sin( k * 0.05 ) );
			else if (hover) {
				int w, h;
				gui_viewport_size( &w, &h );
				viewport_event( VIEWPORT_MOTION, (int)(w * (0.5 + 0.4 * sin( k * 0.03 ))), (int)(h * (0.5 + 0.3 * cos( k * 0.04 ))), 0, 0 );
			}
			else {
				const ScrollAdjustment *adj = camera_scrollbar_adjustment( CAMERA_X_SCROLLBAR );
				camera_scrollbar_moved( CAMERA_X_SCROLLBAR, adj->value + 0.01 * (adj->upper - adj->lower) * ((k / 60) % 2 ? -1 : 1) );
			}
			if (++k >= count)
				[tm invalidate];
		}];
		timer.tolerance = 0.0;
		[[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
		delay = arg.doubleValue + 0.5;
	}
	else if ([cmd isEqualToString:@"quit"]) {
		[NSApp terminate:nil];
		return;
	}

	dispatch_after( dispatch_time( DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC) ), dispatch_get_main_queue( ), ^{
		run_script( steps, i + 1 );
	} );
}


void
FSVLoadRoot( NSString *path )
{
	BOOL is_dir = NO;

	if (FSVMain.scanning || (path == nil))
		return;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&is_dir] || !is_dir) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = @"Not a directory";
		alert.informativeText = path;
		[alert runModal];
		return;
	}

	[[NSUserDefaults standardUserDefaults] setObject:path forKey:@"LastRoot"];
	FSVMain.window.representedURL = [NSURL fileURLWithPath:path isDirectory:YES];
	FSVMain.window.title = [NSString stringWithFormat:@"mac-fsv - %@", path.lastPathComponent.length > 0 ? path.lastPathComponent : path];

	FSVMain.scanning = YES;
	long_operation = YES;
	fsv_load( path.fileSystemRepresentation );
	long_operation = NO;
	FSVMain.scanning = NO;

	if (getenv( "MACFSV_SCRIPT" ) != NULL) {
		static id activity = nil;
		/* Scripted input must not be throttled by App Nap */
		if (activity == nil)
			activity = [[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityUserInitiated | NSActivityLatencyCritical) reason:@"MACFSV_SCRIPT"];
		/* Keep the window visible (occluded windows get throttled),
		 * without taking keyboard focus */
		FSVMain.window.level = NSStatusWindowLevel;
		[FSVMain.window orderFrontRegardless];
		NSArray *steps = [[NSString stringWithUTF8String:getenv( "MACFSV_SCRIPT" )] componentsSeparatedByString:@";"];
		dispatch_after( dispatch_time( DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC) ), dispatch_get_main_queue( ), ^{
			run_script( steps, 0 );
		} );
	}
}


/**** Application delegate ****************/

@interface FSVAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation FSVAppDelegate {
	BOOL _ready;
	NSString *_pendingRoot;
}


static NSMenuItem *
add_item( NSMenu *menu, NSString *title, SEL action, NSString *key, NSEventModifierFlags mods )
{
	NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:(key != nil) ? key : @""];

	if (key != nil)
		item.keyEquivalentModifierMask = mods;

	return item;
}


static NSMenu *
add_menu( NSMenu *bar, NSString *title )
{
	NSMenuItem *item = [bar addItemWithTitle:title action:NULL keyEquivalent:@""];
	NSMenu *menu = [[NSMenu alloc] initWithTitle:title];

	item.submenu = menu;

	return menu;
}


- (void)buildMenus
{
	NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];
	NSMenu *menu;
	NSMenuItem *item;
	NSEventModifierFlags cmd = NSEventModifierFlagCommand;

	/* Application menu */
	menu = add_menu( bar, @"mac-fsv" );
	add_item( menu, @"About fsv", @selector(aboutFsv:), nil, 0 );
	[menu addItem:[NSMenuItem separatorItem]];
	add_item( menu, @"Settings...", @selector(colorSetup:), @",", cmd );
	[menu addItem:[NSMenuItem separatorItem]];
	item = add_item( menu, @"Services", NULL, nil, 0 );
	item.submenu = [[NSMenu alloc] initWithTitle:@"Services"];
	NSApp.servicesMenu = item.submenu;
	[menu addItem:[NSMenuItem separatorItem]];
	add_item( menu, @"Hide mac-fsv", @selector(hide:), @"h", cmd );
	add_item( menu, @"Hide Others", @selector(hideOtherApplications:), @"h", cmd | NSEventModifierFlagOption );
	add_item( menu, @"Show All", @selector(unhideAllApplications:), nil, 0 );
	[menu addItem:[NSMenuItem separatorItem]];
	add_item( menu, @"Quit mac-fsv", @selector(terminate:), @"q", cmd );

	/* File menu */
	menu = add_menu( bar, @"File" );
	add_item( menu, @"Change root...", @selector(changeRoot:), @"n", cmd );
	[menu addItem:[NSMenuItem separatorItem]];
	add_item( menu, @"Close", @selector(performClose:), @"w", cmd );

	/* Vis menu */
	menu = add_menu( bar, @"Vis" );
	add_item( menu, @"MapV", @selector(visMapV:), @"1", cmd );
	add_item( menu, @"TreeV", @selector(visTreeV:), @"2", cmd );

	/* Colors menu */
	menu = add_menu( bar, @"Colors" );
	add_item( menu, @"By node type", @selector(colorByNodeType:), nil, 0 );
	add_item( menu, @"By timestamp", @selector(colorByTimestamp:), nil, 0 );
	add_item( menu, @"By wildcards", @selector(colorByWildcards:), nil, 0 );
	[menu addItem:[NSMenuItem separatorItem]];
	add_item( menu, @"Setup...", @selector(colorSetup:), nil, 0 );

	/* View menu */
	menu = add_menu( bar, @"View" );
	add_item( menu, @"Low-Resolution Rendering", @selector(toggleLowResolution:), @"l", cmd | NSEventModifierFlagControl );
	[menu addItem:[NSMenuItem separatorItem]];
	add_item( menu, @"Enter Full Screen", @selector(toggleFullScreen:), @"f", cmd | NSEventModifierFlagControl );

	/* Window menu */
	menu = add_menu( bar, @"Window" );
	add_item( menu, @"Minimize", @selector(performMiniaturize:), @"m", cmd );
	add_item( menu, @"Zoom", @selector(performZoom:), nil, 0 );
	NSApp.windowsMenu = menu;

	/* Help menu */
	menu = add_menu( bar, @"Help" );
	add_item( menu, @"Contents...", @selector(helpContents:), @"?", cmd );
	[menu addItem:[NSMenuItem separatorItem]];
	add_item( menu, @"About fsv...", @selector(aboutFsv:), nil, 0 );
	NSApp.helpMenu = menu;

	NSApp.mainMenu = bar;
}


- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
	NSBitmapImageRep *rep;
	NSImage *icon;

	[self buildMenus];

	/* fsv's own icon, pixel-doubled */
	rep = FSVBitmapFromXPM( fsv_icon_xpm, 8 );
	if (rep != nil) {
		icon = [[NSImage alloc] initWithSize:NSMakeSize( 512, 512 )];
		[icon addRepresentation:rep];
		NSApp.applicationIconImage = icon;
	}
}


- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	FSVMain = [[FSVMainWindowController alloc] init];
	FSVMain.viewport.lowResolution = [[NSUserDefaults standardUserDefaults] boolForKey:@"LowResolution"];
	[FSVMain showWindow:nil];
	[FSVMain.window makeKeyAndOrderFront:nil];
	[NSApp activate];

	/* Start the 3D engine on the splash screen */
	[FSVMain.viewport startGL];
	fsv_init( cli_mode );
	camera_update_scrollbars( TRUE );
	redraw( );

	_ready = YES;

	/* Give the window a chance to appear before scanning */
	dispatch_async( dispatch_get_main_queue( ), ^{
		[self chooseInitialRoot];
	} );
}


- (void)chooseInitialRoot
{
	if (_pendingRoot != nil) {
		NSString *path = _pendingRoot;
		_pendingRoot = nil;
		FSVLoadRoot( path );
	}
	else if (cli_root_dir != nil)
		FSVLoadRoot( cli_root_dir );
	else
		dialog_change_root( );
}


- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename
{
	BOOL is_dir = NO;

	if (![[NSFileManager defaultManager] fileExistsAtPath:filename isDirectory:&is_dir])
		return NO;
	if (!is_dir)
		filename = filename.stringByDeletingLastPathComponent;

	if (!_ready) {
		_pendingRoot = filename;
		return YES;
	}
	if (FSVMain.scanning)
		return NO;
	if (FSVMain.window.attachedSheet != nil)
		[FSVMain.window endSheet:FSVMain.window.attachedSheet];
	dispatch_async( dispatch_get_main_queue( ), ^{
		FSVLoadRoot( filename );
	} );

	return YES;
}


- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
	return YES;
}


- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app
{
	return YES;
}


/* Menu actions that are not handled by the main window controller are
 * forwarded to it (e.g. while a sheet is up) */
- (BOOL)respondsToSelector:(SEL)selector
{
	if ([super respondsToSelector:selector])
		return YES;
	return (FSVMain != nil) && [FSVMain respondsToSelector:selector];
}


- (id)forwardingTargetForSelector:(SEL)selector
{
	if ((FSVMain != nil) && [FSVMain respondsToSelector:selector])
		return FSVMain;
	return [super forwardingTargetForSelector:selector];
}

@end


/**** main( ) ****************/

static const char usage_summary[] = "\n"
    "mac-fsv - 3D File System Visualizer for macOS\n"
    "          based on fsv " VERSION ", Copyright (C)1999 Daniel Richard G.\n"
    "\n"
    "Usage: %s [rootdir] [options]\n"
    "  rootdir      Root directory for visualization\n"
    "  --mapv       Start in MapV mode (default)\n"
    "  --treev      Start in TreeV mode\n"
    "  --help       Print this help and exit\n"
    "\n";


int
main( int argc, char **argv )
{
	FSVAppDelegate *delegate;
	int i;

	/* Parse command-line options (ignoring those passed by the system,
	 * such as -NSDocumentRevisionsDebugMode or -psn_*) */
	for (i = 1; i < argc; i++) {
		if (!strcmp( argv[i], "--mapv" ))
			cli_mode = FSV_MAPV;
		else if (!strcmp( argv[i], "--treev" ))
			cli_mode = FSV_TREEV;
		else if (!strcmp( argv[i], "--discv" ))
			cli_mode = FSV_DISCV;
		else if (!strcmp( argv[i], "--help" ) || !strcmp( argv[i], "-h" )) {
			printf( usage_summary, argv[0] );
			return EXIT_SUCCESS;
		}
		else if (argv[i][0] == '-') {
			/* AppKit arguments come in pairs (-Key value) */
			if (((i + 1) < argc) && (argv[i + 1][0] != '-') && strncmp( argv[i], "-psn_", 5 ))
				++i;
		}
		else if (cli_root_dir == nil) {
			NSString *path = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:argv[i] length:strlen( argv[i] )];
			if (!path.isAbsolutePath)
				path = [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:path];
			cli_root_dir = path.stringByStandardizingPath;
		}
	}

	@autoreleasepool {
		[NSApplication sharedApplication];
		NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
		delegate = [[FSVAppDelegate alloc] init];
		NSApp.delegate = delegate;
		[NSApp run];
	}

	return EXIT_SUCCESS;
}


/* end FSVApp.m */
