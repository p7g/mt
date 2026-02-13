/* See LICENSE file for copyright and license details. */

/*
 * appearance
 *
 * font: use Core Text font name format
 */
static char *font = "Menlo:size=12";
static int borderpx = 2;

/*
 * What program is execed by mt depends of these precedence rules:
 * 1: program passed with -e
 * 2: scroll and/or utmp
 * 3: SHELL environment variable
 * 4: value of shell in /etc/passwd
 * 5: value of shell in config.h
 */
static char *shell = "/bin/sh";
char *utmp = NULL;
/* scroll program: to enable use a string like "scroll" */
char *scroll = NULL;
char *stty_args = "stty raw pass8 nl -echo -iexten -cstopb 38400";

/* identification sequence returned in DA and DECID */
char *vtiden = "\033[?6c";

/* Kerning / character bounding-box multipliers */
static float cwscale = 1.0;
static float chscale = 1.0;

/*
 * word delimiter string
 *
 * More advanced example: L" `'\"()[]{}"
 */
wchar_t *worddelimiters = L" ";

/* selection timeouts (in milliseconds) */
static unsigned int doubleclicktimeout = 300;
static unsigned int tripleclicktimeout = 600;

/* alt screens */
int allowaltscreen = 1;

/* allow certain non-interactive (insecure) window operations such as:
   setting the clipboard text */
int allowwindowops = 0;

/*
 * draw latency range in ms - from new content/keypress/etc until drawing.
 * within this range, mt draws when content stops arriving (idle). mostly it's
 * near minlatency, but it waits longer for slow updates to avoid partial draw.
 * low minlatency will tear/flicker more, as it can "detect" idle too early.
 */
static double minlatency = 2;
static double maxlatency = 33;

/*
 * blinking timeout (set to 0 to disable blinking) for the terminal blinking
 * attribute.
 */
static unsigned int blinktimeout = 800;

/*
 * thickness of underline and bar cursors
 */
static unsigned int cursorthickness = 2;

/*
 * bell volume. It must be a value between -100 and 100. Use 0 for disabling
 * it
 */
static int bellvolume = 0;

/* default TERM value */
char *termname = "st-256color";

/*
 * spaces per tab
 *
 * When you are changing this value, don't forget to adapt the >>it<< value in
 * the st.info and appropriately install the st.info in the environment where
 * you use this st version.
 *
 *	it#$tabspaces,
 *
 * Secondly make sure your kernel is not expanding tabs. When running `stty
 * -a` >>tab0<< should appear. You can tell the terminal to not expand tabs by
 *  running following command:
 *
 *	stty tabs
 */
unsigned int tabspaces = 8;

/* Terminal colors (16 first used in escape sequence) */
static const char *colorname[] = {
	/* 8 normal colors */
	"#000000", /* black   */
	"#cd0000", /* red3    */
	"#00cd00", /* green3  */
	"#cdcd00", /* yellow3 */
	"#0000ee", /* blue2   */
	"#cd00cd", /* magenta3*/
	"#00cdcd", /* cyan3   */
	"#e5e5e5", /* gray90  */

	/* 8 bright colors */
	"#7f7f7f", /* gray50  */
	"#ff0000", /* red     */
	"#00ff00", /* green   */
	"#ffff00", /* yellow  */
	"#5c5cff",
	"#ff00ff", /* magenta */
	"#00ffff", /* cyan    */
	"#ffffff", /* white   */

	[255] = 0,

	/* more colors can be added after 255 to use with DefaultXX */
	"#cccccc",
	"#555555",
	"#e5e5e5", /* default foreground colour */
	"#000000", /* default background colour */
};


/*
 * Default colors (colorname index)
 * foreground, background, cursor, reverse cursor
 */
unsigned int defaultfg = 258;
unsigned int defaultbg = 259;
unsigned int defaultcs = 256;
static unsigned int defaultrcs = 257;

/*
 * Default shape of cursor
 * 2: Block
 * 4: Underline ("_")
 * 6: Bar ("|")
 * 7: Snowman
 */
static unsigned int cursorshape = 2;

/*
 * Default columns and rows numbers
 */

static unsigned int cols = 80;
static unsigned int rows = 24;

/*
 * Color used to display font attributes when fontconfig selected a font which
 * doesn't match the ones requested.
 */
static unsigned int defaultattr = 11;

/*
 * Force mouse select/shortcuts while mask is active (when MODE_MOUSE is set).
 * Note that if you want to use MK_SHIFT with selmasks, set this to an other
 * modifier, set to 0 to not use it.
 */
static uint forcemousemod = MK_SHIFT;

/*
 * Internal mouse shortcuts.
 * Beware that overloading BTN_LEFT will disable the selection.
 */
static MouseShortcut mshortcuts[] = {
	/* mask                 button         function        argument       release */
	{ MK_ANY,               BTN_MIDDLE,    selpaste,       {.i = 0},      1 },
	{ MK_SHIFT,             BTN_SCROLLUP,  ttysend,        {.s = "\033[5;2~"} },
	{ MK_ANY,               BTN_SCROLLUP,  ttysend,        {.s = "\031"} },
	{ MK_SHIFT,             BTN_SCROLLDOWN,ttysend,        {.s = "\033[6;2~"} },
	{ MK_ANY,               BTN_SCROLLDOWN,ttysend,        {.s = "\005"} },
};

/* Internal keyboard shortcuts. */
#define MODKEY MK_OPTION
#define TERMMOD (MK_CONTROL|MK_SHIFT)

static Shortcut shortcuts[] = {
	/* mask                 keysym                function      argument */
	{ MK_COMMAND,           kVK_ANSI_C,           clipcopy,     {.i =  0} },
	{ MK_COMMAND,           kVK_ANSI_V,           clippaste,    {.i =  0} },
	{ MK_COMMAND,           kVK_ANSI_Equal,       zoom,         {.f = +1} },
	{ MK_COMMAND,           kVK_ANSI_Minus,       zoom,         {.f = -1} },
	{ MK_COMMAND,           kVK_ANSI_0,           zoomreset,    {.f =  0} },
	{ TERMMOD,              kVK_ANSI_Y,           selpaste,     {.i =  0} },
	{ MK_SHIFT,             kVK_Help,             selpaste,     {.i =  0} },
	{ TERMMOD,              kVK_ANSI_KeypadClear, numlock,      {.i =  0} },
};

/*
 * Special keys (change & recompile st.info accordingly)
 *
 * Mask value:
 * * Use MK_ANY to match the key no matter modifiers state
 * * Use MK_NONE to match the key alone (no modifiers)
 * appkey value:
 * * 0: no value
 * * > 0: keypad application mode enabled
 * *   = 2: term.numlock = 1
 * * < 0: keypad application mode disabled
 * appcursor value:
 * * 0: no value
 * * > 0: cursor application mode enabled
 * * < 0: cursor application mode disabled
 *
 * Be careful with the order of the definitions because mt searches in
 * this table sequentially, so any MK_ANY must be in the last
 * position for a key.
 */

/*
 * State bits to ignore when matching key or button events.
 */
static uint ignoremod = 0;

/*
 * This is the huge key array which defines all compatibility to the Linux
 * world. Please decide about changes wisely.
 */
static Key key[] = {
	/* keysym              mask             string      appkey appcursor */
	{ kVK_ANSI_KeypadClear, MK_SHIFT,      "\033[2J",       0,   -1},
	{ kVK_ANSI_KeypadClear, MK_SHIFT,      "\033[1;2H",     0,   +1},
	{ kVK_ANSI_KeypadClear, MK_ANY,        "\033[H",        0,   -1},
	{ kVK_ANSI_KeypadClear, MK_ANY,        "\033[1~",       0,   +1},
	{ kVK_UpArrow,         MK_SHIFT,       "\033[1;2A",     0,    0},
	{ kVK_UpArrow,         MK_OPTION,      "\033[1;3A",     0,    0},
	{ kVK_UpArrow,    MK_SHIFT|MK_OPTION,  "\033[1;4A",     0,    0},
	{ kVK_UpArrow,         MK_CONTROL,     "\033[1;5A",     0,    0},
	{ kVK_UpArrow,  MK_SHIFT|MK_CONTROL,   "\033[1;6A",     0,    0},
	{ kVK_UpArrow,  MK_CONTROL|MK_OPTION,  "\033[1;7A",     0,    0},
	{ kVK_UpArrow,MK_SHIFT|MK_CONTROL|MK_OPTION,"\033[1;8A",0,    0},
	{ kVK_UpArrow,         MK_ANY,         "\033[A",        0,   -1},
	{ kVK_UpArrow,         MK_ANY,         "\033OA",        0,   +1},
	{ kVK_DownArrow,       MK_SHIFT,       "\033[1;2B",     0,    0},
	{ kVK_DownArrow,       MK_OPTION,      "\033[1;3B",     0,    0},
	{ kVK_DownArrow,  MK_SHIFT|MK_OPTION,  "\033[1;4B",     0,    0},
	{ kVK_DownArrow,       MK_CONTROL,     "\033[1;5B",     0,    0},
	{ kVK_DownArrow,MK_SHIFT|MK_CONTROL,   "\033[1;6B",     0,    0},
	{ kVK_DownArrow,MK_CONTROL|MK_OPTION,  "\033[1;7B",     0,    0},
	{ kVK_DownArrow,MK_SHIFT|MK_CONTROL|MK_OPTION,"\033[1;8B",0,  0},
	{ kVK_DownArrow,       MK_ANY,         "\033[B",        0,   -1},
	{ kVK_DownArrow,       MK_ANY,         "\033OB",        0,   +1},
	{ kVK_LeftArrow,       MK_SHIFT,       "\033[1;2D",     0,    0},
	{ kVK_LeftArrow,       MK_OPTION,      "\033[1;3D",     0,    0},
	{ kVK_LeftArrow,  MK_SHIFT|MK_OPTION,  "\033[1;4D",     0,    0},
	{ kVK_LeftArrow,       MK_CONTROL,     "\033[1;5D",     0,    0},
	{ kVK_LeftArrow,MK_SHIFT|MK_CONTROL,   "\033[1;6D",     0,    0},
	{ kVK_LeftArrow,MK_CONTROL|MK_OPTION,  "\033[1;7D",     0,    0},
	{ kVK_LeftArrow,MK_SHIFT|MK_CONTROL|MK_OPTION,"\033[1;8D",0,  0},
	{ kVK_LeftArrow,       MK_ANY,         "\033[D",        0,   -1},
	{ kVK_LeftArrow,       MK_ANY,         "\033OD",        0,   +1},
	{ kVK_RightArrow,      MK_SHIFT,       "\033[1;2C",     0,    0},
	{ kVK_RightArrow,      MK_OPTION,      "\033[1;3C",     0,    0},
	{ kVK_RightArrow, MK_SHIFT|MK_OPTION,  "\033[1;4C",     0,    0},
	{ kVK_RightArrow,      MK_CONTROL,     "\033[1;5C",     0,    0},
	{ kVK_RightArrow,MK_SHIFT|MK_CONTROL,  "\033[1;6C",     0,    0},
	{ kVK_RightArrow,MK_CONTROL|MK_OPTION, "\033[1;7C",     0,    0},
	{ kVK_RightArrow,MK_SHIFT|MK_CONTROL|MK_OPTION,"\033[1;8C",0, 0},
	{ kVK_RightArrow,      MK_ANY,         "\033[C",        0,   -1},
	{ kVK_RightArrow,      MK_ANY,         "\033OC",        0,   +1},
	{ kVK_Escape,          MK_ANY,         "\033",          0,    0},
	{ kVK_Tab,             MK_SHIFT,       "\033[Z",        0,    0},
	{ kVK_Tab,             MK_ANY,         "\t",            0,    0},
	{ kVK_Return,          MK_OPTION,      "\033\r",        0,    0},
	{ kVK_Return,          MK_ANY,         "\r",            0,    0},
	{ kVK_Help,            MK_SHIFT,       "\033[4l",      -1,    0},
	{ kVK_Help,            MK_SHIFT,       "\033[2;2~",    +1,    0},
	{ kVK_Help,            MK_CONTROL,     "\033[L",       -1,    0},
	{ kVK_Help,            MK_CONTROL,     "\033[2;5~",    +1,    0},
	{ kVK_Help,            MK_ANY,         "\033[4h",      -1,    0},
	{ kVK_Help,            MK_ANY,         "\033[2~",      +1,    0},
	{ kVK_ForwardDelete,   MK_CONTROL,     "\033[M",       -1,    0},
	{ kVK_ForwardDelete,   MK_CONTROL,     "\033[3;5~",    +1,    0},
	{ kVK_ForwardDelete,   MK_SHIFT,       "\033[2K",      -1,    0},
	{ kVK_ForwardDelete,   MK_SHIFT,       "\033[3;2~",    +1,    0},
	{ kVK_ForwardDelete,   MK_ANY,         "\033[P",       -1,    0},
	{ kVK_ForwardDelete,   MK_ANY,         "\033[3~",      +1,    0},
	{ kVK_Delete,          MK_NONE,        "\177",          0,    0},
	{ kVK_Delete,          MK_OPTION,      "\033\177",      0,    0},
	{ kVK_Home,            MK_SHIFT,       "\033[2J",       0,   -1},
	{ kVK_Home,            MK_SHIFT,       "\033[1;2H",     0,   +1},
	{ kVK_Home,            MK_ANY,         "\033[H",        0,   -1},
	{ kVK_Home,            MK_ANY,         "\033[1~",       0,   +1},
	{ kVK_End,             MK_CONTROL,     "\033[J",       -1,    0},
	{ kVK_End,             MK_CONTROL,     "\033[1;5F",    +1,    0},
	{ kVK_End,             MK_SHIFT,       "\033[K",       -1,    0},
	{ kVK_End,             MK_SHIFT,       "\033[1;2F",    +1,    0},
	{ kVK_End,             MK_ANY,         "\033[4~",       0,    0},
	{ kVK_PageUp,          MK_CONTROL,     "\033[5;5~",     0,    0},
	{ kVK_PageUp,          MK_SHIFT,       "\033[5;2~",     0,    0},
	{ kVK_PageUp,          MK_ANY,         "\033[5~",       0,    0},
	{ kVK_PageDown,        MK_CONTROL,     "\033[6;5~",     0,    0},
	{ kVK_PageDown,        MK_SHIFT,       "\033[6;2~",     0,    0},
	{ kVK_PageDown,        MK_ANY,         "\033[6~",       0,    0},
	{ kVK_F1,              MK_NONE,        "\033OP" ,       0,    0},
	{ kVK_F1, /* F13 */    MK_SHIFT,       "\033[1;2P",     0,    0},
	{ kVK_F1, /* F25 */    MK_CONTROL,     "\033[1;5P",     0,    0},
	{ kVK_F1, /* F49 */    MK_OPTION,      "\033[1;3P",     0,    0},
	{ kVK_F2,              MK_NONE,        "\033OQ" ,       0,    0},
	{ kVK_F2, /* F14 */    MK_SHIFT,       "\033[1;2Q",     0,    0},
	{ kVK_F2, /* F26 */    MK_CONTROL,     "\033[1;5Q",     0,    0},
	{ kVK_F2, /* F50 */    MK_OPTION,      "\033[1;3Q",     0,    0},
	{ kVK_F3,              MK_NONE,        "\033OR" ,       0,    0},
	{ kVK_F3, /* F15 */    MK_SHIFT,       "\033[1;2R",     0,    0},
	{ kVK_F3, /* F27 */    MK_CONTROL,     "\033[1;5R",     0,    0},
	{ kVK_F3, /* F51 */    MK_OPTION,      "\033[1;3R",     0,    0},
	{ kVK_F4,              MK_NONE,        "\033OS" ,       0,    0},
	{ kVK_F4, /* F16 */    MK_SHIFT,       "\033[1;2S",     0,    0},
	{ kVK_F4, /* F28 */    MK_CONTROL,     "\033[1;5S",     0,    0},
	{ kVK_F4, /* F52 */    MK_OPTION,      "\033[1;3S",     0,    0},
	{ kVK_F5,              MK_NONE,        "\033[15~",      0,    0},
	{ kVK_F5, /* F17 */    MK_SHIFT,       "\033[15;2~",    0,    0},
	{ kVK_F5, /* F29 */    MK_CONTROL,     "\033[15;5~",    0,    0},
	{ kVK_F5, /* F53 */    MK_OPTION,      "\033[15;3~",    0,    0},
	{ kVK_F6,              MK_NONE,        "\033[17~",      0,    0},
	{ kVK_F6, /* F18 */    MK_SHIFT,       "\033[17;2~",    0,    0},
	{ kVK_F6, /* F30 */    MK_CONTROL,     "\033[17;5~",    0,    0},
	{ kVK_F6, /* F54 */    MK_OPTION,      "\033[17;3~",    0,    0},
	{ kVK_F7,              MK_NONE,        "\033[18~",      0,    0},
	{ kVK_F7, /* F19 */    MK_SHIFT,       "\033[18;2~",    0,    0},
	{ kVK_F7, /* F31 */    MK_CONTROL,     "\033[18;5~",    0,    0},
	{ kVK_F7, /* F55 */    MK_OPTION,      "\033[18;3~",    0,    0},
	{ kVK_F8,              MK_NONE,        "\033[19~",      0,    0},
	{ kVK_F8, /* F20 */    MK_SHIFT,       "\033[19;2~",    0,    0},
	{ kVK_F8, /* F32 */    MK_CONTROL,     "\033[19;5~",    0,    0},
	{ kVK_F8, /* F56 */    MK_OPTION,      "\033[19;3~",    0,    0},
	{ kVK_F9,              MK_NONE,        "\033[20~",      0,    0},
	{ kVK_F9, /* F21 */    MK_SHIFT,       "\033[20;2~",    0,    0},
	{ kVK_F9, /* F33 */    MK_CONTROL,     "\033[20;5~",    0,    0},
	{ kVK_F9, /* F57 */    MK_OPTION,      "\033[20;3~",    0,    0},
	{ kVK_F10,             MK_NONE,        "\033[21~",      0,    0},
	{ kVK_F10, /* F22 */   MK_SHIFT,       "\033[21;2~",    0,    0},
	{ kVK_F10, /* F34 */   MK_CONTROL,     "\033[21;5~",    0,    0},
	{ kVK_F10, /* F58 */   MK_OPTION,      "\033[21;3~",    0,    0},
	{ kVK_F11,             MK_NONE,        "\033[23~",      0,    0},
	{ kVK_F11, /* F23 */   MK_SHIFT,       "\033[23;2~",    0,    0},
	{ kVK_F11, /* F35 */   MK_CONTROL,     "\033[23;5~",    0,    0},
	{ kVK_F11, /* F59 */   MK_OPTION,      "\033[23;3~",    0,    0},
	{ kVK_F12,             MK_NONE,        "\033[24~",      0,    0},
	{ kVK_F12, /* F24 */   MK_SHIFT,       "\033[24;2~",    0,    0},
	{ kVK_F12, /* F36 */   MK_CONTROL,     "\033[24;5~",    0,    0},
	{ kVK_F12, /* F60 */   MK_OPTION,      "\033[24;3~",    0,    0},
	{ kVK_F13,             MK_NONE,        "\033[1;2P",     0,    0},
	{ kVK_F14,             MK_NONE,        "\033[1;2Q",     0,    0},
	{ kVK_F15,             MK_NONE,        "\033[1;2R",     0,    0},
	{ kVK_F16,             MK_NONE,        "\033[1;2S",     0,    0},
	{ kVK_F17,             MK_NONE,        "\033[15;2~",    0,    0},
	{ kVK_F18,             MK_NONE,        "\033[17;2~",    0,    0},
	{ kVK_F19,             MK_NONE,        "\033[18;2~",    0,    0},
	{ kVK_F20,             MK_NONE,        "\033[19;2~",    0,    0},
};

/*
 * Selection types' masks.
 * Use the same masks as usual.
 * If no match is found, regular selection is used.
 */
static uint selmasks[] = {
	[SEL_RECTANGULAR] = MK_OPTION,
};

/*
 * Printable characters in ASCII, used to estimate the advance width
 * of single wide characters.
 */
static char ascii_printable[] =
	" !\"#$%&'()*+,-./0123456789:;<=>?"
	"@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_"
	"`abcdefghijklmnopqrstuvwxyz{|}~";
