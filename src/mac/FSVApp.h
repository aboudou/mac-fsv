/* FSVApp.h */

/* mac-fsv: shared declarations for the Cocoa user interface */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

/* fsv core */
#include "common.h"
#include "about.h"
#include "animation.h"
#include "camera.h"
#include "colexp.h"
#include "color.h"
#include "dialog.h"
#include "dirtree.h"
#include "filelist.h"
#include "fsv.h"
#include "geometry.h"
#include "gui.h"
#include "ogl.h"
#include "viewport.h"
#include "window.h"


/**** Viewport (3D view) ****************/

@interface FSVViewport : MTKView <MTKViewDelegate>
@property (nonatomic) BOOL lowResolution;	/* "retro pixels" rendering */
- (void)startGL;
- (void)requestAnimation;
- (void)tickIfDue;
- (void)setCursorGlyph:(int)glyph;
@end


/**** Directory tree item ****************/

@interface FSVDirItem : NSObject
@property (nonatomic) GNode *node;
@property (nonatomic, weak) FSVDirItem *parent;
@property (nonatomic, strong) NSMutableArray<FSVDirItem *> *children;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL expanded;
@end


/**** Main window ****************/

@interface FSVMainWindowController : NSWindowController <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuItemValidation>

@property (nonatomic, strong) FSVViewport *viewport;
@property (nonatomic, strong) NSOutlineView *dirTree;
@property (nonatomic, strong) NSTableView *fileList;
@property (nonatomic) BOOL accessEnabled;
@property (nonatomic) ColorMode colorMode;
@property (nonatomic) BOOL scanning;

- (void)flushPendingUpdates;

/* Back ends of the C interface (window.h, dirtree.h, filelist.h) */
- (void)setStatus:(NSString *)message right:(BOOL)right;
- (void)birdseyeViewOff;
- (void)updateScrollbar:(int)axis adjustment:(const ScrollAdjustment *)adj;

- (void)dirTreeClear;
- (void)dirTreeAdd:(GNode *)dnode;
- (void)dirTreeNoMoreEntries;
- (void)dirTreeShow:(GNode *)dnode;
- (BOOL)dirTreeExpanded:(GNode *)dnode;
- (void)dirTreeCollapseRecursive:(GNode *)dnode;
- (void)dirTreeExpand:(GNode *)dnode;
- (void)dirTreeExpandRecursive:(GNode *)dnode;

- (void)fileListResetAccess;
- (void)fileListPopulate:(GNode *)dnode;
- (void)fileListShowEntry:(GNode *)node;
- (void)fileListInit;
- (void)fileListScanMonitorInit;
- (void)fileListScanMonitor:(int *)nodeCounts sizes:(int64 *)sizeCounts;
- (void)dirTreeRightClickedRow:(NSInteger)row;
- (void)fileListRightClickedRow:(NSInteger)row;

/* Menu/toolbar actions */
- (IBAction)changeRoot:(id)sender;
- (IBAction)visMapV:(id)sender;
- (IBAction)visTreeV:(id)sender;
- (IBAction)colorByNodeType:(id)sender;
- (IBAction)colorByTimestamp:(id)sender;
- (IBAction)colorByWildcards:(id)sender;
- (IBAction)colorSetup:(id)sender;
- (IBAction)helpContents:(id)sender;
- (IBAction)aboutFsv:(id)sender;
- (IBAction)toggleLowResolution:(id)sender;

@end


/**** Globals and helpers ****************/

extern FSVMainWindowController *FSVMain;

/* Loads (scans) a new root directory */
void FSVLoadRoot( NSString *path );

/* Converts a C string from the filesystem into an NSString */
NSString *FSVString( const char *str );

/* XPM icon conversion (FSVXPM.m) */
NSBitmapImageRep *FSVBitmapFromXPM( char **xpm, int scale );
NSImage *FSVImageFromXPM( char **xpm );

/* Icons for node types, at 16x16 ("mini") and 32x32 */
NSImage *FSVMiniIcon( NodeType type );
NSImage *FSVIcon( NodeType type );

/* Color conversions */
NSColor *FSVColorFromRGB( const RGBcolor *color );
RGBcolor FSVRGBFromColor( NSColor *color );


/* end FSVApp.h */
