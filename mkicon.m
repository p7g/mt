/* Generate mt app icon - compile, run, then delete */
#import <Cocoa/Cocoa.h>
#import <CoreText/CoreText.h>

static NSImage *renderIcon(int size)
{
	NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
	[img lockFocus];

	CGFloat s = size;
	CGFloat r = s * 0.18; /* corner radius */
	NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, s, s)
	                                                   xRadius:r yRadius:r];

	/* Black background */
	[[NSColor blackColor] setFill];
	[bg fill];

	/* Subtle dark gradient overlay for depth */
	NSGradient *grad = [[NSGradient alloc]
	    initWithStartingColor:[NSColor colorWithWhite:0.15 alpha:0.6]
	              endingColor:[NSColor colorWithWhite:0.0 alpha:0.0]];
	[grad drawInBezierPath:bg angle:135];

	/* Glassy highlight at top */
	NSBezierPath *highlight = [NSBezierPath bezierPath];
	[highlight moveToPoint:NSMakePoint(s * 0.1, s * 0.95)];
	[highlight curveToPoint:NSMakePoint(s * 0.9, s * 0.95)
	         controlPoint1:NSMakePoint(s * 0.3, s * 0.98)
	         controlPoint2:NSMakePoint(s * 0.7, s * 0.98)];
	[highlight lineToPoint:NSMakePoint(s * 0.85, s * 0.65)];
	[highlight curveToPoint:NSMakePoint(s * 0.15, s * 0.70)
	         controlPoint1:NSMakePoint(s * 0.65, s * 0.60)
	         controlPoint2:NSMakePoint(s * 0.35, s * 0.62)];
	[highlight closePath];

	NSGradient *gloss = [[NSGradient alloc]
	    initWithStartingColor:[NSColor colorWithWhite:1.0 alpha:0.12]
	              endingColor:[NSColor colorWithWhite:1.0 alpha:0.0]];
	/* Clip to rounded rect */
	[NSGraphicsContext saveGraphicsState];
	[bg addClip];
	[gloss drawInBezierPath:highlight angle:270];
	[NSGraphicsContext restoreGraphicsState];

	/* Thin bright border for glass edge */
	[[NSColor colorWithWhite:1.0 alpha:0.08] setStroke];
	NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:
	    NSInsetRect(NSMakeRect(0, 0, s, s), 0.5, 0.5) xRadius:r yRadius:r];
	[border setLineWidth:1.0];
	[border stroke];

	/* "mt" text - sized to fill ~70% of the icon, centered on ink bounds */
	CGFloat fontSize = s * 0.55;
	NSFont *mono = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightBold];
	NSShadow *glow = [[NSShadow alloc] init];
	[glow setShadowColor:[NSColor colorWithWhite:1.0 alpha:0.3]];
	[glow setShadowBlurRadius:s * 0.04];
	[glow setShadowOffset:NSMakeSize(0, 0)];

	NSDictionary *attrs = @{
		NSFontAttributeName: mono,
		NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.95],
		NSShadowAttributeName: glow,
	};
	NSAttributedString *text = [[NSAttributedString alloc]
	    initWithString:@"mt" attributes:attrs];

	/* Use CTLineGetImageBounds for actual ink/glyph bounds */
	CTLineRef line = CTLineCreateWithAttributedString(
	    (__bridge CFAttributedStringRef)text);
	CGContextRef measCtx = CGBitmapContextCreate(NULL, (int)s, (int)s,
	    8, (int)s * 4,
	    CGColorSpaceCreateDeviceRGB(),
	    (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
	CGRect ink = CTLineGetImageBounds(line, measCtx);
	CGContextRelease(measCtx);
	CFRelease(line);

	/* Center on actual ink bounds.
	 * drawAtPoint y is in flipped coords (top-left origin).
	 * ink bounds are baseline-relative (CG coords, y-up).
	 * Ink top above baseline = ink.origin.y + ink.size.height
	 * In flipped coords: drawY + ascent - inkTop = desired top
	 * desired top = (s - ink.size.height) / 2
	 */
	CGFloat ascent = CTFontGetAscent((__bridge CTFontRef)mono);
	CGFloat tx = (s - ink.size.width) / 2 - ink.origin.x;
	CGFloat ty = (s - ink.size.height) / 2 - ascent + ink.origin.y + ink.size.height;
	[text drawAtPoint:NSMakePoint(tx, ty)];

	[img unlockFocus];
	return img;
}

static void savePNG(NSImage *img, int size, NSString *path)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
	    initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
	    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
	    colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
	[rep setSize:NSMakeSize(size, size)];

	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:
	    [NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
	[img drawInRect:NSMakeRect(0, 0, size, size)
	       fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
	[NSGraphicsContext restoreGraphicsState];

	NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
	[png writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[])
{
	@autoreleasepool {
		[NSApplication sharedApplication];

		NSString *iconset = @"mt.iconset";
		[[NSFileManager defaultManager] createDirectoryAtPath:iconset
		    withIntermediateDirectories:YES attributes:nil error:nil];

		struct { int size; NSString *name; } icons[] = {
			{16,   @"icon_16x16.png"},
			{32,   @"icon_16x16@2x.png"},
			{32,   @"icon_32x32.png"},
			{64,   @"icon_32x32@2x.png"},
			{128,  @"icon_128x128.png"},
			{256,  @"icon_128x128@2x.png"},
			{256,  @"icon_256x256.png"},
			{512,  @"icon_256x256@2x.png"},
			{512,  @"icon_512x512.png"},
			{1024, @"icon_512x512@2x.png"},
		};

		for (int i = 0; i < 10; i++) {
			NSImage *img = renderIcon(icons[i].size);
			NSString *path = [iconset stringByAppendingPathComponent:icons[i].name];
			savePNG(img, icons[i].size, path);
		}

		NSLog(@"Generated iconset");
	}
	return 0;
}
