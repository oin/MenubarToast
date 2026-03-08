#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <signal.h>
#import <mach-o/dyld.h>

// =============================================================================
// Constants
// =============================================================================

static const NSTimeInterval kFallbackDuration   = 2.0;
static const NSTimeInterval kFadeDuration       = 0.3;
static const CGFloat        kScrollSpeed        = 50.0;   // points/sec
static const NSTimeInterval kScrollPause        = 1.0;    // pause at each end
static const NSTimeInterval kScrollPauseStart   = 0.3;    // pause before first scroll
static const CGFloat        kHorizontalPadding  = 12.0;
static const CGFloat        kLeftFadeWidth      = 30.0;
static const NSTimeInterval kMousePollInterval  = 0.1 ;

// =============================================================================
// Globals
// =============================================================================

static char gSocketPath[256];

static NSTimeInterval getDefaultDuration(void) {
    double val = [[NSUserDefaults standardUserDefaults] doubleForKey:@"duration"];
    return val > 0 ? val : kFallbackDuration;
}

// =============================================================================
// Cleanup
// =============================================================================

static void cleanupSocket(void) {
    unlink(gSocketPath);
}

static void signalHandler(int sig) {
    unlink(gSocketPath);
    _exit(sig);
}

// =============================================================================
// Menu bar appearance detection
// =============================================================================

static CGFloat getStatusAreaLeftEdge(void) {
    // Enumerate on-screen windows to find status item windows (level 25)
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenFrame = screen.frame;
    CGFloat menuBarHeight = NSMaxY(screenFrame) - NSMaxY(screen.visibleFrame);
    if (menuBarHeight < 22) menuBarHeight = 24;

    CFArrayRef windowList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);

    CGFloat leftMostX = NSMaxX(screenFrame);
    BOOL found = NO;
    pid_t myPID = getpid();

    if (windowList) {
        CFIndex count = CFArrayGetCount(windowList);
        for (CFIndex i = 0; i < count; i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);

            NSNumber *ownerPID = info[(__bridge NSString *)kCGWindowOwnerPID];
            if (ownerPID && [ownerPID intValue] == myPID) continue;

            NSInteger level = [info[(__bridge NSString *)kCGWindowLayer] integerValue];
            if (level != 25) continue;

            NSDictionary *boundsDict = info[(__bridge NSString *)kCGWindowBounds];
            if (!boundsDict) continue;

            CGRect bounds;
            if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &bounds))
                continue;

            // Must be at top of screen (CG coords: Y=0 at top)
            if (bounds.origin.y > menuBarHeight) continue;
            // Must be approximately menu bar height
            if (bounds.size.height > menuBarHeight + 5) continue;

            if (bounds.origin.x < leftMostX) {
                leftMostX = bounds.origin.x;
                found = YES;
            }
        }
        CFRelease(windowList);
    }

    return found ? leftMostX : 0;
}

static BOOL isMenuBarDark(void) {
    // Create a temporary status item to probe the menu bar's effective appearance
    NSStatusItem *probe = [[NSStatusBar systemStatusBar] statusItemWithLength:0];
    NSAppearanceName match = [probe.button.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    [[NSStatusBar systemStatusBar] removeStatusItem:probe];
    return [match isEqualToString:NSAppearanceNameDarkAqua];
}

// =============================================================================
// Color resolver
// =============================================================================

static NSColor *colorFromString(NSString *str) {
    if ([str hasPrefix:@"#"]) {
        unsigned int hex = 0;
        NSString *hexStr = [str substringFromIndex:1];
        [[NSScanner scannerWithString:hexStr] scanHexInt:&hex];
        if (hexStr.length == 6) {
            return [NSColor colorWithSRGBRed:((hex >> 16) & 0xFF) / 255.0
                                       green:((hex >> 8) & 0xFF) / 255.0
                                        blue:(hex & 0xFF) / 255.0
                                       alpha:1.0];
        } else if (hexStr.length == 8) {
            return [NSColor colorWithSRGBRed:((hex >> 24) & 0xFF) / 255.0
                                       green:((hex >> 16) & 0xFF) / 255.0
                                        blue:((hex >> 8) & 0xFF) / 255.0
                                       alpha:(hex & 0xFF) / 255.0];
        }
    }

    static NSDictionary<NSString *, NSColor *> *namedColors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        namedColors = @{
            @"red":     [NSColor systemRedColor],
            @"green":   [NSColor systemGreenColor],
            @"blue":    [NSColor systemBlueColor],
            @"orange":  [NSColor systemOrangeColor],
            @"yellow":  [NSColor systemYellowColor],
            @"purple":  [NSColor systemPurpleColor],
            @"pink":    [NSColor systemPinkColor],
            @"white":   [NSColor whiteColor],
            @"black":   [NSColor blackColor],
            @"gray":    [NSColor systemGrayColor],
            @"cyan":    [NSColor cyanColor],
            @"magenta": [NSColor magentaColor],
        };
    });

    NSColor *color = namedColors[[str lowercaseString]];
    return color ?: [NSColor labelColor];
}

// =============================================================================
// Markup parser
// =============================================================================

static NSAttributedString *parseMarkup(NSString *input, NSFont *baseFont, NSColor *baseColor) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    NSFont *boldFont = [[NSFontManager sharedFontManager] convertFont:baseFont
                                                          toHaveTrait:NSBoldFontMask];
    NSUInteger len = input.length;
    NSUInteger i = 0;
    BOOL isBold = NO;
    NSColor *currentColor = baseColor;
    NSMutableArray<NSColor *> *colorStack = [NSMutableArray array];

    while (i < len) {
        unichar c = [input characterAtIndex:i];

        // ** bold toggle **
        if (c == '*' && i + 1 < len && [input characterAtIndex:i + 1] == '*') {
            isBold = !isBold;
            i += 2;
            continue;
        }

        // {color:NAME} or {/color} or {icon:NAME}
        if (c == '{') {
            NSString *remaining = [input substringFromIndex:i];

            if ([remaining hasPrefix:@"{color:"]) {
                NSRange closeBrace = [remaining rangeOfString:@"}"];
                if (closeBrace.location != NSNotFound) {
                    NSString *colorName = [remaining substringWithRange:
                        NSMakeRange(7, closeBrace.location - 7)];
                    [colorStack addObject:currentColor];
                    currentColor = colorFromString(colorName);
                    i += closeBrace.location + 1;
                    continue;
                }
            }

            if ([remaining hasPrefix:@"{/color}"]) {
                currentColor = colorStack.count > 0 ? colorStack.lastObject : baseColor;
                if (colorStack.count > 0) [colorStack removeLastObject];
                i += 8;
                continue;
            }

            if ([remaining hasPrefix:@"{icon:"]) {
                NSRange closeBrace = [remaining rangeOfString:@"}"];
                if (closeBrace.location != NSNotFound) {
                    NSString *iconName = [remaining substringWithRange:
                        NSMakeRange(6, closeBrace.location - 6)];
                    NSImage *image = [NSImage imageWithSystemSymbolName:iconName
                                            accessibilityDescription:iconName];
                    if (image) {
                        CGFloat fontSize = baseFont.pointSize;
                        NSImageSymbolConfiguration *sizeConfig =
                            [NSImageSymbolConfiguration configurationWithPointSize:fontSize
                                                                           weight:NSFontWeightRegular];
                        NSImageSymbolConfiguration *colorConfig =
                            [NSImageSymbolConfiguration configurationWithHierarchicalColor:currentColor];
                        NSImageSymbolConfiguration *config =
                            [sizeConfig configurationByApplyingConfiguration:colorConfig];
                        image = [image imageWithSymbolConfiguration:config];

                        NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
                        attachment.image = image;
                        CGFloat ratio = image.size.width / image.size.height;
                        CGFloat height = fontSize;
                        CGFloat width = height * ratio;
                        attachment.bounds = CGRectMake(0, baseFont.descender, width, height);

                        NSAttributedString *iconStr =
                            [NSAttributedString attributedStringWithAttachment:attachment];
                        [result appendAttributedString:iconStr];
                    }
                    i += closeBrace.location + 1;
                    continue;
                }
            }
        }

        // Regular text — scan until next special token
        NSUInteger start = i;
        while (i < len) {
            unichar ch = [input characterAtIndex:i];
            if (ch == '{') break;
            if (ch == '*' && i + 1 < len && [input characterAtIndex:i + 1] == '*') break;
            i++;
        }

        if (i > start) {
            NSString *text = [input substringWithRange:NSMakeRange(start, i - start)];
            NSDictionary *attrs = @{
                NSFontAttributeName:            isBold ? boldFont : baseFont,
                NSForegroundColorAttributeName:  currentColor,
            };
            [result appendAttributedString:
                [[NSAttributedString alloc] initWithString:text attributes:attrs]];
        }
    }

    return result;
}

// =============================================================================
// ToastWindow (NSPanel subclass — non-activating, non-key)
// =============================================================================

@interface ToastWindow : NSPanel
@end

@implementation ToastWindow
- (BOOL)canBecomeKeyWindow  { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

// =============================================================================
// Scroll state
// =============================================================================

typedef NS_ENUM(NSInteger, ScrollPhase) {
    ScrollPhaseNone,
    ScrollPhasePauseStart,
    ScrollPhaseScrollingLeft,
    ScrollPhasePauseEnd,
    ScrollPhaseScrollingRight,
};

// =============================================================================
// Toast state
// =============================================================================

typedef NS_ENUM(NSInteger, ToastState) {
    ToastStateIdle,
    ToastStateFadingIn,
    ToastStateVisible,
    ToastStateFadingOut,
};

// =============================================================================
// Forward declaration
// =============================================================================

@class ToastContentView;

@interface ToastController : NSObject
@property (nonatomic, strong) ToastWindow *window;
@property (nonatomic, strong) ToastContentView *contentView;
@property (nonatomic, strong) NSVisualEffectView *vibrancyView;
@property (nonatomic, strong) NSTimer *durationTimer;
@property (nonatomic, strong) NSTimer *mousePollingTimer;
@property (nonatomic, assign) BOOL timerExpired;
@property (nonatomic, assign) BOOL mouseInside;
@property (nonatomic, assign) ToastState state;
@property (nonatomic, assign) int serverFD;
@property (nonatomic, strong) NSFileHandle *serverHandle;
@property (nonatomic, assign) NSPoint initialMousePosition;

- (void)showToastWithText:(NSString *)text duration:(NSTimeInterval)duration;
- (void)dismissToast;
- (void)mouseDidMoveOverToast;
- (void)mouseExitedToast;
- (void)startServer;
@end

// =============================================================================
// ToastContentView
// =============================================================================

@interface ToastContentView : NSView
@property (nonatomic, strong) NSTextField *label;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, weak)   ToastController *controller;
@property (nonatomic, assign) BOOL needsScroll;
@property (nonatomic, strong) NSTimer *scrollTimer;
@property (nonatomic, assign) CGFloat scrollOffset;
@property (nonatomic, assign) CGFloat textWidth;
@property (nonatomic, assign) CGFloat visibleWidth;
@property (nonatomic, assign) ScrollPhase scrollPhase;
@property (nonatomic, assign) NSTimeInterval scrollPauseTime;
@end

@implementation ToastContentView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = [NSColor clearColor].CGColor;

        _label = [NSTextField labelWithString:@""];
        _label.bezeled = NO;
        _label.drawsBackground = NO;
        _label.editable = NO;
        _label.selectable = NO;
        _label.lineBreakMode = NSLineBreakByClipping;
        _label.wantsLayer = YES;  // prevent rendering artifacts during animation
        [self addSubview:_label];
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways)
               owner:self
            userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    [self.controller mouseDidMoveOverToast];
}

- (void)mouseMoved:(NSEvent *)event {
    (void)event;
    [self.controller mouseDidMoveOverToast];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    [self.controller mouseExitedToast];
}

- (void)setAttributedText:(NSAttributedString *)attrStr maxWidth:(CGFloat)maxWidth {
    self.label.attributedStringValue = attrStr;
    [self.label sizeToFit];

    self.textWidth = self.label.frame.size.width;
    self.visibleWidth = maxWidth - kHorizontalPadding * 2;

    CGFloat menuBarHeight = self.bounds.size.height;
    CGFloat labelY = round((menuBarHeight - self.label.frame.size.height) / 2.0);

    self.needsScroll = (self.textWidth > self.visibleWidth);

    if (self.needsScroll) {
        self.label.frame = NSMakeRect(round(kHorizontalPadding), labelY,
                                       ceil(self.textWidth), self.label.frame.size.height);

        // Left fade gradient mask so scrolled text disappears smoothly
        CAGradientLayer *mask = [CAGradientLayer layer];
        mask.frame = self.bounds;
        mask.startPoint = CGPointMake(0, 0.5);
        mask.endPoint = CGPointMake(1, 0.5);
        CGFloat fadeEnd = 8.0 / self.bounds.size.width;
        mask.colors = @[(__bridge id)[NSColor clearColor].CGColor,
                        (__bridge id)[NSColor blackColor].CGColor,
                        (__bridge id)[NSColor blackColor].CGColor];
        mask.locations = @[@0.0, @(fadeEnd), @1.0];
        self.layer.mask = mask;
    } else {
        // Right-align short text
        CGFloat rightX = maxWidth - kHorizontalPadding - ceil(self.textWidth);
        self.label.frame = NSMakeRect(round(rightX), labelY,
                                       ceil(self.textWidth), self.label.frame.size.height);
        self.layer.mask = nil;
    }
}

- (void)startScrolling {
    if (!self.needsScroll) return;
    self.scrollOffset = 0;
    self.scrollPhase = ScrollPhasePauseStart;
    self.scrollPauseTime = [NSDate timeIntervalSinceReferenceDate];

    self.scrollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                       target:self
                                                     selector:@selector(scrollTick)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)stopScrolling {
    [self.scrollTimer invalidate];
    self.scrollTimer = nil;
    self.scrollPhase = ScrollPhaseNone;
}

- (void)scrollTick {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    CGFloat maxOffset = self.textWidth - self.visibleWidth;

    switch (self.scrollPhase) {
        case ScrollPhasePauseStart:
            if (now - self.scrollPauseTime >= kScrollPauseStart) {
                self.scrollPhase = ScrollPhaseScrollingLeft;
            }
            break;

        case ScrollPhaseScrollingLeft:
            self.scrollOffset += kScrollSpeed / 60.0;
            if (self.scrollOffset >= maxOffset) {
                self.scrollOffset = maxOffset;
                self.scrollPhase = ScrollPhasePauseEnd;
                self.scrollPauseTime = now;
            }
            break;

        case ScrollPhasePauseEnd:
            if (now - self.scrollPauseTime >= kScrollPause) {
                self.scrollPhase = ScrollPhaseScrollingRight;
            }
            break;

        case ScrollPhaseScrollingRight:
            self.scrollOffset -= kScrollSpeed / 60.0;
            if (self.scrollOffset <= 0) {
                self.scrollOffset = 0;
                self.scrollPhase = ScrollPhasePauseStart;
                self.scrollPauseTime = now;
            }
            break;

        default:
            break;
    }

    NSRect labelFrame = self.label.frame;
    labelFrame.origin.x = round(kHorizontalPadding - self.scrollOffset);
    self.label.frame = labelFrame;
}

- (NSTimeInterval)minimumScrollDuration {
    if (!self.needsScroll) return 0;
    CGFloat maxOffset = self.textWidth - self.visibleWidth;
    NSTimeInterval scrollTime = maxOffset / kScrollSpeed;
    return kScrollPauseStart + scrollTime + kScrollPause;
}

@end

// =============================================================================
// IPC — socket functions
// =============================================================================

static int createServerSocket(const char *path) {
    unlink(path);

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    if (listen(fd, 5) < 0) {
        close(fd);
        unlink(path);
        return -1;
    }

    return fd;
}

static int tryConnectToServer(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    return fd;
}

static BOOL sendMessageToServer(int fd, NSDictionary *message) {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!jsonData) return NO;

    uint32_t len = htonl((uint32_t)jsonData.length);
    if (write(fd, &len, 4) != 4) return NO;
    if (write(fd, jsonData.bytes, jsonData.length) != (ssize_t)jsonData.length) return NO;

    // Read ACK (best-effort)
    char buf[256];
    read(fd, buf, sizeof(buf));

    return YES;
}

// =============================================================================
// ToastController (implementation)
// =============================================================================

@implementation ToastController

- (void)showToastWithText:(NSString *)text duration:(NSTimeInterval)duration {
    // ---- Screen geometry ----
    NSScreen *screen = [NSScreen mainScreen];
    NSRect screenFrame = screen.frame;
    CGFloat menuBarHeight = NSMaxY(screenFrame) - NSMaxY(screen.visibleFrame) - 1;
    if (menuBarHeight < 22) menuBarHeight = 24;

    // ---- Toast covers the right status area of the menu bar ----
    CGFloat statusLeftEdge = getStatusAreaLeftEdge();
    CGFloat toastX = statusLeftEdge - kLeftFadeWidth;
    CGFloat toastWidth = NSMaxX(screenFrame) - toastX;
    if (toastWidth < 100) {
        // Fallback if detection fails
        toastX = screenFrame.origin.x;
        toastWidth = screenFrame.size.width;
    }

    // ---- Detect menu bar appearance ----
    BOOL dark = isMenuBarDark();
    NSAppearance *menuBarAppearance = [NSAppearance appearanceNamed:
        dark ? NSAppearanceNameVibrantDark : NSAppearanceNameVibrantLight];

    // ---- Parse markup ----
    NSFont *menuFont = [NSFont menuFontOfSize:0];
    NSColor *menuColor = dark ? [NSColor whiteColor] : [NSColor blackColor];
    NSAttributedString *attrStr = parseMarkup(text, menuFont, menuColor);

    // ---- Window frame ----
    NSRect windowFrame = NSMakeRect(toastX,
                                     NSMaxY(screenFrame) - menuBarHeight,
                                     toastWidth,
                                     menuBarHeight);

    // ---- If toast is already visible, cross-fade the text ----
    BOOL alreadyVisible = (self.state == ToastStateFadingIn || self.state == ToastStateVisible);
    if (alreadyVisible && self.window) {
        CGFloat contentInset = kLeftFadeWidth;
        [self.window setFrame:windowFrame display:YES];
        self.vibrancyView.frame = NSMakeRect(0, 0, toastWidth, menuBarHeight);
        self.vibrancyView.layer.mask.frame = NSMakeRect(0, 0, toastWidth, menuBarHeight);
        self.contentView.frame = NSMakeRect(contentInset, 0, toastWidth - contentInset, menuBarHeight);
        self.window.appearance = menuBarAppearance;

        // Cancel timers
        [self.durationTimer invalidate];
        [self.contentView stopScrolling];
        [self.mousePollingTimer invalidate];
        self.mousePollingTimer = nil;

        // Pin label to prevent subpixel drift during fade
        NSRect pinned = self.contentView.label.frame;
        pinned.origin.x = round(pinned.origin.x);
        pinned.origin.y = round(pinned.origin.y);
        self.contentView.label.frame = pinned;

        // Fade out old text
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = kFadeDuration;
            ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            self.contentView.label.animator.alphaValue = 0.0;
        } completionHandler:^{
            // Update text content
            [self.contentView setAttributedText:attrStr maxWidth:toastWidth - kLeftFadeWidth];

            // Reset state
            self.timerExpired = NO;
            self.mouseInside = NO;
            self.initialMousePosition = [NSEvent mouseLocation];
            self.window.ignoresMouseEvents = NO;

            // Fade in new text
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = kFadeDuration;
                ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                self.contentView.label.animator.alphaValue = 1.0;
            } completionHandler:^{
                self.state = ToastStateVisible;
                [self.contentView startScrolling];
            }];

            // Restart duration timer
            NSTimeInterval minScrollDuration = [self.contentView minimumScrollDuration];
            NSTimeInterval actualDuration = MAX(duration, minScrollDuration);
            self.durationTimer = [NSTimer scheduledTimerWithTimeInterval:actualDuration
                                                                 target:self
                                                               selector:@selector(durationTimerFired)
                                                               userInfo:nil
                                                                repeats:NO];
        }];
        return;
    }

    // ---- Create or update window ----
    if (!self.window) {
        self.window = [[ToastWindow alloc]
            initWithContentRect:windowFrame
                      styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        self.window.opaque = NO;
        self.window.backgroundColor = [NSColor clearColor];
        self.window.hasShadow = NO;
        self.window.level = NSStatusWindowLevel;
        self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                          NSWindowCollectionBehaviorStationary;

        // Vibrancy effect view as the content view
        self.vibrancyView = [[NSVisualEffectView alloc]
            initWithFrame:NSMakeRect(0, 0, toastWidth, menuBarHeight)];
        self.vibrancyView.material = NSVisualEffectMaterialMenu;
        self.vibrancyView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.vibrancyView.state = NSVisualEffectStateActive;
        self.vibrancyView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.vibrancyView.wantsLayer = YES;

        // Left-edge fade mask so vibrancy blends into the real menu bar
        CAGradientLayer *fadeMask = [CAGradientLayer layer];
        fadeMask.frame = NSMakeRect(0, 0, toastWidth, menuBarHeight);
        fadeMask.startPoint = CGPointMake(0, 0.5);
        fadeMask.endPoint = CGPointMake(1, 0.5);
        CGFloat fadeWidth = kLeftFadeWidth / toastWidth;
        fadeMask.colors = @[(__bridge id)[NSColor clearColor].CGColor,
                            (__bridge id)[NSColor blackColor].CGColor,
                            (__bridge id)[NSColor blackColor].CGColor];
        fadeMask.locations = @[@0.0, @(fadeWidth), @1.0];
        self.vibrancyView.layer.mask = fadeMask;

        self.window.contentView = self.vibrancyView;

        // Toast content view on top of vibrancy, offset past the fade zone
        self.contentView = [[ToastContentView alloc]
            initWithFrame:NSMakeRect(kLeftFadeWidth, 0, toastWidth - kLeftFadeWidth, menuBarHeight)];
        self.contentView.controller = self;
        [self.vibrancyView addSubview:self.contentView];

        self.window.alphaValue = 0.0;
    } else {
        CGFloat contentInset = kLeftFadeWidth;
        [self.window setFrame:windowFrame display:YES];
        self.vibrancyView.frame = NSMakeRect(0, 0, toastWidth, menuBarHeight);
        self.vibrancyView.layer.mask.frame = NSMakeRect(0, 0, toastWidth, menuBarHeight);
        self.contentView.frame = NSMakeRect(contentInset, 0, toastWidth - contentInset, menuBarHeight);
    }

    // ---- Set appearance to match menu bar ----
    self.window.appearance = menuBarAppearance;
    self.window.backgroundColor = [NSColor clearColor];
    self.vibrancyView.hidden = NO;

    [self.contentView setAttributedText:attrStr maxWidth:toastWidth - kLeftFadeWidth];

    // ---- Duration (extend for scroll if needed) ----
    NSTimeInterval minScrollDuration = [self.contentView minimumScrollDuration];
    NSTimeInterval actualDuration = MAX(duration, minScrollDuration);

    // ---- Reset state ----
    self.timerExpired = NO;
    self.mouseInside = NO;
    self.initialMousePosition = [NSEvent mouseLocation];
    [self.durationTimer invalidate];
    [self.contentView stopScrolling];
    self.contentView.label.alphaValue = 1.0;
    self.contentView.alphaValue = 1.0;
    self.window.ignoresMouseEvents = NO;
    [self.mousePollingTimer invalidate];
    self.mousePollingTimer = nil;

    // ---- Show + fade in ----
    [self.window orderFront:nil];
    self.state = ToastStateFadingIn;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kFadeDuration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.window.animator.alphaValue = 1.0;
    } completionHandler:^{
        self.state = ToastStateVisible;
        [self.contentView startScrolling];
    }];

    // ---- Duration timer ----
    self.durationTimer = [NSTimer scheduledTimerWithTimeInterval:actualDuration
                                                         target:self
                                                       selector:@selector(durationTimerFired)
                                                       userInfo:nil
                                                        repeats:NO];
}

- (void)durationTimerFired {
    self.timerExpired = YES;
    [self fadeOutAndExit];
}

- (void)fadeOutAndExit {
    if (self.state == ToastStateFadingOut) return;
    self.state = ToastStateFadingOut;

    [self.contentView stopScrolling];
    [self.mousePollingTimer invalidate];
    self.mousePollingTimer = nil;
    self.window.ignoresMouseEvents = YES;

    // Pin label position to prevent subpixel drift during fade-out
    NSRect pinned = self.contentView.label.frame;
    pinned.origin.x = round(pinned.origin.x);
    pinned.origin.y = round(pinned.origin.y);
    self.contentView.label.frame = pinned;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kFadeDuration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.window.animator.alphaValue = 0.0;
    } completionHandler:^{
        self.state = ToastStateIdle;
        [self.window orderOut:nil];
        exit(0);  // atexit will clean up socket
    }];
}

- (void)dismissToast {
    [self.durationTimer invalidate];
    self.durationTimer = nil;
    self.timerExpired = YES;
    [self fadeOutAndExit];
}

// ---- Mouse tracking ----

- (BOOL)mouseHasMovedFromInitial {
    NSPoint cur = [NSEvent mouseLocation];
    CGFloat dx = cur.x - self.initialMousePosition.x;
    CGFloat dy = cur.y - self.initialMousePosition.y;
    return (dx * dx + dy * dy) >= 9.0;  // 3px threshold
}

- (void)mouseDidMoveOverToast {
    if (self.timerExpired || self.mouseInside || self.state != ToastStateVisible) return;
    if (![self mouseHasMovedFromInitial]) return;
    self.mouseInside = YES;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.25;
        self.window.animator.alphaValue = 0.0;
    } completionHandler:^{
        self.window.ignoresMouseEvents = YES;
        [self startMousePolling];
    }];
}

- (void)mouseExitedToast {
    if (self.timerExpired || !self.mouseInside) return;
    self.mouseInside = NO;

    [self stopMousePolling];
    self.window.ignoresMouseEvents = NO;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.15;
        self.window.animator.alphaValue = 1.0;
    } completionHandler:nil];
}

- (void)startMousePolling {
    [self.mousePollingTimer invalidate];
    self.mousePollingTimer = [NSTimer scheduledTimerWithTimeInterval:kMousePollInterval
                                                             target:self
                                                           selector:@selector(pollMousePosition)
                                                           userInfo:nil
                                                            repeats:YES];
}

- (void)stopMousePolling {
    [self.mousePollingTimer invalidate];
    self.mousePollingTimer = nil;
}

- (void)pollMousePosition {
    NSPoint mouseLoc = [NSEvent mouseLocation];
    NSRect windowFrame = self.window.frame;

    if (!NSPointInRect(mouseLoc, windowFrame)) {
        [self mouseExitedToast];
    }
}

// ---- IPC Server ----

- (void)startServer {
    self.serverFD = createServerSocket(gSocketPath);
    if (self.serverFD < 0) {
        NSLog(@"MenubarToast: Failed to create server socket");
        return;
    }

    self.serverHandle = [[NSFileHandle alloc] initWithFileDescriptor:self.serverFD
                                                     closeOnDealloc:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(acceptConnection:)
                                                 name:NSFileHandleConnectionAcceptedNotification
                                               object:self.serverHandle];

    [self.serverHandle acceptConnectionInBackgroundAndNotify];
}

- (void)acceptConnection:(NSNotification *)notification {
    NSFileHandle *clientHandle =
        notification.userInfo[NSFileHandleNotificationFileHandleItem];

    if (clientHandle) {
        NSData *data = [clientHandle availableData];
        if (data.length > 4) {
            NSData *jsonData = [data subdataWithRange:NSMakeRange(4, data.length - 4)];
            NSError *error;
            NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:jsonData
                                                               options:0
                                                                 error:&error];
            if (msg) {
                [self handleIncomingMessage:msg];

                // Send ACK
                NSDictionary *ack = @{@"status": @"ok"};
                NSData *ackData = [NSJSONSerialization dataWithJSONObject:ack
                                                                 options:0
                                                                   error:nil];
                uint32_t ackLen = htonl((uint32_t)ackData.length);
                NSMutableData *response = [NSMutableData dataWithBytes:&ackLen length:4];
                [response appendData:ackData];
                [clientHandle writeData:response];
            }
        }
        [clientHandle closeFile];
    }

    // Continue accepting
    [self.serverHandle acceptConnectionInBackgroundAndNotify];
}

- (void)handleIncomingMessage:(NSDictionary *)message {
    NSString *action = message[@"action"];

    if ([action isEqualToString:@"dismiss"]) {
        [self dismissToast];
    } else if ([action isEqualToString:@"show"]) {
        NSString *text = message[@"text"] ?: @"";
        NSTimeInterval duration = [message[@"duration"] doubleValue];
        if (duration <= 0) duration = getDefaultDuration();
        [self showToastWithText:text duration:duration];
    }
}

@end

// =============================================================================
// Usage
// =============================================================================

static void printUsage(void) {
    fprintf(stderr,
        "Usage: MenubarToast [OPTIONS] [TEXT]\n"
        "       echo \"text\" | MenubarToast\n"
        "\n"
        "Options:\n"
        "  --duration N   Display duration in seconds (default: 2)\n"
        "  --dismiss      Dismiss current toast\n"
        "  --help, -h     Show this help\n"
        "\n"
        "Markup:\n"
        "  **bold**                     Bold text\n"
        "  {color:red}text{/color}      Colored text (named or #hex)\n"
        "  {icon:star.fill}             SF Symbol icon\n"
        "\n"
        "Defaults:\n"
        "  defaults write MenubarToast duration -float 3.0\n"
        "  Set default display duration (overridden by --duration)\n"
    );
}

// =============================================================================
// main
// =============================================================================

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // ---- Socket path ----
        snprintf(gSocketPath, sizeof(gSocketPath),
                 "/tmp/MenubarToast-%d.sock", getuid());

        // ---- Server mode (hidden flag, used by fork+exec) ----
        if (argc >= 2 && strcmp(argv[1], "--_server") == 0) {
            NSString *text = argc >= 3
                ? [NSString stringWithUTF8String:argv[2]]
                : @"";
            double duration = argc >= 4 ? atof(argv[3]) : getDefaultDuration();

            signal(SIGTERM, signalHandler);
            signal(SIGINT, signalHandler);
            atexit(cleanupSocket);

            NSApplication *app = [NSApplication sharedApplication];
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

            ToastController *controller = [[ToastController alloc] init];
            [controller startServer];
            [controller showToastWithText:text duration:duration];

            [app run];
            return 0;
        }

        // ---- Parse CLI arguments ----
        NSString *text = nil;
        NSTimeInterval duration = getDefaultDuration();
        BOOL dismiss = NO;

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
                duration = atof(argv[++i]);
                if (duration <= 0) duration = getDefaultDuration();
            } else if (strcmp(argv[i], "--dismiss") == 0) {
                dismiss = YES;
            } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
                printUsage();
                return 0;
            } else if (argv[i][0] != '-') {
                text = [NSString stringWithUTF8String:argv[i]];
            }
        }

        // ---- Read stdin if pipe ----
        if (!text && !dismiss && !isatty(STDIN_FILENO)) {
            NSData *data = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
            text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        // ---- Validate ----
        if (!dismiss && (!text || text.length == 0)) {
            printUsage();
            return 1;
        }

        // ---- Build message ----
        NSDictionary *message;
        if (dismiss) {
            message = @{@"action": @"dismiss"};
        } else {
            message = @{
                @"action":   @"show",
                @"text":     text,
                @"duration": @(duration),
            };
        }

        // ---- Try existing server ----
        int fd = tryConnectToServer(gSocketPath);
        if (fd >= 0) {
            BOOL sent = sendMessageToServer(fd, message);
            close(fd);
            if (sent) return 0;
            // Stale socket
            unlink(gSocketPath);
        }

        // ---- Dismiss with no server: nothing to do ----
        if (dismiss) return 0;

        // ---- Get executable path for fork+exec ----
        char execPath[4096];
        uint32_t execPathSize = sizeof(execPath);
        if (_NSGetExecutablePath(execPath, &execPathSize) != 0) {
            fprintf(stderr, "MenubarToast: Could not determine executable path\n");
            return 1;
        }
        char realExecPath[PATH_MAX];
        if (!realpath(execPath, realExecPath)) {
            strncpy(realExecPath, execPath, PATH_MAX - 1);
            realExecPath[PATH_MAX - 1] = '\0';
        }

        // ---- Fork + exec in server mode ----
        pid_t pid = fork();
        if (pid < 0) {
            perror("fork");
            return 1;
        }
        if (pid > 0) {
            // Parent: return immediately (non-blocking)
            return 0;
        }

        // Child: detach from terminal
        setsid();
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            dup2(devnull, STDIN_FILENO);
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            if (devnull > 2) close(devnull);
        }

        // Exec self in server mode
        char durationStr[32];
        snprintf(durationStr, sizeof(durationStr), "%.2f", duration);
        execl(realExecPath, realExecPath, "--_server",
              [text UTF8String], durationStr, NULL);
        _exit(1);
    }
    return 0;
}
