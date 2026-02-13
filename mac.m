/* See LICENSE for license details. */
#include <errno.h>
#include <math.h>
#include <limits.h>
#include <locale.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <libgen.h>

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <CoreText/CoreText.h>

char *argv0;
#include "arg.h"

/* Suppress MIN/MAX redefinition warnings from Foundation vs st.h */
#undef MIN
#undef MAX
#include "st.h"
#include "win.h"

/* Modifier masks */
#define MK_SHIFT   (1 << 0)
#define MK_CONTROL (1 << 1)
#define MK_OPTION  (1 << 2)
#define MK_COMMAND (1 << 3)
#define MK_ANY     UINT_MAX
#define MK_NONE    0

/* Mouse button aliases */
#define BTN_LEFT       1
#define BTN_MIDDLE     2
#define BTN_RIGHT      3
#define BTN_SCROLLUP   4
#define BTN_SCROLLDOWN 5

/* Types used in config.h */
typedef struct {
	uint mod;
	uint16_t keysym;
	void (*func)(const Arg *);
	const Arg arg;
} Shortcut;

typedef struct {
	uint mod;
	uint button;
	void (*func)(const Arg *);
	const Arg arg;
	uint release;
} MouseShortcut;

typedef struct {
	uint16_t k;
	uint mask;
	char *s;
	/* three-valued logic variables: 0 indifferent, 1 on, -1 off */
	signed char appkey;    /* application keypad */
	signed char appcursor; /* application cursor */
} Key;

/* function definitions used in config.h */
static void clipcopy(const Arg *);
static void clippaste(const Arg *);
static void numlock(const Arg *);
static void selpaste(const Arg *);
static void zoom(const Arg *);
static void zoomabs(const Arg *);
static void zoomreset(const Arg *);
static void ttysend(const Arg *);

/* config.h for applying patches and the configuration. */
#include "config.h"

/* macros */
#define IS_SET(flag)    ((win.mode & (flag)) != 0)
#define TRUERED(x)      (((x) & 0xff0000) >> 16)
#define TRUEGREEN(x)    (((x) & 0xff00) >> 8)
#define TRUEBLUE(x)     ((x) & 0xff)

/* Purely graphic info */
typedef struct {
	int tw, th; /* tty width and height */
	int w, h; /* window width and height */
	int ch; /* char height */
	int cw; /* char width  */
	int mode; /* window state/mode flags */
	int cursor; /* cursor style */
} TermWindow;

/* Font structure */
#define Font Font_
typedef struct {
	int height;
	int width;
	int ascent;
	int descent;
	int badslant;
	int badweight;
	short lbearing;
	short rbearing;
	CTFontRef match;
} Font;

/* Drawing Context */
typedef struct {
	CGColorRef *col;
	size_t collen;
	Font font, bfont, ifont, ibfont;
} DC;

/* Font Ring Cache */
enum {
	FRC_NORMAL,
	FRC_ITALIC,
	FRC_BOLD,
	FRC_ITALICBOLD
};

typedef struct {
	CTFontRef font;
	int flags;
	Rune unicodep;
} Fontcache;

/* Selection state */
typedef struct {
	char *primary, *clipboard;
	struct timespec tclick1;
	struct timespec tclick2;
} MTSelection;

/* Glyph+font spec for rendering */
typedef struct {
	CTFontRef font;
	CGGlyph glyph;
	float x, y;
} GlyphFontSpec;

/* Forward declarations */
@class MTAppDelegate;

@interface MTView : NSView <NSTextInputClient>
{
	NSMutableAttributedString *_markedText;
}
@end

static inline ushort sixd_to_16bit(int);
static int xmakeglyphfontspecs(GlyphFontSpec *, const Glyph *, int, int, int);
static void xdrawglyphfontspecs(const GlyphFontSpec *, Glyph, int, int, int);
static void xdrawglyph(Glyph, int, int);
static void xclear(int, int, int, int);
static void xloadfont(Font *, CTFontRef);
static void xloadfonts(const char *, double);
static void xunloadfont(Font *);
static void xunloadfonts(void);
static void cresize(int, int);
static void xresize(int, int);
static char *kmap(uint16_t, uint);
static int match(uint, uint);
static void schedule_draw(void);
static void macinit(int, int);
static void usage(void);
static uint modflags(NSEventModifierFlags);

/* Globals */
static DC dc;
static TermWindow win;
static MTSelection msel;
static CGContextRef backbuf;
static CGFloat backingscale = 1.0;
static NSWindow *macwin;
static MTView *mtview;

static Fontcache *frc = NULL;
static int frclen = 0;
static int frccap = 0;
static char *usedfont = NULL;
static double usedfontsize = 0;
static double defaultfontsize = 0;

static GlyphFontSpec *specbuf = NULL;

static char **opt_cmd  = NULL;
static char *opt_font  = NULL;
static char *opt_io    = NULL;
static char *opt_line  = NULL;
static char *opt_title = NULL;

static uint buttons; /* bit field of pressed buttons */
static int ttyfd = -1;
static dispatch_source_t ttysrc;
static dispatch_source_t drawtimer;
static int drawing = 0;
static struct timespec trigger;
static struct timespec lastblink = {0};

/* ---------- clipboard / shortcuts ---------- */

void
clipcopy(const Arg *dummy)
{
	@autoreleasepool {
		free(msel.clipboard);
		msel.clipboard = NULL;

		if (msel.primary != NULL) {
			msel.clipboard = xstrdup(msel.primary);
			NSPasteboard *pb = [NSPasteboard generalPasteboard];
			[pb clearContents];
			[pb setString:[NSString stringWithUTF8String:msel.clipboard]
			      forType:NSPasteboardTypeString];
		}
	}
}

void
clippaste(const Arg *dummy)
{
	@autoreleasepool {
		NSPasteboard *pb = [NSPasteboard generalPasteboard];
		NSString *str = [pb stringForType:NSPasteboardTypeString];
		if (str == nil)
			return;
		const char *s = [str UTF8String];
		size_t len = strlen(s);
		/* replace \n with \r */
		char *buf = xmalloc(len);
		memcpy(buf, s, len);
		for (size_t i = 0; i < len; i++)
			if (buf[i] == '\n')
				buf[i] = '\r';
		if (IS_SET(MODE_BRCKTPASTE))
			ttywrite("\033[200~", 6, 0);
		ttywrite(buf, len, 1);
		if (IS_SET(MODE_BRCKTPASTE))
			ttywrite("\033[201~", 6, 0);
		free(buf);
	}
}

void
selpaste(const Arg *dummy)
{
	/* On macOS, primary selection = clipboard */
	clippaste(dummy);
}

void
numlock(const Arg *dummy)
{
	win.mode ^= MODE_NUMLOCK;
}

void
zoom(const Arg *arg)
{
	Arg larg;
	larg.f = usedfontsize + arg->f;
	zoomabs(&larg);
}

void
zoomabs(const Arg *arg)
{
	xunloadfonts();
	xloadfonts(usedfont, arg->f);
	cresize(0, 0);
	redraw();
}

void
zoomreset(const Arg *arg)
{
	Arg larg;
	if (defaultfontsize > 0) {
		larg.f = defaultfontsize;
		zoomabs(&larg);
	}
}

void
ttysend(const Arg *arg)
{
	ttywrite(arg->s, strlen(arg->s), 1);
}

/* ---------- modifier / match helpers ---------- */

uint
modflags(NSEventModifierFlags flags)
{
	uint m = 0;
	if (flags & NSEventModifierFlagShift)   m |= MK_SHIFT;
	if (flags & NSEventModifierFlagControl) m |= MK_CONTROL;
	if (flags & NSEventModifierFlagOption)  m |= MK_OPTION;
	if (flags & NSEventModifierFlagCommand) m |= MK_COMMAND;
	return m;
}

int
match(uint mask, uint state)
{
	return mask == MK_ANY || mask == (state & ~ignoremod);
}

char *
kmap(uint16_t k, uint state)
{
	Key *kp;

	for (kp = key; kp < key + LEN(key); kp++) {
		if (kp->k != k)
			continue;
		if (!match(kp->mask, state))
			continue;
		if (IS_SET(MODE_APPKEYPAD) ? kp->appkey < 0 : kp->appkey > 0)
			continue;
		if (IS_SET(MODE_NUMLOCK) && kp->appkey == 2)
			continue;
		if (IS_SET(MODE_APPCURSOR) ? kp->appcursor < 0 : kp->appcursor > 0)
			continue;
		return kp->s;
	}

	return NULL;
}

/* ---------- colors ---------- */

ushort
sixd_to_16bit(int x)
{
	return x == 0 ? 0 : 0x3737 + 0x2828 * x;
}

static CGColorRef
makecol(CGFloat r, CGFloat g, CGFloat b, CGFloat a)
{
	static CGColorSpaceRef cs;
	if (!cs)
		cs = CGColorSpaceCreateDeviceRGB();
	CGFloat comps[4] = {r, g, b, a};
	return CGColorCreate(cs, comps);
}

static int
xloadcolor(int i, const char *name, CGColorRef *ncolor)
{
	if (!name) {
		if (BETWEEN(i, 16, 255)) { /* 256 color */
			CGFloat r, g, b;
			if (i < 6*6*6+16) { /* same colors as xterm */
				r = sixd_to_16bit(((i-16)/36)%6) / 65535.0;
				g = sixd_to_16bit(((i-16)/6)%6)  / 65535.0;
				b = sixd_to_16bit(((i-16)/1)%6)  / 65535.0;
			} else { /* greyscale */
				r = (0x0808 + 0x0a0a * (i - (6*6*6+16))) / 65535.0;
				g = b = r;
			}
			*ncolor = makecol(r, g, b, 1.0);
			return 1;
		} else {
			name = colorname[i];
		}
	}

	if (!name)
		return 0;

	/* Parse hex color: "#rrggbb" */
	if (name[0] == '#' && strlen(name) == 7) {
		unsigned int rv, gv, bv;
		if (sscanf(name, "#%02x%02x%02x", &rv, &gv, &bv) == 3) {
			*ncolor = makecol(rv/255.0, gv/255.0, bv/255.0, 1.0);
			return 1;
		}
	}

	/* Parse named colors - support basic CSS/X11 names */
	struct { const char *name; CGFloat r, g, b; } namedcols[] = {
		{"black",   0, 0, 0},
		{"red",     1, 0, 0},
		{"green",   0, 1, 0},
		{"yellow",  1, 1, 0},
		{"blue",    0, 0, 1},
		{"magenta", 1, 0, 1},
		{"cyan",    0, 1, 1},
		{"white",   1, 1, 1},
		{"red3",    0.804, 0, 0},
		{"green3",  0, 0.804, 0},
		{"yellow3", 0.804, 0.804, 0},
		{"blue2",   0, 0, 0.933},
		{"magenta3",0.804, 0, 0.804},
		{"cyan3",   0, 0.804, 0.804},
		{"gray90",  0.898, 0.898, 0.898},
		{"gray50",  0.498, 0.498, 0.498},
	};
	for (size_t j = 0; j < sizeof(namedcols)/sizeof(namedcols[0]); j++) {
		if (strcasecmp(name, namedcols[j].name) == 0) {
			*ncolor = makecol(namedcols[j].r, namedcols[j].g, namedcols[j].b, 1.0);
			return 1;
		}
	}

	return 0;
}

void
xloadcols(void)
{
	int i;
	static int loaded;

	if (loaded) {
		for (size_t j = 0; j < dc.collen; ++j)
			if (dc.col[j])
				CGColorRelease(dc.col[j]);
	} else {
		dc.collen = MAX(LEN(colorname), 256);
		dc.col = xmalloc(dc.collen * sizeof(CGColorRef));
		memset(dc.col, 0, dc.collen * sizeof(CGColorRef));
	}

	for (i = 0; i < (int)dc.collen; i++)
		if (!xloadcolor(i, NULL, &dc.col[i])) {
			if (colorname[i])
				die("could not allocate color '%s'\n", colorname[i]);
			else
				die("could not allocate color %d\n", i);
		}
	loaded = 1;
}

int
xgetcolor(int x, unsigned char *r, unsigned char *g, unsigned char *b)
{
	if (!BETWEEN(x, 0, (int)dc.collen - 1))
		return 1;

	const CGFloat *comps = CGColorGetComponents(dc.col[x]);
	*r = (unsigned char)(comps[0] * 255);
	*g = (unsigned char)(comps[1] * 255);
	*b = (unsigned char)(comps[2] * 255);

	return 0;
}

int
xsetcolorname(int x, const char *name)
{
	CGColorRef ncolor;

	if (!BETWEEN(x, 0, (int)dc.collen - 1))
		return 1;

	if (!xloadcolor(x, name, &ncolor))
		return 1;

	if (dc.col[x])
		CGColorRelease(dc.col[x]);
	dc.col[x] = ncolor;

	return 0;
}

/* ---------- CGColor helpers for drawing ---------- */

static void
cgsetcolor(CGContextRef ctx, CGColorRef c)
{
	CGContextSetFillColorWithColor(ctx, c);
}

static CGColorRef
maketruecolor(uint32_t c)
{
	return makecol(TRUERED(c)/255.0, TRUEGREEN(c)/255.0, TRUEBLUE(c)/255.0, 1.0);
}

/* ---------- fonts ---------- */

void
xloadfont(Font *f, CTFontRef ctfont)
{
	f->match = ctfont;

	f->ascent = (int)ceilf(CTFontGetAscent(ctfont));
	f->descent = (int)ceilf(CTFontGetDescent(ctfont));
	f->height = f->ascent + f->descent;
	f->lbearing = 0;
	f->rbearing = (int)ceilf(CTFontGetBoundingBox(ctfont).size.width);

	/* Measure average character width using ascii_printable */
	size_t plen = strlen(ascii_printable);
	CFStringRef pstr = CFStringCreateWithCString(NULL, ascii_printable,
	                                             kCFStringEncodingUTF8);
	CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 1,
	    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(attrs, kCTFontAttributeName, ctfont);
	CFAttributedStringRef astr = CFAttributedStringCreate(NULL, pstr, attrs);
	CTLineRef line = CTLineCreateWithAttributedString(astr);
	CGFloat totalwidth = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	CFRelease(line);
	CFRelease(astr);
	CFRelease(attrs);
	CFRelease(pstr);

	f->width = (int)ceilf(totalwidth / plen);
	f->badslant = 0;
	f->badweight = 0;
}

void
xloadfonts(const char *fontstr, double fontsize)
{
	@autoreleasepool {
		CGFloat size;

		/* Parse "Name:size=N" format */
		NSString *fstr = [NSString stringWithUTF8String:fontstr];
		NSString *fname = fstr;
		size = 12.0; /* default */

		NSRange sizeRange = [fstr rangeOfString:@":size="];
		if (sizeRange.location != NSNotFound) {
			fname = [fstr substringToIndex:sizeRange.location];
			NSString *sizeStr = [fstr substringFromIndex:
			    sizeRange.location + sizeRange.length];
			size = [sizeStr doubleValue];
		}

		if (fontsize > 1)
			size = fontsize;

		usedfontsize = size;
		if (fontsize == 0 || defaultfontsize == 0)
			defaultfontsize = size;

		CTFontRef base = CTFontCreateWithName((__bridge CFStringRef)fname,
		                                      size, NULL);
		if (!base)
			die("can't open font %s\n", fontstr);

		xloadfont(&dc.font, base);

		/* italic */
		CTFontRef italic = CTFontCreateCopyWithSymbolicTraits(
		    base, size, NULL, kCTFontItalicTrait, kCTFontItalicTrait);
		if (!italic) italic = CFRetain(base);
		xloadfont(&dc.ifont, italic);

		/* bold */
		CTFontRef bold = CTFontCreateCopyWithSymbolicTraits(
		    base, size, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
		if (!bold) bold = CFRetain(base);
		xloadfont(&dc.bfont, bold);

		/* bold italic */
		CTFontRef bolditalic = CTFontCreateCopyWithSymbolicTraits(
		    base, size, NULL,
		    kCTFontBoldTrait | kCTFontItalicTrait,
		    kCTFontBoldTrait | kCTFontItalicTrait);
		if (!bolditalic) bolditalic = CFRetain(base);
		xloadfont(&dc.ibfont, bolditalic);

		/* Setting character width and height. */
		win.cw = ceilf(dc.font.width * cwscale);
		win.ch = ceilf(dc.font.height * chscale);
	}
}

void
xunloadfont(Font *f)
{
	if (f->match)
		CFRelease(f->match);
	f->match = NULL;
}

void
xunloadfonts(void)
{
	while (frclen > 0) {
		CFRelease(frc[--frclen].font);
	}

	xunloadfont(&dc.font);
	xunloadfont(&dc.bfont);
	xunloadfont(&dc.ifont);
	xunloadfont(&dc.ibfont);
}

/* ---------- back buffer ---------- */

static void
recreatebackbuf(void)
{
	if (backbuf)
		CGContextRelease(backbuf);

	int pw = (int)(win.w * backingscale);
	int ph = (int)(win.h * backingscale);
	static CGColorSpaceRef cs;
	if (!cs)
		cs = CGColorSpaceCreateDeviceRGB();
	backbuf = CGBitmapContextCreate(NULL, pw, ph, 8, pw * 4, cs,
	    kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);

	/* Flip coordinate system and scale for Retina */
	CGContextTranslateCTM(backbuf, 0, ph);
	CGContextScaleCTM(backbuf, backingscale, -backingscale);
}

/* ---------- drawing ---------- */

void
xclear(int x1, int y1, int x2, int y2)
{
	CGColorRef c = dc.col[IS_SET(MODE_REVERSE) ? defaultfg : defaultbg];
	cgsetcolor(backbuf, c);
	CGContextFillRect(backbuf, CGRectMake(x1, y1, x2-x1, y2-y1));
}

int
xmakeglyphfontspecs(GlyphFontSpec *specs, const Glyph *glyphs, int len, int x, int y)
{
	float winx = borderpx + x * win.cw, winy = borderpx + y * win.ch, xp, yp;
	ushort mode, prevmode = USHRT_MAX;
	Font *font = &dc.font;
	int frcflags = FRC_NORMAL;
	float runewidth = win.cw;
	Rune rune;
	int i, f, numspecs = 0;

	for (i = 0, xp = winx, yp = winy + font->ascent; i < len; ++i) {
		rune = glyphs[i].u;
		mode = glyphs[i].mode;

		if (mode == ATTR_WDUMMY)
			continue;

		if (prevmode != mode) {
			prevmode = mode;
			font = &dc.font;
			frcflags = FRC_NORMAL;
			runewidth = win.cw * ((mode & ATTR_WIDE) ? 2.0f : 1.0f);
			if ((mode & ATTR_ITALIC) && (mode & ATTR_BOLD)) {
				font = &dc.ibfont;
				frcflags = FRC_ITALICBOLD;
			} else if (mode & ATTR_ITALIC) {
				font = &dc.ifont;
				frcflags = FRC_ITALIC;
			} else if (mode & ATTR_BOLD) {
				font = &dc.bfont;
				frcflags = FRC_BOLD;
			}
			yp = winy + font->ascent;
		}

		/* Look up glyph in primary font */
		UniChar uc = (UniChar)rune;
		CGGlyph glyph = 0;
		if (CTFontGetGlyphsForCharacters(font->match, &uc, &glyph, 1) && glyph) {
			specs[numspecs].font = font->match;
			specs[numspecs].glyph = glyph;
			specs[numspecs].x = xp;
			specs[numspecs].y = yp;
			xp += runewidth;
			numspecs++;
			continue;
		}

		/* Fallback: search font cache */
		for (f = 0; f < frclen; f++) {
			if (CTFontGetGlyphsForCharacters(frc[f].font, &uc, &glyph, 1)
			    && glyph && frc[f].flags == frcflags)
				break;
			if (!glyph && frc[f].flags == frcflags && frc[f].unicodep == rune)
				break;
		}

		/* Nothing in cache: use CTFontCreateForString to find fallback */
		if (f >= frclen) {
			@autoreleasepool {
				NSString *str = [[NSString alloc] initWithCharacters:&uc length:1];
				CTFontRef fbfont = CTFontCreateForString(font->match,
				    (__bridge CFStringRef)str, CFRangeMake(0, [str length]));
				if (!fbfont)
					fbfont = (CTFontRef)CFRetain(font->match);

				if (frclen >= frccap) {
					frccap += 16;
					frc = xrealloc(frc, frccap * sizeof(Fontcache));
				}

				frc[frclen].font = fbfont;
				frc[frclen].flags = frcflags;
				frc[frclen].unicodep = rune;

				CTFontGetGlyphsForCharacters(fbfont, &uc, &glyph, 1);
				f = frclen;
				frclen++;
			}
		}

		specs[numspecs].font = frc[f].font;
		specs[numspecs].glyph = glyph;
		specs[numspecs].x = xp;
		specs[numspecs].y = yp;
		xp += runewidth;
		numspecs++;
	}

	return numspecs;
}

void
xdrawglyphfontspecs(const GlyphFontSpec *specs, Glyph base, int len, int x, int y)
{
	int charlen = len * ((base.mode & ATTR_WIDE) ? 2 : 1);
	int winx = borderpx + x * win.cw, winy = borderpx + y * win.ch,
	    width = charlen * win.cw;
	CGColorRef fg, bg, temp;
	CGColorRef truefg = NULL, truebg = NULL, revfg = NULL, revbg = NULL, faintfg = NULL;

	/* Fallback on color display for attributes not supported by the font */
	if (base.mode & ATTR_ITALIC && base.mode & ATTR_BOLD) {
		if (dc.ibfont.badslant || dc.ibfont.badweight)
			base.fg = defaultattr;
	} else if ((base.mode & ATTR_ITALIC && dc.ifont.badslant) ||
	    (base.mode & ATTR_BOLD && dc.bfont.badweight)) {
		base.fg = defaultattr;
	}

	if (IS_TRUECOL(base.fg)) {
		truefg = maketruecolor(base.fg);
		fg = truefg;
	} else {
		fg = dc.col[base.fg];
	}

	if (IS_TRUECOL(base.bg)) {
		truebg = maketruecolor(base.bg);
		bg = truebg;
	} else {
		bg = dc.col[base.bg];
	}

	/* Change basic system colors [0-7] to bright system colors [8-15] */
	if ((base.mode & ATTR_BOLD_FAINT) == ATTR_BOLD && BETWEEN(base.fg, 0, 7))
		fg = dc.col[base.fg + 8];

	if (IS_SET(MODE_REVERSE)) {
		if (fg == dc.col[defaultfg]) {
			fg = dc.col[defaultbg];
		} else {
			const CGFloat *c = CGColorGetComponents(fg);
			revfg = makecol(1.0-c[0], 1.0-c[1], 1.0-c[2], 1.0);
			fg = revfg;
		}
		if (bg == dc.col[defaultbg]) {
			bg = dc.col[defaultfg];
		} else {
			const CGFloat *c = CGColorGetComponents(bg);
			revbg = makecol(1.0-c[0], 1.0-c[1], 1.0-c[2], 1.0);
			bg = revbg;
		}
	}

	if ((base.mode & ATTR_BOLD_FAINT) == ATTR_FAINT) {
		const CGFloat *c = CGColorGetComponents(fg);
		faintfg = makecol(c[0]/2, c[1]/2, c[2]/2, 1.0);
		fg = faintfg;
	}

	if (base.mode & ATTR_REVERSE) {
		temp = fg;
		fg = bg;
		bg = temp;
	}

	if (base.mode & ATTR_BLINK && win.mode & MODE_BLINK)
		fg = bg;

	if (base.mode & ATTR_INVISIBLE)
		fg = bg;

	/* Intelligent cleaning up of the borders. */
	if (x == 0) {
		xclear(0, (y == 0)? 0 : winy, borderpx,
			winy + win.ch +
			((winy + win.ch >= borderpx + win.th)? win.h : 0));
	}
	if (winx + width >= borderpx + win.tw) {
		xclear(winx + width, (y == 0)? 0 : winy, win.w,
			((winy + win.ch >= borderpx + win.th)? win.h : (winy + win.ch)));
	}
	if (y == 0)
		xclear(winx, 0, winx + width, borderpx);
	if (winy + win.ch >= borderpx + win.th)
		xclear(winx, winy + win.ch, winx + width, win.h);

	/* Draw background */
	cgsetcolor(backbuf, bg);
	CGContextFillRect(backbuf, CGRectMake(winx, winy, width, win.ch));

	/* Draw glyphs */
	CGContextSaveGState(backbuf);
	CGContextClipToRect(backbuf, CGRectMake(winx, winy, width, win.ch));

	/* We need to draw in flipped coordinates */
	const CGFloat *fgcomps = CGColorGetComponents(fg);
	CGContextSetRGBFillColor(backbuf, fgcomps[0], fgcomps[1], fgcomps[2], 1.0);

	/* Group glyphs by font for batch drawing.
	 * Use stack buffers for typical runs; fall back to heap for huge ones. */
	#define STACK_GLYPHS 512
	CGGlyph  sglyphs[STACK_GLYPHS];
	CGPoint  spositions[STACK_GLYPHS];
	int start = 0;
	while (start < len) {
		CTFontRef curfont = specs[start].font;
		int end = start + 1;
		while (end < len && specs[end].font == curfont)
			end++;

		int count = end - start;
		CGGlyph *glyphs = (count <= STACK_GLYPHS) ? sglyphs
		    : xmalloc(count * sizeof(CGGlyph));
		CGPoint *positions = (count <= STACK_GLYPHS) ? spositions
		    : xmalloc(count * sizeof(CGPoint));
		for (int j = 0; j < count; j++) {
			glyphs[j] = specs[start+j].glyph;
			/* Compute flipped y directly: Core Text draws in
			 * y-up coords, so negate y after the scale(-1) flip. */
			positions[j] = CGPointMake(specs[start+j].x,
			    -specs[start+j].y);
		}

		/* Draw text by temporarily unflipping for Core Text */
		CGContextSaveGState(backbuf);
		CGContextScaleCTM(backbuf, 1.0, -1.0);
		CTFontDrawGlyphs(curfont, glyphs, positions, count, backbuf);
		CGContextRestoreGState(backbuf);

		if (glyphs != sglyphs) free(glyphs);
		if (positions != spositions) free(positions);
		start = end;
	}
	#undef STACK_GLYPHS

	/* Render underline */
	if (base.mode & ATTR_UNDERLINE) {
		cgsetcolor(backbuf, fg);
		CGContextFillRect(backbuf, CGRectMake(winx,
		    winy + (int)(dc.font.ascent * chscale) + 1, width, 1));
	}

	/* Render strikethrough */
	if (base.mode & ATTR_STRUCK) {
		cgsetcolor(backbuf, fg);
		CGContextFillRect(backbuf, CGRectMake(winx,
		    winy + 2 * (int)(dc.font.ascent * chscale) / 3, width, 1));
	}

	CGContextRestoreGState(backbuf);

	if (truefg) CGColorRelease(truefg);
	if (truebg) CGColorRelease(truebg);
	if (revfg) CGColorRelease(revfg);
	if (revbg) CGColorRelease(revbg);
	if (faintfg) CGColorRelease(faintfg);
}

void
xdrawglyph(Glyph g, int x, int y)
{
	int numspecs;
	GlyphFontSpec spec;

	numspecs = xmakeglyphfontspecs(&spec, &g, 1, x, y);
	xdrawglyphfontspecs(&spec, g, numspecs, x, y);
}

void
xdrawcursor(int cx, int cy, Glyph g, int ox, int oy, Glyph og)
{
	CGColorRef drawcol;

	/* remove the old cursor */
	if (selected(ox, oy))
		og.mode ^= ATTR_REVERSE;
	xdrawglyph(og, ox, oy);

	if (IS_SET(MODE_HIDE))
		return;

	/*
	 * Select the right color for the right mode.
	 */
	g.mode &= ATTR_BOLD|ATTR_ITALIC|ATTR_UNDERLINE|ATTR_STRUCK|ATTR_WIDE;

	if (IS_SET(MODE_REVERSE)) {
		g.mode |= ATTR_REVERSE;
		g.bg = defaultfg;
		if (selected(cx, cy)) {
			drawcol = dc.col[defaultcs];
			g.fg = defaultrcs;
		} else {
			drawcol = dc.col[defaultrcs];
			g.fg = defaultcs;
		}
	} else {
		if (selected(cx, cy)) {
			g.fg = defaultfg;
			g.bg = defaultrcs;
		} else {
			g.fg = defaultbg;
			g.bg = defaultcs;
		}
		drawcol = dc.col[g.bg];
	}

	/* draw the new one */
	if (IS_SET(MODE_FOCUSED)) {
		switch (win.cursor) {
		case 7: /* st extension */
			g.u = 0x2603; /* snowman (U+2603) */
			/* FALLTHROUGH */
		case 0: /* Blinking Block */
		case 1: /* Blinking Block (Default) */
		case 2: /* Steady Block */
			xdrawglyph(g, cx, cy);
			break;
		case 3: /* Blinking Underline */
		case 4: /* Steady Underline */
			cgsetcolor(backbuf, drawcol);
			CGContextFillRect(backbuf, CGRectMake(
			    borderpx + cx * win.cw,
			    borderpx + (cy + 1) * win.ch - cursorthickness,
			    win.cw, cursorthickness));
			break;
		case 5: /* Blinking bar */
		case 6: /* Steady bar */
			cgsetcolor(backbuf, drawcol);
			CGContextFillRect(backbuf, CGRectMake(
			    borderpx + cx * win.cw,
			    borderpx + cy * win.ch,
			    cursorthickness, win.ch));
			break;
		}
	} else {
		cgsetcolor(backbuf, drawcol);
		CGContextFillRect(backbuf, CGRectMake(
		    borderpx + cx * win.cw,
		    borderpx + cy * win.ch,
		    win.cw - 1, 1));
		CGContextFillRect(backbuf, CGRectMake(
		    borderpx + cx * win.cw,
		    borderpx + cy * win.ch,
		    1, win.ch - 1));
		CGContextFillRect(backbuf, CGRectMake(
		    borderpx + (cx + 1) * win.cw - 1,
		    borderpx + cy * win.ch,
		    1, win.ch - 1));
		CGContextFillRect(backbuf, CGRectMake(
		    borderpx + cx * win.cw,
		    borderpx + (cy + 1) * win.ch - 1,
		    win.cw, 1));
	}
}

int
xstartdraw(void)
{
	return IS_SET(MODE_VISIBLE);
}

void
xdrawline(Line line, int x1, int y1, int x2)
{
	int i, x, ox, numspecs;
	Glyph base, new;
	GlyphFontSpec *specs = specbuf;

	numspecs = xmakeglyphfontspecs(specs, &line[x1], x2 - x1, x1, y1);
	i = ox = 0;
	for (x = x1; x < x2 && i < numspecs; x++) {
		new = line[x];
		if (new.mode == ATTR_WDUMMY)
			continue;
		if (selected(x, y1))
			new.mode ^= ATTR_REVERSE;
		if (i > 0 && ATTRCMP(base, new)) {
			xdrawglyphfontspecs(specs, base, i, ox, y1);
			specs += i;
			numspecs -= i;
			i = 0;
		}
		if (i == 0) {
			ox = x;
			base = new;
		}
		i++;
	}
	if (i > 0)
		xdrawglyphfontspecs(specs, base, i, ox, y1);
}

void
xfinishdraw(void)
{
	@autoreleasepool {
		if (!backbuf)
			return;

		CGImageRef img = CGBitmapContextCreateImage(backbuf);
		if (img && mtview) {
			[mtview.layer setContents:(__bridge id)img];
			CGImageRelease(img);
		}
	}
}

void
xximspot(int x, int y)
{
	/* No-op: macOS input methods handle positioning automatically */
	(void)x;
	(void)y;
}

/* ---------- window operations ---------- */

void
xclipcopy(void)
{
	clipcopy(NULL);
}

void
xsetsel(char *str)
{
	if (!str)
		return;

	free(msel.primary);
	msel.primary = str;
}

void
xsettitle(char *p)
{
	@autoreleasepool {
		DEFAULT(p, opt_title);
		if (p[0] == '\0')
			p = opt_title;
		[macwin setTitle:[NSString stringWithUTF8String:p]];
	}
}

void
xseticontitle(char *p)
{
	xsettitle(p);
}

void
xsetpointermotion(int set)
{
	/* macOS always receives mouse moved events when we track them via NSView */
	(void)set;
}

void
xsetmode(int set, unsigned int flags)
{
	int mode = win.mode;
	MODBIT(win.mode, set, flags);
	if ((win.mode & MODE_REVERSE) != (mode & MODE_REVERSE))
		redraw();
}

int
xsetcursor(int cursor)
{
	if (!BETWEEN(cursor, 0, 7)) /* 7: st extension */
		return 1;
	win.cursor = cursor;
	schedule_draw();
	return 0;
}

void
xbell(void)
{
	if (bellvolume)
		NSBeep();
}

/* ---------- resize ---------- */

void
cresize(int width, int height)
{
	int col, row;

	if (width != 0)
		win.w = width;
	if (height != 0)
		win.h = height;

	col = (win.w - 2 * borderpx) / win.cw;
	row = (win.h - 2 * borderpx) / win.ch;
	col = MAX(1, col);
	row = MAX(1, row);

	tresize(col, row);
	xresize(col, row);
	ttyresize(win.tw, win.th);
}

void
xresize(int col, int row)
{
	win.tw = col * win.cw;
	win.th = row * win.ch;

	recreatebackbuf();
	specbuf = xrealloc(specbuf, col * sizeof(GlyphFontSpec));
	xclear(0, 0, win.w, win.h);
}

/* ---------- draw scheduling ---------- */

void
schedule_draw(void)
{
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);

	if (!drawing) {
		trigger = now;
		drawing = 1;
	}

	double timeout = (maxlatency - TIMEDIFF(now, trigger))
	                 / maxlatency * minlatency;

	if (timeout <= 0) {
		/* maxlatency exhausted, draw now */
		if (blinktimeout && tattrset(ATTR_BLINK)) {
			double bt = blinktimeout - TIMEDIFF(now, lastblink);
			if (bt <= 0) {
				if (-bt > blinktimeout)
					win.mode |= MODE_BLINK;
				win.mode ^= MODE_BLINK;
				tsetdirtattr(ATTR_BLINK);
				lastblink = now;
			}
		}
		draw();
		drawing = 0;
		return;
	}

	/* Schedule (or reschedule) a persistent timer */
	uint64_t ns = (uint64_t)(timeout * 1e6);
	if (!drawtimer) {
		drawtimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
		    0, 0, dispatch_get_main_queue());
		dispatch_source_set_event_handler(drawtimer, ^{
			/* Idle the timer until next schedule_draw() */
			dispatch_source_set_timer(drawtimer,
			    DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);

			struct timespec now2;
			clock_gettime(CLOCK_MONOTONIC, &now2);

			if (blinktimeout && tattrset(ATTR_BLINK)) {
				double bt = blinktimeout - TIMEDIFF(now2, lastblink);
				if (bt <= 0) {
					if (-bt > blinktimeout)
						win.mode |= MODE_BLINK;
					win.mode ^= MODE_BLINK;
					tsetdirtattr(ATTR_BLINK);
					lastblink = now2;
				}
			}

			draw();
			drawing = 0;
		});
		dispatch_resume(drawtimer);
	}
	dispatch_source_set_timer(drawtimer,
	    dispatch_time(DISPATCH_TIME_NOW, ns),
	    DISPATCH_TIME_FOREVER, ns / 10);
}

/* ---------- blink timer ---------- */

static void
setup_blink_timer(void)
{
	if (blinktimeout == 0)
		return;

	dispatch_source_t blinksrc = dispatch_source_create(
	    DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	uint64_t ns = (uint64_t)blinktimeout * NSEC_PER_MSEC;
	dispatch_source_set_timer(blinksrc, dispatch_time(DISPATCH_TIME_NOW, ns),
	    ns, ns / 10);
	dispatch_source_set_event_handler(blinksrc, ^{
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (tattrset(ATTR_BLINK)) {
			win.mode ^= MODE_BLINK;
			tsetdirtattr(ATTR_BLINK);
			lastblink = now;
			draw();
		}
	});
	dispatch_resume(blinksrc);
}

/* ---------- mouse event helpers ---------- */

static int
evcol(NSPoint p)
{
	int x = (int)p.x - borderpx;
	LIMIT(x, 0, win.tw - 1);
	return x / win.cw;
}

static int
evrow(NSPoint p)
{
	int y = (int)p.y - borderpx;
	LIMIT(y, 0, win.th - 1);
	return y / win.ch;
}

static void
mousesel(NSPoint p, uint state, int done)
{
	int type, seltype = SEL_REGULAR;
	uint cleanstate = state & ~(forcemousemod);

	for (type = 1; type < (int)LEN(selmasks); ++type) {
		if (match(selmasks[type], cleanstate)) {
			seltype = type;
			break;
		}
	}
	selextend(evcol(p), evrow(p), seltype, done);
	if (done)
		xsetsel(getsel());
}

static void
mousereport(int x, int y, int btn, int evt, uint state)
{
	int len, code;
	char buf[40];
	static int ox, oy;

	if (evt == NSEventTypeMouseMoved || evt == NSEventTypeLeftMouseDragged ||
	    evt == NSEventTypeRightMouseDragged || evt == NSEventTypeOtherMouseDragged) {
		if (x == ox && y == oy)
			return;
		if (!IS_SET(MODE_MOUSEMOTION) && !IS_SET(MODE_MOUSEMANY))
			return;
		if (IS_SET(MODE_MOUSEMOTION) && buttons == 0)
			return;
		/* Find lowest-numbered pressed button or 12 */
		for (btn = 1; btn <= 11 && !(buttons & (1<<(btn-1))); btn++)
			;
		code = 32;
	} else if (evt == NSEventTypeLeftMouseUp || evt == NSEventTypeRightMouseUp ||
	           evt == NSEventTypeOtherMouseUp) {
		if (btn < 1 || btn > 11)
			return;
		if (IS_SET(MODE_MOUSEX10))
			return;
		if (btn == 4 || btn == 5)
			return;
		code = 0;
	} else {
		/* button press or scroll */
		if (btn < 1 || btn > 11)
			return;
		code = 0;
	}

	ox = x;
	oy = y;

	if ((!IS_SET(MODE_MOUSESGR) && (evt == NSEventTypeLeftMouseUp ||
	    evt == NSEventTypeRightMouseUp || evt == NSEventTypeOtherMouseUp)) || btn == 12)
		code += 3;
	else if (btn >= 8)
		code += 128 + btn - 8;
	else if (btn >= 4)
		code += 64 + btn - 4;
	else
		code += btn - 1;

	if (!IS_SET(MODE_MOUSEX10)) {
		code += ((state & MK_SHIFT)   ?  4 : 0)
		      + ((state & MK_OPTION)  ?  8 : 0)
		      + ((state & MK_CONTROL) ? 16 : 0);
	}

	if (IS_SET(MODE_MOUSESGR)) {
		len = snprintf(buf, sizeof(buf), "\033[<%d;%d;%d%c",
		    code, x+1, y+1,
		    (evt == NSEventTypeLeftMouseUp || evt == NSEventTypeRightMouseUp ||
		     evt == NSEventTypeOtherMouseUp) ? 'm' : 'M');
	} else if (x < 223 && y < 223) {
		len = snprintf(buf, sizeof(buf), "\033[M%c%c%c",
		    32+code, 32+x+1, 32+y+1);
	} else {
		return;
	}

	ttywrite(buf, len, 0);
}

static int
mouseaction(int btn, uint state, int release)
{
	MouseShortcut *ms;

	for (ms = mshortcuts; ms < mshortcuts + LEN(mshortcuts); ms++) {
		if (ms->release == release &&
		    ms->button == (uint)btn &&
		    (match(ms->mod, state) ||
		     match(ms->mod, state & ~forcemousemod))) {
			ms->func(&(ms->arg));
			return 1;
		}
	}
	return 0;
}

/* ---------- MTView ---------- */

@implementation MTView

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		_markedText = [[NSMutableAttributedString alloc] init];
		self.wantsLayer = YES;
		[self registerForDraggedTypes:@[NSPasteboardTypeString]];
	}
	return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];
	CGFloat newscale = self.window.backingScaleFactor;
	if (newscale != backingscale) {
		backingscale = newscale;
		self.layer.contentsScale = backingscale;
		recreatebackbuf();
		redraw();
	}
}

/* --- keyboard --- */

- (void)keyDown:(NSEvent *)event
{
	if (IS_SET(MODE_KBDLOCK))
		return;

	uint state = modflags([event modifierFlags]);
	uint16_t kc = [event keyCode];

	/* 1. shortcuts */
	for (int i = 0; i < (int)LEN(shortcuts); i++) {
		Shortcut *bp = &shortcuts[i];
		if (kc == bp->keysym && match(bp->mod, state)) {
			bp->func(&(bp->arg));
			return;
		}
	}

	/* 2. custom keys from config.h (Return, Delete, arrows, F-keys, etc.) */
	char *customkey = kmap(kc, state);
	if (customkey) {
		ttywrite(customkey, strlen(customkey), 1);
		return;
	}

	/* 3. Control+key: generate control characters */
	if ((state & MK_CONTROL) && !(state & MK_COMMAND)) {
		NSString *chars = [event charactersIgnoringModifiers];
		if ([chars length] == 1) {
			unichar ch = [chars characterAtIndex:0];
			/* Ctrl+letter -> 0x01-0x1A */
			if (ch >= 'a' && ch <= 'z') {
				char c = ch - 'a' + 1;
				if (state & MK_OPTION) {
					char buf[2] = {'\033', c};
					ttywrite(buf, 2, 1);
				} else {
					ttywrite(&c, 1, 1);
				}
				return;
			}
			if (ch >= 'A' && ch <= 'Z') {
				char c = ch - 'A' + 1;
				if (state & MK_OPTION) {
					char buf[2] = {'\033', c};
					ttywrite(buf, 2, 1);
				} else {
					ttywrite(&c, 1, 1);
				}
				return;
			}
			/* Ctrl+[ -> ESC, Ctrl+\ -> 0x1C, Ctrl+] -> 0x1D, etc. */
			if (ch >= '[' && ch <= '_') {
				char c = ch - '@';
				ttywrite(&c, 1, 1);
				return;
			}
			/* Ctrl+@ -> NUL */
			if (ch == '@' || ch == '2' || ch == ' ') {
				char c = 0;
				ttywrite(&c, 1, 1);
				return;
			}
			/* Ctrl+/ -> 0x1F */
			if (ch == '/') {
				char c = 0x1f;
				ttywrite(&c, 1, 1);
				return;
			}
		}
	}

	/* 4. Option+key: send ESC prefix for meta */
	if ((state & MK_OPTION) && !(state & MK_CONTROL) && !(state & MK_COMMAND)) {
		NSString *chars = [event charactersIgnoringModifiers];
		if ([chars length] == 1) {
			unichar ch = [chars characterAtIndex:0];
			if (ch < 0x80 && ch >= 0x20) {
				if (IS_SET(MODE_8BIT)) {
					Rune c = ch | 0x80;
					char ubuf[8];
					int len = (int)utf8encode(c, ubuf);
					ttywrite(ubuf, len, 1);
				} else {
					char buf[2] = {'\033', (char)ch};
					ttywrite(buf, 2, 1);
				}
				return;
			}
		}
	}

	/* 5. Use [event characters] for keys that interpretKeyEvents won't
	 *    deliver via insertText: (e.g. Escape, Tab) */
	NSString *chars = [event characters];
	if ([chars length] >= 1 && !(state & (MK_CONTROL | MK_OPTION | MK_COMMAND))) {
		unichar ch = [chars characterAtIndex:0];
		if (ch == 0x1B) { /* Escape */
			ttywrite("\033", 1, 1);
			return;
		}
		if (ch == 0x09) { /* Tab */
			ttywrite("\t", 1, 1);
			return;
		}
	}

	/* 6. Let input method handle it (regular text input) */
	[self interpretKeyEvents:@[event]];
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange
{
	NSString *str = ([string isKindOfClass:[NSAttributedString class]])
	    ? [string string] : string;
	const char *s = [str UTF8String];
	if (s)
		ttywrite(s, strlen(s), 1);
	[_markedText setAttributedString:[[NSMutableAttributedString alloc] init]];
}

/* NSTextInputClient */
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange
    replacementRange:(NSRange)replacementRange
{
	if ([string isKindOfClass:[NSAttributedString class]])
		[_markedText setAttributedString:string];
	else
		[_markedText setAttributedString:
		    [[NSAttributedString alloc] initWithString:string]];
}

- (void)unmarkText
{
	[_markedText setAttributedString:[[NSMutableAttributedString alloc] init]];
}

- (NSRange)selectedRange { return NSMakeRange(NSNotFound, 0); }
- (NSRange)markedRange
{
	return (_markedText.length > 0) ? NSMakeRange(0, _markedText.length)
	                                 : NSMakeRange(NSNotFound, 0);
}
- (BOOL)hasMarkedText { return _markedText.length > 0; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
    actualRange:(NSRangePointer)actualRange
{
	return nil;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText
{
	return @[];
}
- (NSRect)firstRectForCharacterRange:(NSRange)range
    actualRange:(NSRangePointer)actualRange
{
	return [self.window convertRectToScreen:
	    [self convertRect:self.bounds toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point
{
	return NSNotFound;
}

- (void)doCommandBySelector:(SEL)selector
{
	/* Ignore unhandled commands */
}

/* --- mouse --- */

- (void)mouseDown:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	int btn = BTN_LEFT;
	uint state = modflags([event modifierFlags]);

	buttons |= 1 << (btn-1);

	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), btn, (int)[event type], state);
		return;
	}

	if (mouseaction(btn, state, 0))
		return;

	/* selection */
	struct timespec now;
	int snap;
	clock_gettime(CLOCK_MONOTONIC, &now);
	if (TIMEDIFF(now, msel.tclick2) <= tripleclicktimeout) {
		snap = SNAP_LINE;
	} else if (TIMEDIFF(now, msel.tclick1) <= doubleclicktimeout) {
		snap = SNAP_WORD;
	} else {
		snap = 0;
	}
	msel.tclick2 = msel.tclick1;
	msel.tclick1 = now;

	selstart(evcol(p), evrow(p), snap);
	draw();
}

- (void)mouseUp:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	int btn = BTN_LEFT;
	uint state = modflags([event modifierFlags]);

	buttons &= ~(1 << (btn-1));

	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), btn, (int)[event type], state);
		return;
	}

	if (mouseaction(btn, state, 1))
		return;

	mousesel(p, state, 1);
	draw();
}

- (void)mouseDragged:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	uint state = modflags([event modifierFlags]);

	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), BTN_LEFT, (int)[event type], state);
		return;
	}

	mousesel(p, state, 0);
	draw();
}

- (void)rightMouseDown:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	int btn = BTN_RIGHT;
	uint state = modflags([event modifierFlags]);
	buttons |= 1 << (btn-1);

	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), btn, (int)[event type], state);
		return;
	}
	mouseaction(btn, state, 0);
}

- (void)rightMouseUp:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	int btn = BTN_RIGHT;
	uint state = modflags([event modifierFlags]);
	buttons &= ~(1 << (btn-1));

	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), btn, (int)[event type], state);
		return;
	}
	mouseaction(btn, state, 1);
}

- (void)otherMouseDown:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	int btn = BTN_MIDDLE;
	uint state = modflags([event modifierFlags]);
	buttons |= 1 << (btn-1);

	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), btn, (int)[event type], state);
		return;
	}
	mouseaction(btn, state, 0);
}

- (void)otherMouseUp:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	int btn = BTN_MIDDLE;
	uint state = modflags([event modifierFlags]);
	buttons &= ~(1 << (btn-1));

	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), btn, (int)[event type], state);
		return;
	}
	mouseaction(btn, state, 1);
}

- (void)scrollWheel:(NSEvent *)event
{
	static CGFloat accumY = 0.0;
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	uint state = modflags([event modifierFlags]);

	CGFloat dy = [event scrollingDeltaY];
	if (dy == 0)
		return;

	int lines;
	if ([event hasPreciseScrollingDeltas]) {
		/* Trackpad: accumulate pixel deltas, fire per line height */
		accumY += dy;
		lines = (int)(accumY / win.ch);
		if (lines == 0)
			return;
		accumY -= lines * win.ch;
	} else {
		/* Discrete mouse wheel: use delta directly */
		lines = (int)dy;
		if (lines == 0)
			lines = (dy > 0) ? 1 : -1;
	}

	int btn = (lines > 0) ? BTN_SCROLLUP : BTN_SCROLLDOWN;
	int count = abs(lines);

	for (int n = 0; n < count; n++) {
		if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
			mousereport(evcol(p), evrow(p), btn,
			    (int)NSEventTypeLeftMouseDown, state);
			continue;
		}

		/* Check mouse shortcuts for scroll */
		for (int i = 0; i < (int)LEN(mshortcuts); i++) {
			MouseShortcut *ms = &mshortcuts[i];
			if (ms->button == (uint)btn &&
			    (match(ms->mod, state) ||
			     match(ms->mod, state & ~forcemousemod))) {
				ms->func(&(ms->arg));
				break;
			}
		}
	}
}

- (void)otherMouseDragged:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	uint state = modflags([event modifierFlags]);
	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), BTN_MIDDLE, (int)[event type], state);
	}
}

- (void)rightMouseDragged:(NSEvent *)event
{
	NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
	uint state = modflags([event modifierFlags]);
	if (IS_SET(MODE_MOUSE) && !(state & forcemousemod)) {
		mousereport(evcol(p), evrow(p), BTN_RIGHT, (int)[event type], state);
	}
}

@end

/* ---------- App Delegate ---------- */

@interface MTAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation MTAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	/* When launched from Finder/Spotlight, cwd is / — fix it */
	const char *home = getenv("HOME");
	if (home)
		chdir(home);

	/* TTY is set up after window is visible */
	ttyfd = ttynew(opt_line, shell, opt_io, opt_cmd);
	cresize(win.w, win.h);

	/* Monitor PTY fd for data */
	ttysrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
	    ttyfd, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler(ttysrc, ^{
		ttyread();
		schedule_draw();
	});
	dispatch_source_set_cancel_handler(ttysrc, ^{
		ttyhangup();
		exit(0);
	});
	dispatch_resume(ttysrc);

	setup_blink_timer();

	/* initial draw */
	draw();
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	ttyhangup();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return YES;
}

- (void)newWindow:(id)sender
{
	@autoreleasepool {
		NSString *exe = [[NSBundle mainBundle] executablePath];
		[NSTask launchedTaskWithLaunchPath:exe arguments:@[]];
	}
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender
{
	NSMenu *menu = [[NSMenu alloc] init];
	[menu addItemWithTitle:@"New Window"
	    action:@selector(newWindow:) keyEquivalent:@""];
	return menu;
}

/* NSWindowDelegate */
- (void)windowDidResize:(NSNotification *)notification
{
	NSRect frame = [[macwin contentView] frame];
	int w = (int)frame.size.width;
	int h = (int)frame.size.height;
	if (w == win.w && h == win.h)
		return;
	cresize(w, h);
	schedule_draw();
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
	win.mode |= MODE_FOCUSED;
	if (IS_SET(MODE_FOCUS))
		ttywrite("\033[I", 3, 0);
	draw();
}

- (void)windowDidResignKey:(NSNotification *)notification
{
	win.mode &= ~MODE_FOCUSED;
	if (IS_SET(MODE_FOCUS))
		ttywrite("\033[O", 3, 0);
	draw();
}

- (void)windowWillClose:(NSNotification *)notification
{
	ttyhangup();
}

@end

/* ---------- macinit ---------- */

void
macinit(int cols_init, int rows_init)
{
	@autoreleasepool {
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

		/* font + colors */
		usedfont = (opt_font == NULL) ? font : opt_font;
		xloadfonts(usedfont, 0);
		xloadcols();

		win.w = 2 * borderpx + cols_init * win.cw;
		win.h = 2 * borderpx + rows_init * win.ch;

		NSRect frame = NSMakeRect(100, 100, win.w, win.h);
		macwin = [[NSWindow alloc] initWithContentRect:frame
		    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
		               NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
		    backing:NSBackingStoreBuffered defer:NO];

		[macwin setTitle:[NSString stringWithUTF8String:opt_title]];
		[macwin setContentResizeIncrements:NSMakeSize(win.cw, win.ch)];
		[macwin setContentMinSize:NSMakeSize(win.cw + 2*borderpx,
		                                     win.ch + 2*borderpx)];

		backingscale = [macwin backingScaleFactor];

		mtview = [[MTView alloc] initWithFrame:
		    NSMakeRect(0, 0, win.w, win.h)];
		mtview.layer.contentsScale = backingscale;
		[macwin setContentView:mtview];
		[macwin makeFirstResponder:mtview];

		MTAppDelegate *delegate = [[MTAppDelegate alloc] init];
		[NSApp setDelegate:delegate];
		[macwin setDelegate:delegate];

		recreatebackbuf();
		specbuf = xmalloc(cols_init * sizeof(GlyphFontSpec));

		win.mode = MODE_NUMLOCK;
		win.mode |= MODE_VISIBLE | MODE_FOCUSED;

		/* App menu */
		NSMenu *menubar = [[NSMenu alloc] init];
		NSMenuItem *appItem = [[NSMenuItem alloc] init];
		[menubar addItem:appItem];
		NSMenu *appMenu = [[NSMenu alloc] init];
		[appMenu addItemWithTitle:@"Quit mt"
		    action:@selector(terminate:)
		    keyEquivalent:@"q"];
		[appItem setSubmenu:appMenu];

		NSMenuItem *shellItem = [[NSMenuItem alloc] init];
		[menubar addItem:shellItem];
		NSMenu *shellMenu = [[NSMenu alloc] initWithTitle:@"Shell"];
		[shellMenu addItemWithTitle:@"New Window"
		    action:@selector(newWindow:) keyEquivalent:@"n"];
		[shellItem setSubmenu:shellMenu];

		NSMenuItem *editItem = [[NSMenuItem alloc] init];
		[menubar addItem:editItem];
		NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
		[editMenu addItemWithTitle:@"Copy"
		    action:@selector(copy:) keyEquivalent:@"c"];
		[editMenu addItemWithTitle:@"Paste"
		    action:@selector(paste:) keyEquivalent:@"v"];
		[editItem setSubmenu:editMenu];

		[NSApp setMainMenu:menubar];

		[macwin makeKeyAndOrderFront:nil];
		[NSApp activateIgnoringOtherApps:YES];

		clock_gettime(CLOCK_MONOTONIC, &msel.tclick1);
		clock_gettime(CLOCK_MONOTONIC, &msel.tclick2);
		msel.primary = NULL;
		msel.clipboard = NULL;
	}
}

/* ---------- usage / main ---------- */

void
usage(void)
{
	die("usage: %s [-aiv] [-f font] [-o file]\n"
	    "          [-T title] [-t title]"
	    " [[-e] command [args ...]]\n"
	    "       %s [-aiv] [-f font] [-o file]\n"
	    "          [-T title] [-t title] -l line"
	    " [stty_args ...]\n", argv0, argv0);
}

int
main(int argc, char *argv[])
{
	xsetcursor(cursorshape);

	ARGBEGIN {
	case 'a':
		allowaltscreen = 0;
		break;
	case 'e':
		if (argc > 0)
			--argc, ++argv;
		goto run;
	case 'f':
		opt_font = EARGF(usage());
		break;
	case 'i':
		/* fixed geometry - ignored on macOS */
		break;
	case 'o':
		opt_io = EARGF(usage());
		break;
	case 'l':
		opt_line = EARGF(usage());
		break;
	case 't':
	case 'T':
		opt_title = EARGF(usage());
		break;
	case 'v':
		die("%s " VERSION "\n", argv0);
		break;
	default:
		usage();
	} ARGEND;

run:
	if (argc > 0) /* eat all remaining arguments */
		opt_cmd = argv;

	/* Default to login shell so .profile/.zprofile are sourced */
	static char *logincmd[3];
	if (!opt_cmd && !opt_line) {
		const char *sh = getenv("SHELL");
		if (!sh) sh = shell;
		logincmd[0] = (char *)sh;
		logincmd[1] = "-l";
		logincmd[2] = NULL;
		opt_cmd = logincmd;
	}

	if (!opt_title)
		opt_title = (opt_line || !opt_cmd) ? "mt" : opt_cmd[0];

	setlocale(LC_CTYPE, "");
	cols = MAX(cols, 1);
	rows = MAX(rows, 1);
	tnew(cols, rows);
	selinit();
	macinit(cols, rows);

	/* Run the Cocoa event loop */
	[NSApp run];

	return 0;
}
