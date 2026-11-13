/* FSVViewport.m */

/* The 3D viewport: a Metal view that drives fsv's animation loop and
 * translates mouse input into fsv's original controls:
 *   left click            look at node
 *   left drag + Control   revolve the camera (Command works too)
 *   middle drag           dolly the camera (Option + left drag, the
 *                         scroll wheel and pinch gestures work too)
 *   right click           context menu */

/* mac-fsv - macOS port of fsv
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version. */


#import "FSVApp.h"
#import "minigl_metal.h"
#import <QuartzCore/QuartzCore.h>


@implementation FSVViewport {
	CADisplayLink *_displayLink;
	BOOL _glStarted;
	BOOL _inTick;
	BOOL _animating;
	BOOL _loopActive;
	int _idleTicks;
	double _lastTick;
	unsigned int _buttons;
	BOOL _optionDolly;
	NSTrackingArea *_trackingArea;
}


- (instancetype)initWithFrame:(NSRect)frame
{
	id<MTLDevice> device = MTLCreateSystemDefaultDevice( );

	self = [super initWithFrame:frame device:device];
	if (self == nil)
		return nil;

	if (device == nil) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = @"mac-fsv requires Metal support.";
		[alert runModal];
		exit( EXIT_FAILURE );
	}

	self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	self.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
	self.sampleCount = 1;	/* no antialiasing: 1999 looks */
	self.clearColor = MTLClearColorMake( 0.0, 0.0, 0.0, 1.0 );
	self.paused = YES;
	self.enableSetNeedsDisplay = NO;
	self.framebufferOnly = YES;
	self.delegate = self;
	self.layer.magnificationFilter = kCAFilterNearest;

	return self;
}


- (BOOL)acceptsFirstResponder
{
	return YES;
}


- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
	return YES;
}


/* Sets up the GL state; call once the view is in a window */
- (void)startGL
{
	if (_glStarted)
		return;

	[self updateDrawableSize];
	mglb_init( self );
	ogl_init( );
	_glStarted = YES;

	_displayLink = [self displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
	[_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	_displayLink.paused = YES;
}


- (void)updateDrawableSize
{
	CGFloat scale = self.window ? self.window.backingScaleFactor : NSScreen.mainScreen.backingScaleFactor;
	NSSize size = self.bounds.size;

	if (self.lowResolution) {
		/* One pixel per point, magnified without filtering */
		self.autoResizeDrawable = NO;
		self.drawableSize = CGSizeMake( MAX(1.0, floor( size.width )), MAX(1.0, floor( size.height )) );
		mglb_set_line_scale( 1.0f );
	}
	else {
		self.autoResizeDrawable = NO;
		self.drawableSize = CGSizeMake( MAX(1.0, floor( size.width * scale )), MAX(1.0, floor( size.height * scale )) );
		mglb_set_line_scale( (float)scale );
	}
}


- (void)setLowResolution:(BOOL)lowResolution
{
	_lowResolution = lowResolution;
	[self updateDrawableSize];
	if (_glStarted) {
		ogl_resize( );
		redraw( );
	}
}


- (void)setFrameSize:(NSSize)newSize
{
	[super setFrameSize:newSize];
	[self updateDrawableSize];
	if (_glStarted) {
		ogl_resize( );
		redraw( );
	}
}


- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	[self updateDrawableSize];
	if (_glStarted) {
		ogl_resize( );
		redraw( );
	}
}


/**** MTKViewDelegate ****/

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
	if (_glStarted)
		redraw( );
}


/* Frames are rendered from -tick, through -[MTKView draw]: MTKView only
 * provides a fresh drawable (currentDrawable) during its draw cycle, and
 * releases it afterwards. (Rendering outside of it reused an already
 * presented drawable, so most frames never reached the screen.) */
- (void)drawInMTKView:(MTKView *)view
{
	if (_inTick)
		_loopActive = animation_loop( );
}


/**** Animation ****/

/* Frames are paced by a display link. Pausing and resuming a display
 * link is slow (it takes several refresh periods to restart), so it is
 * kept running for a while after the last frame: interactive redraws
 * (camera drags, highlighting) then render at the full refresh rate. */
#define DISPLAY_LINK_IDLE_TICKS 45

- (void)requestAnimation
{
	BOOL was_paused;

	_animating = YES;
	_idleTicks = 0;
	if (_displayLink == nil)
		return;
	was_paused = _displayLink.paused;
	_displayLink.paused = NO;
	if (was_paused) {
		/* Don't wait for the display link to restart */
		dispatch_async( dispatch_get_main_queue( ), ^{
			[self tick];
		} );
	}
}


- (void)tick
{
	BOOL active;
	double t0;

	if (!_glStarted || _inTick)
		return;

	if (!_animating) {
		if (++_idleTicks > DISPLAY_LINK_IDLE_TICKS)
			_displayLink.paused = YES;
		return;
	}

	_inTick = YES;
	t0 = xgettime( );
	_lastTick = t0;
	_loopActive = NO;
	[self draw];
	active = _loopActive;
	if (!active) {
		_animating = NO;
		_idleTicks = 0;
	}
	_inTick = NO;

	if (getenv( "MACFSV_DEBUG" ) != NULL) {
		static int n = 0;
		static double t_sec = 0.0, worst = 0.0;
		double dt = xgettime( ) - t0;
		++n;
		if (dt > worst)
			worst = dt;
		if ((t0 - t_sec) >= 1.0) {
			NSLog( @"perf: %d frames/s, worst tick %.1f ms", n, 1000.0 * worst );
			n = 0;
			worst = 0.0;
			t_sec = t0;
		}
	}
}


- (void)displayLinkFired:(CADisplayLink *)link
{
	if (getenv( "MACFSV_DEBUG" ) != NULL) {
		static int n = 0;
		static double t_sec = 0.0;
		double t = xgettime( );
		++n;
		if ((t - t_sec) >= 1.0) {
			NSLog( @"display link: %d fires/s", n );
			n = 0;
			t_sec = t;
		}
	}
	[self tick];
}


/* Used during long operations, when the run loop may not get a chance
 * to fire the display link */
- (void)tickIfDue
{
	if (!_animating)
		return;
	if ((xgettime( ) - _lastTick) >= (1.0 / 30.0))
		[self tick];
}


/**** Mouse input ****/

- (void)updateTrackingAreas
{
	[super updateTrackingAreas];
	if (_trackingArea != nil)
		[self removeTrackingArea:_trackingArea];
	_trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect) owner:self userInfo:nil];
	[self addTrackingArea:_trackingArea];
}


/* Event location in viewport pixels (origin at top left) */
- (void)pixelLocation:(NSEvent *)event x:(int *)x y:(int *)y
{
	NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
	NSSize size = self.bounds.size;
	CGSize dsize = self.drawableSize;
	double kx = (size.width > 0.0) ? (dsize.width / size.width) : 1.0;
	double ky = (size.height > 0.0) ? (dsize.height / size.height) : 1.0;

	*x = (int)floor( p.x * kx );
	*y = (int)floor( (size.height - p.y) * ky );
}


- (unsigned int)stateForEvent:(NSEvent *)event
{
	unsigned int state = _buttons;
	NSEventModifierFlags mods = event.modifierFlags;

	if (mods & (NSEventModifierFlagControl | NSEventModifierFlagCommand))
		state |= VIEWPORT_CONTROL_MASK;

	return state;
}


- (void)press:(NSEvent *)event button:(int)button
{
	int x, y;

	[self pixelLocation:event x:&x y:&y];
	if (getenv( "MACFSV_DEBUG" ))
		NSLog( @"press %d at %d,%d moving=%d", button, x, y, camera_moving( ) );
	viewport_event( VIEWPORT_BUTTON_PRESS, x, y, button, [self stateForEvent:event] );
	_buttons |= (VIEWPORT_BUTTON1_MASK << (button - 1));
}


- (void)release:(NSEvent *)event button:(int)button
{
	int x, y;
	unsigned int state;

	if (!(_buttons & (VIEWPORT_BUTTON1_MASK << (button - 1))))
		return;
	[self pixelLocation:event x:&x y:&y];
	state = [self stateForEvent:event];
	_buttons &= ~(VIEWPORT_BUTTON1_MASK << (button - 1));
	viewport_event( VIEWPORT_BUTTON_RELEASE, x, y, button, state );
}


/* Debugging aid: per-second statistics on mouse event handling */
static void
debug_event_stats( double dt, BOOL is_wheel )
{
	static int n_motion = 0, n_wheel = 0;
	static double busy = 0.0, worst = 0.0, t_sec = 0.0;
	double t = xgettime( );

	if (is_wheel)
		++n_wheel;
	else
		++n_motion;
	busy += dt;
	if (dt > worst)
		worst = dt;
	if ((t - t_sec) >= 1.0) {
		NSLog( @"events: %d motion/s, %d wheel/s, %.1f ms busy, worst %.1f ms", n_motion, n_wheel, 1000.0 * busy, 1000.0 * worst );
		n_motion = n_wheel = 0;
		busy = worst = 0.0;
		t_sec = t;
	}
}


- (void)motion:(NSEvent *)event
{
	double t0 = xgettime( );
	int x, y;

	[self pixelLocation:event x:&x y:&y];
	viewport_event( VIEWPORT_MOTION, x, y, 0, [self stateForEvent:event] );
	if (getenv( "MACFSV_DEBUG" ) != NULL)
		debug_event_stats( xgettime( ) - t0, NO );
}


- (void)mouseDown:(NSEvent *)event
{
	[self.window makeFirstResponder:self];
	if ((event.modifierFlags & NSEventModifierFlagOption) && !(event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand))) {
		/* Option + left button stands in for the middle button */
		_optionDolly = YES;
		[self press:event button:2];
	}
	else {
		_optionDolly = NO;
		[self press:event button:1];
	}
}


- (void)mouseUp:(NSEvent *)event
{
	if (_optionDolly) {
		_optionDolly = NO;
		[self release:event button:2];
	}
	else
		[self release:event button:1];
}


- (void)rightMouseDown:(NSEvent *)event
{
	[self press:event button:3];
	/* The context menu (if any) swallowed the button release */
	if (!([NSEvent pressedMouseButtons] & (1 << 1)))
		_buttons &= ~VIEWPORT_BUTTON3_MASK;
}


- (void)rightMouseUp:(NSEvent *)event
{
	[self release:event button:3];
}


- (void)otherMouseDown:(NSEvent *)event
{
	if (event.buttonNumber == 2)
		[self press:event button:2];
}


- (void)otherMouseUp:(NSEvent *)event
{
	if (event.buttonNumber == 2)
		[self release:event button:2];
}


- (void)mouseMoved:(NSEvent *)event
{
	[self motion:event];
}


- (void)mouseDragged:(NSEvent *)event
{
	[self motion:event];
}


- (void)rightMouseDragged:(NSEvent *)event
{
	[self motion:event];
}


- (void)otherMouseDragged:(NSEvent *)event
{
	[self motion:event];
}


- (void)mouseExited:(NSEvent *)event
{
	if (_buttons == 0)
		viewport_event( VIEWPORT_LEAVE, 0, 0, 0, 0 );
}


- (void)scrollWheel:(NSEvent *)event
{
	double dy = event.scrollingDeltaY;

	if (!event.hasPreciseScrollingDeltas)
		dy *= 8.0;
	if (dy != 0.0) {
		double t0 = xgettime( );
		viewport_dolly( 0.5 * dy );
		if (getenv( "MACFSV_DEBUG" ) != NULL)
			debug_event_stats( xgettime( ) - t0, YES );
	}
}


- (void)magnifyWithEvent:(NSEvent *)event
{
	viewport_dolly( 200.0 * event.magnification );
}


- (void)setCursorGlyph:(int)glyph
{
	switch (glyph) {
		case GUI_CURSOR_DOUBLE_ARROW:
		[[NSCursor resizeUpDownCursor] set];
		break;

		case GUI_CURSOR_FLEUR:
		[[NSCursor closedHandCursor] set];
		break;

		case GUI_CURSOR_X:
		[[NSCursor operationNotAllowedCursor] set];
		break;

		default:
		[[NSCursor arrowCursor] set];
		break;
	}
}

@end


/**** C interface (gui.h) ****************/

void
gui_request_animation( void )
{
	[FSVMain.viewport requestAnimation];
}


void
gui_viewport_size( int *width, int *height )
{
	CGSize size = FSVMain.viewport.drawableSize;

	*width = MAX(1, (int)size.width);
	*height = MAX(1, (int)size.height);
}


void
gui_cursor( int glyph )
{
	[FSVMain.viewport setCursorGlyph:glyph];
}


void
gui_scrollbar_update( int axis, const struct _ScrollAdjustment *adj )
{
	[FSVMain updateScrollbar:axis adjustment:adj];
}


/* end FSVViewport.m */
