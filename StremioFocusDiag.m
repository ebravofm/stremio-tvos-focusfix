// Diagnostico de foco para la grilla de biblioteca de Stremio tvOS.
// Muestra en pantalla los ultimos eventos de foco y avisa si el hilo principal se bloquea.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static UILabel *gHUD;
static NSMutableArray<NSString *> *gLines;
static volatile CFAbsoluteTime gLastPong;

static void StremioFixLog(NSString *line) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gLines) gLines = [NSMutableArray array];
        [gLines addObject:line];
        while (gLines.count > 9) [gLines removeObjectAtIndex:0];
        gHUD.text = [gLines componentsJoinedByString:@"\n"];
    });
}

static void InstallHUD(void) {
    UIWindow *win = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class])
            for (UIWindow *w in ((UIWindowScene *)s).windows) { if (w.isKeyWindow) win = w; }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ InstallHUD(); }); return; }
    gHUD = [[UILabel alloc] initWithFrame:CGRectMake(40, 40, 1100, 330)];
    gHUD.numberOfLines = 0;
    gHUD.font = [UIFont monospacedSystemFontOfSize:22 weight:UIFontWeightRegular];
    gHUD.textColor = UIColor.yellowColor;
    gHUD.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    gHUD.userInteractionEnabled = NO;
    gHUD.text = @"StremioFocusDiag activo";
    [win addSubview:gHUD];
    gHUD.layer.zPosition = 10000;
}

static void StartWatchdog(void) {
    gLastPong = CFAbsoluteTimeGetCurrent();
    dispatch_queue_t q = dispatch_queue_create("stremiofix.watchdog", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        BOOL reported = NO;
        while (YES) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CFAbsoluteTime blocked = CFAbsoluteTimeGetCurrent() - gLastPong;
                if (blocked > 1.5) StremioFixLog([NSString stringWithFormat:@"main desbloqueado tras %.1fs", blocked]);
                gLastPong = CFAbsoluteTimeGetCurrent();
            });
            [NSThread sleepForTimeInterval:0.5];
            if (CFAbsoluteTimeGetCurrent() - gLastPong > 2.0 && !reported) {
                reported = YES;
                NSLog(@"[StremioFocusDiag] HILO PRINCIPAL BLOQUEADO");
            } else if (CFAbsoluteTimeGetCurrent() - gLastPong <= 2.0) reported = NO;
        }
    });
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
    NSString *idx = @"-", *vis = @"-";
    if ([next isKindOfClass:UICollectionViewCell.class] && cv) {
        NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)next];
        idx = ip ? [NSString stringWithFormat:@"%ld/%ld", (long)ip.section, (long)ip.item] : @"nil";
        CGRect visible = CGRectMake(cv.contentOffset.x, cv.contentOffset.y, cv.bounds.size.width, cv.bounds.size.height);
        vis = CGRectIntersectsRect(visible, next.frame) ? @"visible" : @"FUERA";
    }
    StremioFixLog([NSString stringWithFormat:@"foco %@ idx=%@ %@ off=(%.0f,%.0f) win=%d",
                   next ? NSStringFromClass(next.class) : @"nil", idx, vis,
                   cv.contentOffset.x, cv.contentOffset.y, next.window != nil]);
}

static void Install(void) {
    Class c = NSClassFromString(@"_TtC7Stremio25CatalogGridViewController");
    if (!c) { StremioFixLog(@"clase CatalogGridViewController NO encontrada"); return; }
    SEL sel = @selector(didUpdateFocusInContext:withAnimationCoordinator:);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { StremioFixLog(@"metodo didUpdateFocus NO encontrado"); return; }
    gOrigFocus = (FocusIMP)method_setImplementation(m, (IMP)HookedDidUpdateFocus);
    StremioFixLog(@"hook didUpdateFocus instalado");
}

__attribute__((constructor)) static void StremioFocusDiagInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ InstallHUD(); Install(); StartWatchdog(); });
    }];
}
