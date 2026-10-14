// Diagnostico de foco para la grilla de biblioteca de Stremio tvOS.
// El recuadro vive en su propia UIWindow para que la app no pueda quitarlo.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>

// 1 = el layout deja de calcular su propio destino de scroll y se usa el del sistema.
#ifndef BYPASS_CUSTOM_TARGET
#define BYPASS_CUSTOM_TARGET 1
#endif

static UIWindow *gHUDWin;
static UILabel *gHUD;
static UILabel *gBeat;
static __weak UICollectionView *gCV;
static unsigned long gTick;
static NSMutableArray<NSString *> *gLines;
static volatile CFAbsoluteTime gLastPong;

static dispatch_queue_t gFileQ;
static NSString *gLogPath;
static UILabel *gPrev;
static NSString *gPrevText;

static void FileLog(NSString *line) {
    if (!gFileQ || !gLogPath) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *row = [NSString stringWithFormat:@"%.2f %@\n", fmod(now, 10000), line];
    dispatch_sync(gFileQ, ^{
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!h) { [@"" writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:nil]; h = [NSFileHandle fileHandleForWritingAtPath:gLogPath]; }
        [h seekToEndOfFile];
        [h writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
        [h synchronizeFile];
        [h closeFile];
    });
}

static void SetupFileLog(void) {
    gFileQ = dispatch_queue_create("stremiofix.file", DISPATCH_QUEUE_SERIAL);
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    gLogPath = [dir stringByAppendingPathComponent:@"focusdiag.log"];
    NSString *prev = [NSString stringWithContentsOfFile:gLogPath encoding:NSUTF8StringEncoding error:nil];
    if (prev.length) {
        NSArray *rows = [prev componentsSeparatedByString:@"\n"];
        NSUInteger from = rows.count > 22 ? rows.count - 22 : 0;
        gPrevText = [@"EJECUCION ANTERIOR (ultimas lineas):\n" stringByAppendingString:
                     [[rows subarrayWithRange:NSMakeRange(from, rows.count - from)] componentsJoinedByString:@"\n"]];
    }
    [[NSFileManager defaultManager] removeItemAtPath:gLogPath error:nil];
}

static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        return info.phys_footprint / 1048576.0;
    return -1;
}

static void StremioFixLog(NSString *line) {
    FileLog(line);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLines) gLines = [NSMutableArray array];
        [gLines addObject:line];
        while (gLines.count > 12) [gLines removeObjectAtIndex:0];
        gHUD.text = [gLines componentsJoinedByString:@"\n"];
    });
}

static void InstallHUD(void) {
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
    if (!scene) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ InstallHUD(); });
        return;
    }
    gHUDWin = [[UIWindow alloc] initWithWindowScene:scene];
    gHUDWin.windowLevel = UIWindowLevelAlert + 1000;
    gHUDWin.backgroundColor = UIColor.clearColor;
    gHUDWin.userInteractionEnabled = NO;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    gHUDWin.rootViewController = vc;
    gHUD = [[UILabel alloc] initWithFrame:CGRectMake(40, 40, 1840, 380)];
    gHUD.numberOfLines = 0;
    gHUD.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
    gHUD.textColor = UIColor.yellowColor;
    gHUD.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    gHUD.text = gLines.count ? [gLines componentsJoinedByString:@"\n"] : @"StremioFocusDiag v5 activo (log en archivo)";
    [vc.view addSubview:gHUD];
    gBeat = [[UILabel alloc] initWithFrame:CGRectMake(40, 8, 1840, 28)];
    gBeat.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightBold];
    gBeat.textColor = UIColor.cyanColor;
    gBeat.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    [vc.view addSubview:gBeat];
    if (gPrevText) {
        gPrev = [[UILabel alloc] initWithFrame:CGRectMake(40, 430, 1840, 560)];
        gPrev.numberOfLines = 0;
        gPrev.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
        gPrev.textColor = UIColor.orangeColor;
        gPrev.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        gPrev.text = gPrevText;
        [vc.view addSubview:gPrev];
    }
    gHUDWin.hidden = NO;
    // Latido: si el contador deja de avanzar, el hilo principal esta bloqueado.
    NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm) {
        UICollectionView *cv = gCV;
        NSString *focus = @"-";
        if (cv) {
            id<UIFocusItem> it = [UIFocusSystem focusSystemForEnvironment:cv].focusedItem;
            if ([it isKindOfClass:UICollectionViewCell.class]) {
                NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)it];
                focus = [NSString stringWithFormat:@"cell %ld", (long)ip.item];
            } else focus = it ? NSStringFromClass([(id)it class]) : @"nil";
        }
        gBeat.text = [NSString stringWithFormat:@"tick=%lu sysfocus=%@ off=%.0f drag=%d decel=%d anim=%d",
                      ++gTick, focus, cv.contentOffset.x, cv.isDragging, cv.isDecelerating,
                      (int)cv.layer.animationKeys.count];
        if (gTick % 4 == 0) FileLog(gBeat.text);
    }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

static void StartWatchdog(void) {
    gLastPong = CFAbsoluteTimeGetCurrent();
    dispatch_queue_t q = dispatch_queue_create("stremiofix.watchdog", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        while (YES) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CFAbsoluteTime blocked = CFAbsoluteTimeGetCurrent() - gLastPong;
                if (blocked > 1.5) StremioFixLog([NSString stringWithFormat:@"main desbloqueado tras %.1fs", blocked]);
                gLastPong = CFAbsoluteTimeGetCurrent();
            });
            [NSThread sleepForTimeInterval:0.5];
            CFAbsoluteTime lag = CFAbsoluteTimeGetCurrent() - gLastPong;
            if (lag > 2.0) FileLog([NSString stringWithFormat:@"MAIN BLOQUEADO %.1fs", lag]);
        }
    });
}

static void Observe(NSNotificationName name) {
    [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) {
        NSString *short_ = [name stringByReplacingOccurrencesOfString:@"Notification" withString:@""];
        NSString *cls = n.object ? NSStringFromClass([n.object class]) : @"";
        StremioFixLog([NSString stringWithFormat:@"! %@ %@ mem=%.0fMB", short_, cls, FootprintMB()]);
    }];
}

static UICollectionView *FindCollectionView(UIView *v) {
    while (v && ![v isKindOfClass:UICollectionView.class]) v = v.superview;
    return (UICollectionView *)v;
}

typedef void (*FocusIMP)(id, SEL, UIFocusUpdateContext *, UIFocusAnimationCoordinator *);
static FocusIMP gOrigFocus;

static void HookedDidUpdateFocus(id self, SEL _cmd, UIFocusUpdateContext *ctx, UIFocusAnimationCoordinator *coord) {
    gOrigFocus(self, _cmd, ctx, coord);
    UIView *next = ctx.nextFocusedView;
    UICollectionView *cv = FindCollectionView(next);
    if (cv) gCV = cv;
    NSString *idx = @"-", *vis = @"-", *geo = @"";
    BOOL isCell = [next isKindOfClass:UICollectionViewCell.class] && cv;
    if (isCell) {
        NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)next];
        idx = ip ? [NSString stringWithFormat:@"%ld", (long)ip.item] : @"nil";
        CGRect visible = CGRectMake(cv.contentOffset.x, cv.contentOffset.y, cv.bounds.size.width, cv.bounds.size.height);
        vis = CGRectIntersectsRect(visible, next.frame) ? @"vis" : @"FUERA";
        geo = [NSString stringWithFormat:@" cs=%.0f fr=%.0f+%.0f bw=%.0f n=%ld %@",
               cv.contentSize.width, next.frame.origin.x, next.frame.size.width, cv.bounds.size.width,
               (long)[cv numberOfItemsInSection:0], [NSStringFromClass(cv.collectionViewLayout.class) stringByReplacingOccurrencesOfString:@"Stremio." withString:@""]];
    }
    StremioFixLog([NSString stringWithFormat:@"foco i=%@ %@ off=%.0f%@ m=%.0f",
                   idx, vis, cv.contentOffset.x, geo, FootprintMB()]);

    // Correccion de prueba: si poco despues la celda enfocada sigue fuera de pantalla, forzar el scroll.
    if (isCell) {
        __weak UICollectionView *wcv = cv;
        __weak UIView *wnext = next;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UICollectionView *c = wcv; UIView *cell = wnext;
            if (!c || !cell || !cell.window) return;
            CGRect visible = CGRectMake(c.contentOffset.x, c.contentOffset.y, c.bounds.size.width, c.bounds.size.height);
            if (CGRectContainsRect(visible, cell.frame)) return;
            CGFloat before = c.contentOffset.x;
            [c scrollRectToVisible:CGRectInset(cell.frame, -120, 0) animated:NO];
            StremioFixLog([NSString stringWithFormat:@"FIX off %.0f -> %.0f cs=%.0f", before, c.contentOffset.x, c.contentSize.width]);
        });
    }
}

typedef CGPoint (*TCOIMP)(id, SEL, CGPoint, CGPoint);
static TCOIMP gOrigTCO;
static CFAbsoluteTime gLastTCOLog;

static CGPoint HookedTCO(id self, SEL _cmd, CGPoint proposed, CGPoint velocity) {
    CGPoint orig = gOrigTCO(self, _cmd, proposed, velocity);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (fabs(orig.x - proposed.x) > 1.0 && now - gLastTCOLog > 0.2) {
        gLastTCOLog = now;
        StremioFixLog([NSString stringWithFormat:@"tco prop=%.0f orig=%.0f %@", proposed.x, orig.x,
                       BYPASS_CUSTOM_TARGET ? @"-> uso prop" : @"-> uso orig"]);
    }
    return BYPASS_CUSTOM_TARGET ? proposed : orig;
}

static void Install(void) {
    Class c = NSClassFromString(@"_TtC7Stremio25CatalogGridViewController");
    if (!c) { StremioFixLog(@"clase CatalogGridViewController NO encontrada"); return; }
    Method m = class_getInstanceMethod(c, @selector(didUpdateFocusInContext:withAnimationCoordinator:));
    if (!m) { StremioFixLog(@"metodo didUpdateFocus NO encontrado"); return; }
    gOrigFocus = (FocusIMP)method_setImplementation(m, (IMP)HookedDidUpdateFocus);
    Class lay = NSClassFromString(@"_TtC7Stremio24LeadingAlignedFlowLayout");
    Method lm = lay ? class_getInstanceMethod(lay, @selector(targetContentOffsetForProposedContentOffset:withScrollingVelocity:)) : NULL;
    if (lm) gOrigTCO = (TCOIMP)method_setImplementation(lm, (IMP)HookedTCO);
    StremioFixLog([NSString stringWithFormat:@"hook foco ok, hook layout %@ bypass=%d mem=%.0fMB",
                   lm ? @"ok" : @"NO ENCONTRADO", BYPASS_CUSTOM_TARGET, FootprintMB()]);
}

__attribute__((constructor)) static void StremioFocusDiagInit(void) {
    SetupFileLog();
    Observe(UIApplicationDidReceiveMemoryWarningNotification);
    Observe(UIApplicationWillResignActiveNotification);
    Observe(UIApplicationDidEnterBackgroundNotification);
    Observe(UIWindowDidBecomeVisibleNotification);
    Observe(UIWindowDidBecomeHiddenNotification);
    Observe(UIWindowDidBecomeKeyNotification);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ InstallHUD(); Install(); StartWatchdog(); });
    }];
}
