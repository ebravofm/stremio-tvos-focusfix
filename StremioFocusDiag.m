// Diagnostico de foco para la grilla de biblioteca de Stremio tvOS.
// El recuadro vive en su propia UIWindow para que la app no pueda quitarlo.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach/mach.h>

static UIWindow *gHUDWin;
static UILabel *gHUD;
static NSMutableArray<NSString *> *gLines;
static volatile CFAbsoluteTime gLastPong;

static double FootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        return info.phys_footprint / 1048576.0;
    return -1;
}

static void StremioFixLog(NSString *line) {
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
    gHUD = [[UILabel alloc] initWithFrame:CGRectMake(40, 40, 1500, 380)];
    gHUD.numberOfLines = 0;
    gHUD.font = [UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightRegular];
    gHUD.textColor = UIColor.yellowColor;
    gHUD.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    gHUD.text = gLines.count ? [gLines componentsJoinedByString:@"\n"] : @"StremioFocusDiag v2 activo";
    [vc.view addSubview:gHUD];
    gHUDWin.hidden = NO;
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
    NSString *idx = @"-", *vis = @"-";
    if ([next isKindOfClass:UICollectionViewCell.class] && cv) {
        NSIndexPath *ip = [cv indexPathForCell:(UICollectionViewCell *)next];
        idx = ip ? [NSString stringWithFormat:@"%ld", (long)ip.item] : @"nil";
        CGRect visible = CGRectMake(cv.contentOffset.x, cv.contentOffset.y, cv.bounds.size.width, cv.bounds.size.height);
        vis = CGRectIntersectsRect(visible, next.frame) ? @"vis" : @"FUERA";
    }
    UIViewController *vc = (UIViewController *)self;
    StremioFixLog([NSString stringWithFormat:@"foco %@ i=%@ %@ off=(%.0f,%.0f) vcwin=%d n=%ld mem=%.0fMB",
                   next ? NSStringFromClass(next.class) : @"nil", idx, vis,
                   cv.contentOffset.x, cv.contentOffset.y,
                   vc.isViewLoaded && vc.view.window != nil,
                   (long)gHUDWin.windowScene.windows.count, FootprintMB()]);
}

static void Install(void) {
    Class c = NSClassFromString(@"_TtC7Stremio25CatalogGridViewController");
    if (!c) { StremioFixLog(@"clase CatalogGridViewController NO encontrada"); return; }
    Method m = class_getInstanceMethod(c, @selector(didUpdateFocusInContext:withAnimationCoordinator:));
    if (!m) { StremioFixLog(@"metodo didUpdateFocus NO encontrado"); return; }
    gOrigFocus = (FocusIMP)method_setImplementation(m, (IMP)HookedDidUpdateFocus);
    StremioFixLog([NSString stringWithFormat:@"hook instalado mem=%.0fMB", FootprintMB()]);
}

__attribute__((constructor)) static void StremioFocusDiagInit(void) {
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
