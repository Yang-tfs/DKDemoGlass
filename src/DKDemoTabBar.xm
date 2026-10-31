//
//  DKDemoTabBar.xm
//  DKDemoGlass
//
//  目的：在 iOS 16 上验证「自绘悬浮胶囊底栏」这条路，不追求功能完整。
//
//  做法：
//   1. 钩 AWENormalModeTabBar 的 layoutSubviews / didMoveToWindow，接管它的子视图；
//   2. 把原生子视图整体 alpha 归零、底栏本身背景清空——否则玻璃底下永远是一块白底，
//      模糊什么都看不出来（这一步对应 DYKiller 里的 DKTabBarBackdrop 模块）；
//   3. 挂两块自绘胶囊：左侧 4 项，右侧独立拍摄圆键；内容尽量从原生按钮镜像（图标 / 标题 / 选中态）；
//   4. 点击转发给原生按钮的 UIControl 事件，失败只打日志，不崩。
//
//  刻意保持"探测式"写法：抖音换了类名 / KVC 键，最坏是回退成占位图标 + 一条诊断日志，
//  而不是把 App 拖崩。长按胶囊出菜单，可以切材质、临时隐藏 3 秒和原生对比。
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "DKDemoGlassCapsule.h"

// 抖音底栏。只声明本插件用到的部分；类不存在时 Logos 会跳过钩子并打日志。
@interface AWENormalModeTabBar : UIView
@end

// 前置声明：菜单与对比逻辑要用到它，而它定义在文件后半段。
static void DKDemoSync(AWENormalModeTabBar *bar);
static void DKDemoUpdateFloatButton(UIWindow *window);
static UIWindow *DKDemoKeyWindow(void);

#pragma mark - 常量

static NSString *const kDKDemoEnabledKey = @"DKDemoGlassEnabled";
static NSString *const kDKDemoPresetKey  = @"DKDemoGlassPreset";

static const long long kDKDemoPlusButtonType = 2;

static const CGFloat kDKDemoCapsuleHeight = 62.0;
static const CGFloat kDKDemoPlusKeySide   = 62.0;
static const CGFloat kDKDemoEdgeInset     = 16.0;
static const CGFloat kDKDemoPlusGap       = 12.0;

// 关联对象键：记住原生视图被我们改掉之前的 alpha / 背景色。
static char kDKDemoOriginalAlphaKey;
static char kDKDemoOriginalColorKey;

#pragma mark - 状态

static __weak AWENormalModeTabBar *gBar;
static DKDemoGlassCapsule *gCapsule;
static DKDemoGlassCapsule *gPlusKey;
static NSMutableArray<UIControl *> *gItems;
static NSArray *gNativeButtons;
static __weak UIControl *gPlusNativeButton;
static NSString *gSignature;
static NSString *gDiagnostics;
static NSString *gScanReport;
static BOOL gSyncing;
static UIButton *gFloatButton;
static BOOL gFloatButtonHidden;
static CGFloat gPanBaseGap = 34.0;   // 拖动开始时的距底值
static CGFloat gLastGap = 36.0;      // 本次布局实际用的距底值（原位时也会填）
/// 宿主：YES = 挂 window（默认），NO = 挂底栏。
/// 只在本次运行内有效，不落盘——上一版把它存进 NSUserDefaults，误触一次就再也回不来，
/// 重启 App 恢复窗口模式比让用户去菜单里找回来靠谱。
static BOOL gHostWindow = YES;

/// 「隐藏 3 秒对比原生」的窗口期。这期间 sync 不能再把原生子视图藏回去，
/// 否则 layoutSubviews 一触发，那 3 秒里两边都看不见，这个功能就等于没有。
static NSTimeInterval gComparisonUntil = 0.0;

static BOOL DKDemoComparing(void) {
    return gComparisonUntil > [NSDate timeIntervalSinceReferenceDate];
}

#pragma mark - 内容项

/// 胶囊里的一项：有文字时只显示文字（iOS 26 悬浮栏的形态），选中项底下垫一枚深色内胶囊；
/// 没有文字时只居中图标（右侧拍摄键复用同一个类）。
@interface DKDemoItemView : UIControl
@property (nonatomic, strong) UIView *selectionView;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
- (void)applyTint;
@end

@implementation DKDemoItemView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _selectionView = [[UIView alloc] initWithFrame:CGRectZero];
    _selectionView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
    _selectionView.userInteractionEnabled = NO;
    _selectionView.hidden = YES;
    [self addSubview:_selectionView];

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.75;
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    BOOL textOnly = self.titleLabel.text.length > 0;

    if (textOnly) {
        // 选中态：内缩一圈的深色胶囊，跟参考图一致。
        CGFloat padX = 2.0;
        CGFloat padY = 6.0;
        self.selectionView.frame = CGRectInset(bounds, padX, padY);
        self.selectionView.layer.cornerRadius = MAX(CGRectGetHeight(self.selectionView.bounds) * 0.5, 0.0);
        self.selectionView.layer.cornerCurve = kCACornerCurveContinuous;
        self.selectionView.hidden = !self.isSelected;

        self.iconView.hidden = YES;
        self.iconView.frame = CGRectZero;
        self.titleLabel.frame = bounds;
    } else {
        self.selectionView.hidden = YES;
        self.iconView.hidden = NO;
        CGFloat side = MIN(30.0, MAX(MIN(bounds.size.width, bounds.size.height) - 10.0, 0.0));
        self.iconView.frame = CGRectMake((bounds.size.width - side) * 0.5,
                                         (bounds.size.height - side) * 0.5, side, side);
        self.titleLabel.frame = CGRectZero;
    }
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self applyTint];
    [self setNeedsLayout];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    // 按压反馈自己做：iOS 26 的 platter 有系统缩放，16 上没有，只能补一个。
    [UIView animateWithDuration:0.16
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.94, 0.94) : CGAffineTransformIdentity;
    } completion:nil];
}

- (void)tintColorDidChange {
    [super tintColorDidChange];
    [self applyTint];
}

- (void)applyTint {
    // 底栏浮在视频上，抖音又把 window 强制成浅色（导致 tintColor 是黑的），
    // 所以内容色不能跟 tintColor 走——固定白色 + 轻阴影，深色浅色背景都读得出来。
    UIColor *base = UIColor.whiteColor;
    self.iconView.tintColor = self.selected ? base : [base colorWithAlphaComponent:0.68];
    self.titleLabel.textColor = self.selected ? base : [base colorWithAlphaComponent:0.78];

    for (UIView *view in @[ self.iconView, self.titleLabel ]) {
        view.layer.shadowColor = UIColor.blackColor.CGColor;
        view.layer.shadowOpacity = 0.45;
        view.layer.shadowRadius = 2.0;
        view.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    }
}

@end

#pragma mark - 偏好

static BOOL DKDemoEnabled(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:kDKDemoEnabledKey];
    return value ? [value boolValue] : YES;
}

static DKDemoGlassPreset DKDemoPreset(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:kDKDemoPresetKey] == nil) return DKDemoGlassPresetFrosted;
    return (DKDemoGlassPreset)[defaults integerForKey:kDKDemoPresetKey];
}

/// 底栏底边距屏幕底的距离，按内容类型分开记：
/// 图文帖底部多一条输入/切换条，需要比普通视频再高一点（用户实测 20 vs 18）。
static NSString *const kDKDemoGapVideoKey   = @"DKDemoGlassGapVideo";
static NSString *const kDKDemoGapGalleryKey = @"DKDemoGlassGapGallery";

/// 图文帖判定：屏幕上出现「图文」标记（作者名旁边那个小标签）。
/// 比找进度条可靠——进度条会淡出，标签一直在。
/// 结果缓存 0.5s：拖动时每帧都会调用，不能每次都遍历整棵视图树。
static BOOL DKDemoScanGallery(void) {
    UIWindow *window = DKDemoKeyWindow();
    if (!window) return NO;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    NSUInteger budget = 3000;
    while (stack.count > 0 && budget-- > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:UILabel.class]) {
            UILabel *label = (UILabel *)view;
            if (!label.hidden && label.alpha > 0.05 && [label.text isEqualToString:@"图文"]) {
                return YES;
            }
        }
        for (UIView *sub in view.subviews) [stack addObject:sub];
    }
    return NO;
}

static BOOL DKDemoIsGalleryPage(void) {
    static BOOL cached = NO;
    static NSTimeInterval cachedAt = 0.0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - cachedAt < 1.5) return cached;
    cached = DKDemoScanGallery();
    cachedAt = now;
    return cached;
}

static CGFloat DKDemoGap(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id video = [defaults objectForKey:kDKDemoGapVideoKey];
    id gallery = [defaults objectForKey:kDKDemoGapGalleryKey];
    // 两个键都没设过 → 结果必然是 0。先短路，免得为了选哪个键去遍历整棵视图树。
    if (!video && !gallery) return 0.0;
    id value = DKDemoIsGalleryPage() ? gallery : video;
    return value ? [value doubleValue] : 0.0;   // 0 = 原位（按底栏的位置摆）
}

/// 窗口宿主下实际生效的距底值。0 表示「默认贴底」，即安全区上方 8pt。
static CGFloat DKDemoResolvedGap(UIView *host) {
    CGFloat gap = DKDemoGap();
    if (gap > 0.0) return gap;
    return host.safeAreaInsets.bottom + 8.0;
}

static void DKDemoSetGap(CGFloat gap) {
    BOOL gallery = DKDemoIsGalleryPage();
    NSString *key = gallery ? kDKDemoGapGalleryKey : kDKDemoGapVideoKey;
    [NSUserDefaults.standardUserDefaults setDouble:MAX(0.0, MIN(gap, 200.0)) forKey:key];
}

static NSString *DKDemoPresetName(DKDemoGlassPreset preset) {
    switch (preset) {
        case DKDemoGlassPresetThin: return @"清透";
        case DKDemoGlassPresetChrome: return @"厚雾";
        case DKDemoGlassPresetFrosted:
        default: return @"磨砂";
    }
}

/// 外观：抖音会把 window.overrideUserInterfaceStyle 钉成浅色，所以优先用 override。
static UIUserInterfaceStyle DKDemoStyle(UIView *view) {
    UIUserInterfaceStyle style = view.window.overrideUserInterfaceStyle;
    if (style != UIUserInterfaceStyleUnspecified) return style;
    style = view.traitCollection.userInterfaceStyle;
    return style == UIUserInterfaceStyleUnspecified ? UIUserInterfaceStyleLight : style;
}

#pragma mark - 读原生按钮

static BOOL DKDemoButtonType(id button, long long *outType) {
    @try {
        id value = [button valueForKey:@"type"];
        if ([value respondsToSelector:@selector(longLongValue)]) {
            if (outType) *outType = [value longLongValue];
            return YES;
        }
    } @catch (__unused NSException *exception) {
    }
    return NO;
}

static UIImage *DKDemoButtonIcon(id button) {
    @try {
        id imageView = nil;
        @try { imageView = [button valueForKey:@"aweImageView"]; } @catch (__unused NSException *e) {}
        if (![imageView isKindOfClass:UIImageView.class]) {
            @try { imageView = [button valueForKey:@"buttonImageView"]; } @catch (__unused NSException *e) {}
        }
        if ([imageView isKindOfClass:UIImageView.class] && ((UIImageView *)imageView).image) {
            return ((UIImageView *)imageView).image;
        }
    } @catch (__unused NSException *exception) {
    }

    if ([button isKindOfClass:UIButton.class]) {
        UIImage *image = [(UIButton *)button imageForState:UIControlStateNormal];
        if (image) return image;
    }
    return nil;
}

static NSString *DKDemoButtonTitle(id button) {
    @try {
        id label = nil;
        @try { label = [button valueForKey:@"label"]; } @catch (__unused NSException *e) {}
        if (![label isKindOfClass:UILabel.class]) {
            @try { label = [button valueForKey:@"buttonLabel"]; } @catch (__unused NSException *e) {}
        }
        if ([label isKindOfClass:UILabel.class]) {
            NSString *text = ((UILabel *)label).text;
            if (text.length > 0) return text;
        }
    } @catch (__unused NSException *exception) {
    }

    if ([button isKindOfClass:UIButton.class]) {
        NSString *title = [(UIButton *)button titleForState:UIControlStateNormal];
        if (title.length > 0) return title;
    }
    return nil;
}

static BOOL DKDemoButtonSelected(id button) {
    if ([button respondsToSelector:@selector(isSelected)]) return [button isSelected];
    return NO;
}

/// 原生按钮数组。优先读 KVC 的 tabBarButtons（抖音的私有数组），失败再扫子视图里的 UIControl。
static NSArray *DKDemoNativeButtons(AWENormalModeTabBar *bar) {
    @try {
        id value = [bar valueForKey:@"tabBarButtons"];
        if ([value isKindOfClass:NSArray.class] && ((NSArray *)value).count > 0) return (NSArray *)value;
    } @catch (__unused NSException *exception) {
    }

    NSMutableArray *candidates = [NSMutableArray array];
    for (UIView *sub in bar.subviews) {
        if ([sub isKindOfClass:DKDemoGlassCapsule.class]) continue;
        if ([sub isKindOfClass:UIControl.class]) [candidates addObject:sub];
    }
    return candidates;
}

static NSString *DKDemoSignature(NSArray *buttons) {
    NSMutableString *signature = [NSMutableString string];
    for (id button in buttons) {
        long long type = -1;
        DKDemoButtonType(button, &type);
        [signature appendFormat:@"%@|%@|%lld;",
            NSStringFromClass([button class]), DKDemoButtonTitle(button) ?: @"", type];
    }
    return signature;
}

#pragma mark - 切页转发

// 抖音的切页不走 UIControl 的 target-action——实测 sendActionsForControlEvents: 是空转，
// 底栏看着有反馈，页面不换。DYKiller 在 iOS 26 上验证过的做法是直接调底栏控制器的私有回调，
// 连手势对象一起回传，40.7.0 的二进制里是同一套方法，这里照抄。
static NSString *const kDKDemoTabSelectSelector = @"tabBarButtonDidTouchUpInside:gestureRecognizer:";
static NSString *const kDKDemoPlusClickSelector = @"plusTabBarButtonDidClick:";

static UITabBarController *DKDemoControllerForView(UIView *view) {
    for (UIResponder *responder = view.nextResponder; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UITabBarController.class]) return (UITabBarController *)responder;
    }
    return nil;
}

static UITabBarController *DKDemoFindTabBarController(UIViewController *root) {
    if (!root) return nil;
    if ([root isKindOfClass:UITabBarController.class]) return (UITabBarController *)root;
    for (UIViewController *child in root.childViewControllers) {
        UITabBarController *found = DKDemoFindTabBarController(child);
        if (found) return found;
    }
    if (root.presentedViewController) return DKDemoFindTabBarController(root.presentedViewController);
    return nil;
}

static UITabBarController *DKDemoTabBarControllerFor(id native) {
    UITabBarController *controller = nil;
    if ([native isKindOfClass:UIView.class]) controller = DKDemoControllerForView((UIView *)native);
    if (!controller) controller = DKDemoFindTabBarController(DKDemoKeyWindow().rootViewController);
    return controller;
}

/// 返回 YES 表示已经走抖音自己的回调。
static BOOL DKDemoForwardSelect(id native) {
    if (![native isKindOfClass:UIView.class]) return NO;

    UITabBarController *controller = DKDemoTabBarControllerFor(native);
    SEL selector = NSSelectorFromString(kDKDemoTabSelectSelector);
    if (!controller || ![controller respondsToSelector:selector]) return NO;

    id gesture = nil;
    @try { gesture = [native valueForKey:@"singleTapGes"]; } @catch (__unused NSException *exception) {}
    ((void (*)(id, SEL, id, id))objc_msgSend)(controller, selector, native, gesture);
    return YES;
}

static BOOL DKDemoForwardPlus(id native) {
    UITabBarController *controller = DKDemoTabBarControllerFor(native);
    SEL selector = NSSelectorFromString(kDKDemoPlusClickSelector);
    if (!controller || ![controller respondsToSelector:selector]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, native);
    return YES;
}

#pragma mark - 原生视图遮蔽

static void DKDemoHideNative(AWENormalModeTabBar *bar) {
    for (UIView *sub in bar.subviews) {
        if ([sub isKindOfClass:DKDemoGlassCapsule.class]) continue;
        if (objc_getAssociatedObject(sub, &kDKDemoOriginalAlphaKey) == nil) {
            objc_setAssociatedObject(sub, &kDKDemoOriginalAlphaKey, @(sub.alpha),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        sub.alpha = 0.0;
    }

    if (objc_getAssociatedObject(bar, &kDKDemoOriginalColorKey) == nil) {
        objc_setAssociatedObject(bar, &kDKDemoOriginalColorKey,
                                 bar.backgroundColor ?: NSNull.null,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    bar.backgroundColor = UIColor.clearColor;
}

static void DKDemoRestoreNative(AWENormalModeTabBar *bar) {
    for (UIView *sub in bar.subviews) {
        if ([sub isKindOfClass:DKDemoGlassCapsule.class]) continue;
        NSNumber *alpha = objc_getAssociatedObject(sub, &kDKDemoOriginalAlphaKey);
        if (alpha) {
            sub.alpha = alpha.doubleValue;
            objc_setAssociatedObject(sub, &kDKDemoOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }

    id color = objc_getAssociatedObject(bar, &kDKDemoOriginalColorKey);
    if (color) {
        bar.backgroundColor = (color == NSNull.null) ? nil : color;
        objc_setAssociatedObject(bar, &kDKDemoOriginalColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - 菜单

/// 当前 key window。抖音会把底栏、播放器分散在多个 window 里，这里只取最上面那个。
static UIWindow *DKDemoKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}

static UIViewController *DKDemoTopViewController(void) {
    UIWindow *keyWindow = DKDemoKeyWindow();
    UIViewController *controller = keyWindow.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    return controller;
}

static void DKDemoScanViews(UIView *root, NSMutableArray<NSString *> *out, NSInteger depth) {
    if (!root || depth > 14) return;
    NSString *name = NSStringFromClass(root.class);
    if ([name containsString:@"TabBar"]) {
        [out addObject:[NSString stringWithFormat:@"%@@%ld", name, (long)depth]];
    }
    for (UIView *sub in root.subviews) DKDemoScanViews(sub, out, depth + 1);
}

static NSString *DKDemoBuildScanReport(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            DKDemoScanViews(window, names, 0);
        }
    }
    if (names.count == 0) return @"未发现任何 TabBar 类视图（底栏可能还没建）";
    return [names componentsJoinedByString:@"\n"];
}

#pragma mark - 控制目标

@interface DKDemoControl : NSObject
- (void)handleItemTap:(DKDemoItemView *)item;
- (void)handlePlusTap;
- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
- (void)showMenu;
- (void)hideForComparison;
- (void)showToast:(NSString *)text;
@end

@implementation DKDemoControl

- (void)handleItemTap:(DKDemoItemView *)item {
    NSInteger index = item.tag;
    if (index < 0 || index >= (NSInteger)gNativeButtons.count) {
        NSLog(@"[DKDemoGlass] 占位项被点击，无原生按钮可转发（index=%ld）", (long)index);
        [self showToast:@"占位项：没读到原生按钮"];
        return;
    }

    id native = gNativeButtons[(NSUInteger)index];
    if (DKDemoForwardSelect(native)) {
        NSLog(@"[DKDemoGlass] 已切页 -> %@", NSStringFromClass([native class]));
        return;
    }

    if ([native isKindOfClass:UIControl.class]) {
        [(UIControl *)native sendActionsForControlEvents:UIControlEventTouchUpInside];
        NSLog(@"[DKDemoGlass] 切页回退 sendActions -> %@", NSStringFromClass([native class]));
        [self showToast:@"切页走了回退路径，可能无效"];
        return;
    }

    NSLog(@"[DKDemoGlass] 无法转发：%@", NSStringFromClass([native class]));
    [self showToast:@"切页失败：找不到可用回调"];
}

- (void)handlePlusTap {
    UIControl *native = gPlusNativeButton;
    if (!native) {
        NSLog(@"[DKDemoGlass] 没有找到拍摄按钮，圆键为占位");
        [self showToast:@"拍摄键：没读到原生按钮"];
        return;
    }

    if (DKDemoForwardPlus(native)) {
        NSLog(@"[DKDemoGlass] 已调用拍摄回调 -> %@", NSStringFromClass([native class]));
        return;
    }

    [native sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSLog(@"[DKDemoGlass] 拍摄回退 sendActions -> %@", NSStringFromClass([native class]));
    [self showToast:@"拍摄走了回退路径，可能无效"];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self showMenu];
}

/// 上下拖动底栏改位置：向上拖 = 距底变大（往上走），松手后位置落盘。
- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *view = gesture.view;
    if (!view) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        gPanBaseGap = gLastGap;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:view.window ?: view];
        DKDemoSetGap(gPanBaseGap - translation.y);
        if (gBar) DKDemoSync(gBar);
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled) {
        [gesture setTranslation:CGPointZero inView:view.window ?: view];
        [self showToast:[NSString stringWithFormat:@"距底 %.0fpt", DKDemoGap()]];
    }
}

- (void)showMenu {
    UIViewController *presenter = DKDemoTopViewController();
    if (!presenter) return;

    NSString *message = [NSString stringWithFormat:@"材质：%@\n%@\n\n扫描：\n%@",
                         DKDemoPresetName(DKDemoPreset()),
                         gDiagnostics ?: @"尚未同步",
                         gScanReport ?: @"尚未扫描"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"DKDemoGlass"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    // 宿主放第一条：这是唯一能决定"看不看得见"的开关，别让它排在滚动区外面。
    [alert addAction:[UIAlertAction actionWithTitle:(gHostWindow ? @"宿主：窗口（点此改为底栏）"
                                                                : @"宿主：底栏（点此改为窗口）")
                                            style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        gHostWindow = !gHostWindow;
        if (gBar) DKDemoSync(gBar);
        [weakSelf showToast:(gHostWindow ? @"宿主：窗口" : @"宿主：底栏")];
    }]];

    // 位置：默认按底栏原位摆放（原版策略）；拖动可微调，这里只提供复位。
    BOOL galleryNow = DKDemoIsGalleryPage();
    CGFloat currentGap = DKDemoGap();
    NSString *gapText;
    if (currentGap > 0.0) {
        gapText = [NSString stringWithFormat:@"距底 %.0fpt", currentGap];
    } else {
        // 窗口宿主下 0 不是「原位」而是安全区上方 8pt；只有挂底栏时才是真原位。
        gapText = gHostWindow ? @"默认贴底" : @"跟随底栏";
    }
    [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"位置：%@ %@（拖动可调）",
                                                      galleryNow ? @"图文" : @"视频", gapText]
                                            style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        DKDemoSetGap(0.0);
        if (gBar) DKDemoSync(gBar);
        [weakSelf showToast:@"位置已复位"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"切换材质" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSInteger next = (DKDemoPreset() + 1) % 3;
        [NSUserDefaults.standardUserDefaults setInteger:next forKey:kDKDemoPresetKey];
        if (gBar) DKDemoSync(gBar);
        [weakSelf showToast:[NSString stringWithFormat:@"材质：%@", DKDemoPresetName((DKDemoGlassPreset)next)]];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"隐藏 3 秒（对比原生）" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf hideForComparison];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"重新扫描底栏" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        gScanReport = DKDemoBuildScanReport();
        NSLog(@"[DKDemoGlass] 扫描结果：\n%@", gScanReport);
        [weakSelf showToast:@"已扫描，详情见日志"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:(gFloatButtonHidden ? @"显示浮标" : @"隐藏浮标")
                                            style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        // 胶囊没建出来时（钩子没命中 / 类名变了），浮标是唯一的菜单入口。
        // 这时候允许隐藏等于把自己锁在门外，直接拒绝。
        if (!gFloatButtonHidden && !gCapsule) {
            [weakSelf showToast:@"胶囊未建出，浮标是唯一入口，不能隐藏"];
            return;
        }
        gFloatButtonHidden = !gFloatButtonHidden;
        DKDemoUpdateFloatButton(DKDemoKeyWindow());
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.sourceView = gCapsule ?: presenter.view;
    alert.popoverPresentationController.sourceRect = gCapsule
        ? CGRectMake(CGRectGetMidX(gCapsule.bounds), 0.0, 1.0, 1.0)
        : CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1.0, 1.0);
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)hideForComparison {
    DKDemoGlassCapsule *capsule = gCapsule;
    DKDemoGlassCapsule *plusKey = gPlusKey;
    AWENormalModeTabBar *bar = gBar;
    if (!capsule) return;

    // 先把窗口期立起来，再还原原生：否则 layoutSubviews 一触发，
    // DKDemoSync 会立刻把原生重新藏回去，这 3 秒里两边都看不见。
    gComparisonUntil = [NSDate timeIntervalSinceReferenceDate] + 3.0;
    capsule.hidden = YES;
    plusKey.hidden = YES;
    DKDemoRestoreNative(bar);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gComparisonUntil = 0.0;
        capsule.hidden = NO;
        plusKey.hidden = NO;
        if (bar) DKDemoSync(bar);
    });
}

- (void)showToast:(NSString *)text {
    UIViewController *presenter = DKDemoTopViewController();
    if (!presenter) return;

    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectZero];
    toast.text = text;
    toast.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightMedium];
    toast.textColor = UIColor.whiteColor;
    toast.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.layer.cornerRadius = 16.0;
    toast.layer.cornerCurve = kCACornerCurveContinuous;
    toast.clipsToBounds = YES;
    [toast sizeToFit];
    CGRect frame = toast.frame;
    frame.size.width += 28.0;
    frame.size.height = 32.0;
    frame.origin.x = (presenter.view.bounds.size.width - frame.size.width) * 0.5;
    frame.origin.y = presenter.view.bounds.size.height - 160.0;
    toast.frame = frame;
    toast.alpha = 0.0;
    [presenter.view addSubview:toast];

    [UIView animateWithDuration:0.18 animations:^{ toast.alpha = 1.0; } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.3 delay:1.2 options:UIViewAnimationOptionCurveEaseIn animations:^{
            toast.alpha = 0.0;
        } completion:^(__unused BOOL done) {
            [toast removeFromSuperview];
        }];
    }];
}

@end

static DKDemoControl *gControl = nil;
static DKDemoControl *DKDemoControlShared(void) {
    if (!gControl) gControl = [[DKDemoControl alloc] init];
    return gControl;
}

/// 浮标：底栏接管失败时，这是唯一能看到诊断信息的入口（TrollStore 环境默认没有 SSH）。
static void DKDemoUpdateFloatButton(UIWindow *window) {
    if (!window || !DKDemoEnabled() || gFloatButtonHidden) {
        [gFloatButton removeFromSuperview];
        return;
    }

    if (!gFloatButton) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        button.layer.cornerRadius = 20.0;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.titleLabel.font = [UIFont boldSystemFontOfSize:12.0];
        [button setTitle:@"DK" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        [button addTarget:DKDemoControlShared()
                   action:@selector(showMenu)
         forControlEvents:UIControlEventTouchUpInside];
        gFloatButton = button;
    }

    if (gFloatButton.superview != window) [window addSubview:gFloatButton];

    CGFloat side = 40.0;
    // 浮标固定在胶囊上方 50pt，跟着底栏一起移动。gLastGap 是上一次布局实际用的距底值，
    // 底栏宿主时不会更新，退回到 42（安全区 34 + 8）也能落在合理位置。
    CGFloat gap = gLastGap > 0.0 ? gLastGap : 42.0;
    CGFloat bottomGap = gap + kDKDemoCapsuleHeight + 50.0;
    gFloatButton.frame = CGRectMake(window.bounds.size.width - side - 6.0,
                                    window.bounds.size.height - bottomGap, side, side);

    // 弹窗（比如我们自己的菜单）在的时候不要抢到最上面，否则会盖住弹窗。
    if (!window.rootViewController.presentedViewController) {
        [window bringSubviewToFront:gFloatButton];
    }
}

#pragma mark - 构建与布局

static UIImage *DKDemoTemplateImage(UIImage *image) {
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *DKDemoSymbol(NSString *name) {
    if (@available(iOS 13.0, *)) {
        return DKDemoTemplateImage([UIImage systemImageNamed:name]);
    }
    return nil;
}

static DKDemoItemView *DKDemoMakeItem(NSString *title, UIImage *icon, NSInteger index, BOOL selected) {
    DKDemoItemView *item = [[DKDemoItemView alloc] initWithFrame:CGRectZero];
    item.tag = index;
    item.titleLabel.text = title;
    item.iconView.image = icon ? DKDemoTemplateImage(icon) : nil;
    item.selected = selected;
    [item applyTint];
    [item addTarget:DKDemoControlShared()
             action:@selector(handleItemTap:)
   forControlEvents:UIControlEventTouchUpInside];
    return item;
}

static NSArray<NSString *> *DKDemoFallbackTitles(void) {
    return @[ @"首页", @"朋友", @"消息", @"我" ];
}

static NSArray<NSString *> *DKDemoFallbackSymbols(void) {
    return @[ @"house.fill", @"person.2.fill", @"bell.fill", @"person.crop.square.fill" ];
}

/// 切页后同步选中态。选中态不在签名里（否则每切一次都要重建整块胶囊），单独刷。
static void DKDemoRefreshSelection(void) {
    for (UIControl *control in gItems) {
        if (![control isKindOfClass:DKDemoItemView.class]) continue;
        DKDemoItemView *item = (DKDemoItemView *)control;
        NSInteger index = item.tag;
        if (index < 0 || index >= (NSInteger)gNativeButtons.count) continue;

        id native = gNativeButtons[(NSUInteger)index];
        BOOL selected = DKDemoButtonSelected(native);
        if (item.selected == selected) continue;

        item.selected = selected;
        UIImage *icon = DKDemoButtonIcon(native);
        if (icon) item.iconView.image = DKDemoTemplateImage(icon);
    }
}

/// 直接建到最终宿主上。以前是先 addSubview 到 bar 再 reparent——
/// 而 rebuild 常常发生在 bar 自己的 layoutSubviews 里，等于在布局过程中改它的子树，
/// 容易多触发一轮布局。现在窗口宿主下根本不动 bar 的子视图。
static void DKDemoRebuild(UIView *host, NSArray *buttons, NSString *signature) {
    [gCapsule removeFromSuperview];
    [gPlusKey removeFromSuperview];
    gCapsule = nil;
    gPlusKey = nil;
    gItems = [NSMutableArray array];
    gNativeButtons = buttons ?: @[];
    gPlusNativeButton = nil;

    for (id button in gNativeButtons) {
        long long type = -1;
        if (DKDemoButtonType(button, &type) && type == kDKDemoPlusButtonType
            && [button isKindOfClass:UIControl.class]) {
            gPlusNativeButton = (UIControl *)button;
            break;
        }
    }

    gCapsule = [[DKDemoGlassCapsule alloc] initWithFrame:CGRectZero];
    gCapsule.preset = DKDemoPreset();
    [host addSubview:gCapsule];

    gPlusKey = [[DKDemoGlassCapsule alloc] initWithFrame:CGRectZero];
    gPlusKey.preset = DKDemoPreset();
    gPlusKey.capsuleCornerRadius = kDKDemoPlusKeySide * 0.5;
    [host addSubview:gPlusKey];

    if (gNativeButtons.count == 0) {
        // 没读到原生按钮：只放占位项，材质和几何仍然可以评估。
        NSArray *titles = DKDemoFallbackTitles();
        NSArray *symbols = DKDemoFallbackSymbols();
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIImage *icon = DKDemoSymbol(symbols[i]);
            DKDemoItemView *item = DKDemoMakeItem(titles[i], icon, -1, i == 0);
            [gCapsule.contentView addSubview:item];
            [gItems addObject:item];
        }
    } else {
        // tag 存的是它在原生数组里的下标——拍摄按钮可能夹在中间，不能用自己的计数。
        NSArray<NSString *> *fallbackTitles = DKDemoFallbackTitles();
        NSArray<NSString *> *fallbackSymbols = DKDemoFallbackSymbols();
        NSUInteger slot = 0;
        for (NSUInteger i = 0; i < gNativeButtons.count; i++) {
            id button = gNativeButtons[i];
            long long type = -1;
            if (DKDemoButtonType(button, &type) && type == kDKDemoPlusButtonType) continue;
            if (![button isKindOfClass:UIView.class]) continue;

            // 标题读不到时按位置兜底：抖音这类按钮的 label 有时是懒建的，
            // 没有兜底的话胶囊里就只剩图标，看不出是哪个 tab。
            NSString *title = DKDemoButtonTitle(button);
            if (title.length == 0 && slot < fallbackTitles.count) title = fallbackTitles[slot];

            UIImage *icon = DKDemoButtonIcon(button);
            if (!icon && slot < fallbackSymbols.count) icon = DKDemoSymbol(fallbackSymbols[slot]);

            DKDemoItemView *item = DKDemoMakeItem(title, icon, (NSInteger)i, DKDemoButtonSelected(button));
            [gCapsule.contentView addSubview:item];
            [gItems addObject:item];
            slot++;
        }
    }

    // 拍摄圆键：参考图是圆角方形加号，优先用它；读不到再退回抖音自己的图标。
    UIImage *plusIcon = DKDemoSymbol(@"plus.square");
    if (!plusIcon && gPlusNativeButton) plusIcon = DKDemoButtonIcon(gPlusNativeButton);
    if (!plusIcon) plusIcon = DKDemoSymbol(@"camera.fill");
    DKDemoItemView *plusItem = DKDemoMakeItem(nil, plusIcon, -1, NO);
    [plusItem addTarget:DKDemoControlShared()
                 action:@selector(handlePlusTap)
       forControlEvents:UIControlEventTouchUpInside];
    [gPlusKey.contentView addSubview:plusItem];
    [gItems addObject:plusItem];

    // 长按出菜单：挂在两块胶囊上，避免和按钮点击抢事件。
    UILongPressGestureRecognizer *capsulePress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:DKDemoControlShared()
                                                      action:@selector(handleLongPress:)];
    [gCapsule addGestureRecognizer:capsulePress];

    UILongPressGestureRecognizer *plusPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:DKDemoControlShared()
                                                      action:@selector(handleLongPress:)];
    [gPlusKey addGestureRecognizer:plusPress];

    // 上下拖动调位置：UIPan 只在移动后才开始，不会抢走点击。
    UIPanGestureRecognizer *capsulePan =
        [[UIPanGestureRecognizer alloc] initWithTarget:DKDemoControlShared()
                                                action:@selector(handlePan:)];
    [gCapsule addGestureRecognizer:capsulePan];

    UIPanGestureRecognizer *plusPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:DKDemoControlShared()
                                                action:@selector(handlePan:)];
    [gPlusKey addGestureRecognizer:plusPan];

    gSignature = [signature copy];
}

/// 胶囊的宿主：默认挂 key window。挂底栏会被 DYYY 全屏 / 抖音换页一起带走。
static UIView *DKDemoHost(AWENormalModeTabBar *bar) {
    if (!gHostWindow) return bar;
    // 优先 key window：那是浮标所在的窗口，已经证明它能盖在视频上面。
    UIWindow *window = DKDemoKeyWindow();
    if (!window) window = bar.window;
    return window ?: bar;
}

static void DKDemoReparent(UIView *host) {
    if (!gCapsule || !gPlusKey || !host) return;

    if (gCapsule.superview != host) {
        [gCapsule removeFromSuperview];
        [host addSubview:gCapsule];
    }
    if (gPlusKey.superview != host) {
        [gPlusKey removeFromSuperview];
        [host addSubview:gPlusKey];
    }

    // 圆键永远压在胶囊之上；但弹窗（我们的菜单）在的时候别抢，否则会盖住菜单。
    UIViewController *presented = host.window.rootViewController.presentedViewController;
    if (!presented) {
        [host bringSubviewToFront:gCapsule];
        [host bringSubviewToFront:gPlusKey];
    }
}

/// 把抖音的进度条整体顶到胶囊上方：找进度条容器，把它的位移改成「刚好在胶囊上面」。
///
/// 两个关键点：
///  · 容器一旦定位就缓存下来（弱引用），后续布局直接复用，不再每帧遍历整棵视图树；
///  · 位移必须可逆。任何一条不再需要避让的路径（切回底栏宿主、离开视频页、退场）
///    都要把容器还原成它自己的 transform，否则进度条会永久悬在半空。
static __weak UIView *gProgressContainer;
static CGAffineTransform gProgressBaseTransform = CGAffineTransformIdentity;
static CGFloat gProgressShift = 0.0;
static Class gProgressSliderClass = Nil;
static NSTimeInterval gProgressScanAt = 0.0;

/// 把容器放回它自己的 transform，但保留缓存（下一次布局还能直接命中）。
static void DKDemoClearProgressShift(void) {
    UIView *container = gProgressContainer;
    if (container && !CGAffineTransformEqualToTransform(container.transform, gProgressBaseTransform)) {
        container.transform = gProgressBaseTransform;
    }
    gProgressShift = 0.0;
}

/// 彻底忘掉：切宿主、退场、找不到进度条时用。
static void DKDemoResetProgressShift(void) {
    DKDemoClearProgressShift();
    gProgressContainer = nil;
    gProgressBaseTransform = CGAffineTransformIdentity;
}

static BOOL DKDemoIsProgressSlider(UIView *view, UIWindow *window, CGRect screenBounds) {
    if (view.hidden || view.alpha <= 0.05) return NO;

    // 类名匹配成功一次后就缓存 Class，后面全是 isKindOfClass:，
    // 不用再为每个视图拼一遍 NSStringFromClass——那才是这条路径上最贵的一步。
    BOOL matched = gProgressSliderClass
        ? [view isKindOfClass:gProgressSliderClass]
        : [NSStringFromClass(view.class) containsString:@"ProgressSlider"];
    if (!matched) return NO;

    CGRect frame = [view convertRect:view.bounds toView:window];
    return frame.size.width > screenBounds.size.width * 0.4 &&
           frame.size.height > 0.0 && frame.size.height < 40.0 &&
           frame.origin.y > screenBounds.size.height * 0.5;
}

static UIView *DKDemoProgressContainer(UIWindow *window, CGRect screenBounds) {
    UIView *cached = gProgressContainer;
    if (cached && cached.window == window && !cached.hidden && cached.alpha > 0.05) return cached;

    // 刚扫过没找到就别再扫：个人页这类没有进度条的页面会每帧调到这里。
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gProgressScanAt < 0.5) return nil;
    gProgressScanAt = now;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    NSUInteger budget = 3000;
    UIView *slider = nil;
    while (stack.count > 0 && budget-- > 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (DKDemoIsProgressSlider(view, window, screenBounds)) {
            slider = view;
            break;
        }
        for (UIView *sub in view.subviews) [stack addObject:sub];
    }
    if (!slider) {
        // 缓存下来的类可能只覆盖信息流；换到直播等页面时进度条是另一个类。
        // 清掉缓存，下一轮重新用类名扫，让它自愈。
        gProgressSliderClass = Nil;
        return nil;
    }
    if (!gProgressSliderClass) gProgressSliderClass = [slider class];
    return slider.superview ?: slider;
}

static CGFloat DKDemoLiftProgress(CGFloat capsuleTop, CGRect screenBounds) {
    UIWindow *window = DKDemoKeyWindow();
    if (!window) {
        DKDemoResetProgressShift();
        return 0.0;
    }

    UIView *container = DKDemoProgressContainer(window, screenBounds);
    if (!container) {
        DKDemoResetProgressShift();
        return 0.0;
    }

    if (gProgressContainer != container) {
        DKDemoResetProgressShift();
        gProgressContainer = container;
        gProgressBaseTransform = container.transform;
    }

    // 用「未位移的原始矩形」算重叠：先把 transform 换成基准再 convertRect，
    // 否则读到的是上一次的位移，overlap 会逐帧累积，界面自己往上爬。
    CGAffineTransform applied = container.transform;
    container.transform = gProgressBaseTransform;
    CGRect base = [container convertRect:container.bounds toView:window];
    container.transform = applied;

    if (base.size.height > 80.0) {   // 太大，多半是整层视频 HUD，不碰
        DKDemoResetProgressShift();
        return 0.0;
    }

    CGFloat overlap = CGRectGetMaxY(base) - (capsuleTop - 4.0);
    if (overlap <= 0.0) {
        DKDemoClearProgressShift();
        return 0.0;
    }

    container.transform = CGAffineTransformTranslate(gProgressBaseTransform, 0.0, -overlap);
    gProgressShift = overlap;
    return overlap;
}

static void DKDemoLayoutInView(UIView *host) {
    if (!gCapsule || !gPlusKey || !host) return;

    CGRect bounds = host.bounds;
    CGFloat bottomInset = host.safeAreaInsets.bottom;
    CGFloat margin = 2.0;

    CGRect barRect = CGRectZero;
    if (gBar && gBar.superview) {
        barRect = [gBar convertRect:gBar.bounds toView:host];
    }
    BOOL windowHost = [host isKindOfClass:UIWindow.class];

    // 参考图的形态：窗口宿主用完整 62pt 胶囊；挂底栏时才收进底栏内容区（约 45pt）。
    CGFloat height = kDKDemoCapsuleHeight;
    if (!windowHost && barRect.size.height > 40.0) {
        height = MAX(barRect.size.height - bottomInset - margin * 2.0, 36.0);
        height = MIN(height, kDKDemoCapsuleHeight);
    }

    CGFloat y;
    if (windowHost) {
        gLastGap = DKDemoResolvedGap(host);
        y = MAX(bounds.size.height - gLastGap - height, 0.0);
    } else {
        y = MAX(bounds.size.height - bottomInset - margin - height, 0.0);
    }

    CGFloat plusSide = MIN(kDKDemoPlusKeySide, height);
    CGFloat plusX = bounds.size.width - kDKDemoEdgeInset - plusSide;

    gPlusKey.frame = CGRectMake(plusX, y + (height - plusSide) * 0.5, plusSide, plusSide);
    gPlusKey.capsuleCornerRadius = plusSide * 0.5;

    CGFloat capsuleWidth = plusX - kDKDemoPlusGap - kDKDemoEdgeInset;
    capsuleWidth = MAX(capsuleWidth, 80.0);
    gCapsule.frame = CGRectMake(kDKDemoEdgeInset, y, capsuleWidth, height);
    gCapsule.capsuleCornerRadius = height * 0.5;

    // 圆键里的那颗图标自己撑满。用圆键的 bounds 而不是 contentView.bounds：
    // 此刻 contentView 还没走过这一轮布局，尺寸可能仍是零。
    for (UIView *sub in gPlusKey.contentView.subviews) {
        sub.frame = gPlusKey.bounds;
    }
    [gPlusKey setNeedsLayout];

    // 窗口宿主：胶囊是完整 62pt，会盖住进度条，所以反过来把进度条顶上去。
    // 底栏宿主不需要避让——但必须把之前留下的位移还原，否则切过来进度条还悬着。
    if (windowHost) {
        gProgressShift = DKDemoLiftProgress(y, bounds);
    } else {
        DKDemoResetProgressShift();
    }

    NSUInteger count = gItems.count;
    NSUInteger itemCount = count > 0 ? count - 1 : 0;   // 最后一个是圆键里的图标
    if (itemCount == 0) return;

    CGFloat itemWidth = capsuleWidth / (CGFloat)itemCount;
    for (NSUInteger i = 0; i < itemCount; i++) {
        gItems[i].frame = CGRectMake((CGFloat)i * itemWidth, 0.0, itemWidth, height);
    }

    [gCapsule setNeedsLayout];
}

static void DKDemoTeardown(AWENormalModeTabBar *bar) {
    if (bar) DKDemoRestoreNative(bar);
    [gCapsule removeFromSuperview];
    [gPlusKey removeFromSuperview];
    [gFloatButton removeFromSuperview];
    // 退场也要把进度条放回去，否则关掉插件后视频进度条永远多悬着一段。
    DKDemoResetProgressShift();
    gComparisonUntil = 0.0;
    gCapsule = nil;
    gPlusKey = nil;
    gItems = nil;
    gNativeButtons = nil;
    gPlusNativeButton = nil;
    gSignature = nil;
}

static void DKDemoSync(AWENormalModeTabBar *bar) {
    if (!bar || gSyncing) return;

    gSyncing = YES;
    @try {
        gBar = bar;

        if (!DKDemoEnabled()) {
            DKDemoTeardown(bar);
            return;
        }

        UIView *host = DKDemoHost(bar);

        NSArray *buttons = DKDemoNativeButtons(bar);
        NSString *signature = DKDemoSignature(buttons);
        if (!gCapsule || ![signature isEqualToString:gSignature ?: @""]) {
            DKDemoRebuild(host, buttons, signature);
        }

        // 对比模式下不要又把原生藏回去，否则这 3 秒里胶囊和原生两边都看不见。
        if (!DKDemoComparing()) DKDemoHideNative(bar);

        DKDemoReparent(host);
        DKDemoLayoutInView(host);
        DKDemoRefreshSelection();

        // 材质档位是运行时可切的，不能只在 rebuild 时同步：
        // 菜单里点「切换材质」不会改签名、不会触发 rebuild，只在这里赋值的话等于点了没反应。
        DKDemoGlassPreset preset = DKDemoPreset();
        gCapsule.preset = preset;   // setter 内部用 _appliedPreset 挡住重复重建材质
        gPlusKey.preset = preset;

        UIUserInterfaceStyle style = DKDemoStyle(bar);
        [gCapsule applyStyle:style];
        [gPlusKey applyStyle:style];

        UIWindow *keyWindow = DKDemoKeyWindow();
        DKDemoUpdateFloatButton(keyWindow ?: bar.window);

        CGRect barBounds = bar.bounds;
        NSUInteger mirrored = gItems.count > 0 ? gItems.count - 1 : 0;
        gDiagnostics = [NSString stringWithFormat:
                        @"底栏 %@ %.0f×%.0f 安全区=%.0f 镜像=%lu/%lu\n宿主=%@ 底栏hidden=%d alpha=%.2f window=%d 距底=%.0f 进度条上移=%.0f\n内容=%@",
                        NSStringFromClass(bar.class), barBounds.size.width, barBounds.size.height,
                        bar.safeAreaInsets.bottom,
                        (unsigned long)mirrored, (unsigned long)buttons.count,
                        host == bar ? @"底栏" : NSStringFromClass(host.class),
                        bar.hidden ? 1 : 0, bar.alpha, bar.window ? 1 : 0, gLastGap, gProgressShift,
                        DKDemoIsGalleryPage() ? @"图文" : @"视频"];

        // 几何只在第一次同步时打一行：底栏高度决定胶囊能有多高，这是移植时最先要确认的数。
        static BOOL loggedGeometry = NO;
        if (!loggedGeometry) {
            loggedGeometry = YES;
            NSLog(@"[DKDemoGlass] 首次同步 %@", gDiagnostics);
        }
    } @finally {
        gSyncing = NO;
    }
}

/// 定时兜底：window 尺寸变化、宿主被换掉、胶囊被别的视图挤下去时，把它摆回来。
static void DKDemoUpdateOverlay(void) {
    if (!gBar || !gCapsule || !gPlusKey || gSyncing) return;
    UIView *host = DKDemoHost(gBar);
    if (!host) return;
    // 抖音换页时会重挂背景层，这里补一次遮蔽，别等它下一次 layoutSubviews。
    if (!DKDemoComparing()) DKDemoHideNative(gBar);
    DKDemoReparent(host);
    DKDemoLayoutInView(host);
}

#pragma mark - 钩子

%hook AWENormalModeTabBar

- (void)layoutSubviews {
    %orig;
    DKDemoSync(self);
}

- (void)didMoveToWindow {
    %orig;
    DKDemoSync(self);
}

%end

#pragma mark - 入口

%ctor {
    NSLog(@"[DKDemoGlass] loaded · enabled=%@ · preset=%@",
          DKDemoEnabled() ? @"YES" : @"NO", DKDemoPresetName(DKDemoPreset()));

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gScanReport = DKDemoBuildScanReport();
        NSLog(@"[DKDemoGlass] 底栏类扫描：\n%@", gScanReport);
        DKDemoUpdateFloatButton(DKDemoKeyWindow());
    });

    // 用 common modes 注册：默认模式在滚动 / 拖动时会被停掉，
    // 而这两种场景恰恰是最需要兜底布局的时候。
    NSTimer *watchdog = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
        DKDemoUpdateFloatButton(DKDemoKeyWindow());
        DKDemoUpdateOverlay();
    }];
    [NSRunLoop.mainRunLoop addTimer:watchdog forMode:NSRunLoopCommonModes];
}
