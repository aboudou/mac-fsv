/* mkicon.m - builds the application's .iconset from fsv's original XPM
 * icon (pixel-doubled with nearest-neighbor scaling, for a crisp retro
 * look). Usage: mkicon <output.iconset> */

#import <Cocoa/Cocoa.h>

NSBitmapImageRep *FSVBitmapFromXPM( char **xpm, int scale );

#include "xmaps/fsv-icon.xpm"


static void
write_png( NSBitmapImageRep *rep, NSString *path )
{
	NSData *data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];

	if (![data writeToFile:path atomically:YES]) {
		fprintf( stderr, "mkicon: cannot write %s\n", path.fileSystemRepresentation );
		exit( 1 );
	}
}


/* Downscaled version (for the 16 and 32 pixel sizes) */
static NSBitmapImageRep *
downscaled( NSBitmapImageRep *src, int size )
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
	NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

	[NSGraphicsContext saveGraphicsState];
	NSGraphicsContext.currentContext = ctx;
	ctx.imageInterpolation = NSImageInterpolationHigh;
	[src drawInRect:NSMakeRect( 0, 0, size, size ) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0 respectFlipped:NO hints:nil];
	[NSGraphicsContext restoreGraphicsState];

	return rep;
}


int
main( int argc, char **argv )
{
	@autoreleasepool {
		NSString *dir;
		NSBitmapImageRep *base;
		struct { const char *name; int size; } icons[] = {
			{ "icon_16x16.png", 16 },
			{ "icon_16x16@2x.png", 32 },
			{ "icon_32x32.png", 32 },
			{ "icon_32x32@2x.png", 64 },
			{ "icon_128x128.png", 128 },
			{ "icon_128x128@2x.png", 256 },
			{ "icon_256x256.png", 256 },
			{ "icon_256x256@2x.png", 512 },
			{ "icon_512x512.png", 512 },
			{ "icon_512x512@2x.png", 1024 }
		};
		size_t i;

		if (argc != 2) {
			fprintf( stderr, "usage: mkicon <output.iconset>\n" );
			return 1;
		}
		dir = [NSString stringWithUTF8String:argv[1]];
		[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

		base = FSVBitmapFromXPM( fsv_icon_xpm, 1 );
		for (i = 0; i < sizeof(icons) / sizeof(icons[0]); i++) {
			NSBitmapImageRep *rep;
			int size = icons[i].size;

			if (size >= base.pixelsWide)
				rep = FSVBitmapFromXPM( fsv_icon_xpm, size / (int)base.pixelsWide );
			else
				rep = downscaled( base, size );
			write_png( rep, [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:icons[i].name]] );
		}
	}

	return 0;
}
