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
#import <objc/runtime.h>

#import "DKDemoGlassCapsule.h"

// 抖音底栏。只声明本插件用到的部分；类不存在时 Logos 会跳过钩子并打日志。
@interface AWENormalModeTabBar : UIView
@end

// 前置声明：菜单与对比逻辑要用到它，而它定义在文件后半段。
static void DKDemoSync(AWENormalModeTabBar *bar);
static void DKDemoUpdateFloatButton(UIWindow *window);

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

#pragma mark - 内容项

/// 胶囊里的一项：图标在上、文字在下；无文字时只居中图标（拍摄圆键就复用这个）。
@interface DKDemoItemView : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
- (void)applyTint;
@end

@implementation DKDemoItemView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.userInteractionEnabled = NO;
    [self addSubview:_iconView];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.8;
    _titleLabel.userInteractionEnabled = NO;
    [self addSubview:_titleLabel];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    // 底栏内容区只有 49pt 时胶囊只有 45pt 高，图标 + 文字（24+3+12=39）刚好塞得下；
    // 再矮就只留图标，避免文字被压扁。
    BOOL showTitle = self.titleLabel.text.length > 0 && height >= 40.0 && width >= 44.0;

    if (showTitle) {
        CGFloat iconSide = 24.0;
        CGFloat gap = 3.0;
        CGFloat labelHeight = 12.0;
        CGFloat total = iconSide + gap + labelHeight;
        CGFloat top = MAX((height - total) * 0.5, 0.0);
        self.iconView.frame = CGRectMake((width - iconSide) * 0.5, top, iconSide, iconSide);
        self.titleLabel.frame = CGRectMake(0.0, top + iconSide + gap, width, labelHeight);
    } else {
        CGFloat iconSide = MIN(28.0, MAX(MIN(width, height) - 8.0, 0.0));
        self.iconView.frame = CGRectMake((width - iconSide) * 0.5, (height - iconSide) * 0.5,
                                         iconSide, iconSide);
        self.titleLabel.frame = CGRectZero;
    }
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self applyTint];
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
    UIColor *base = self.tintColor ?: UIColor.labelColor;
    self.iconView.tintColor = self.selected ? base : [base colorWithAlphaComponent:0.62];
    self.titleLabel.textColor = self.selected ? base : [base colorWithAlphaComponent:0.62];
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
- (void)showMenu;
- (void)hideForComparison;
- (void)showToast:(NSString *)text;
@end

@implementation DKDemoControl

- (void)handleItemTap:(DKDemoItemView *)item {
    NSInteger index = item.tag;
    if (index < 0 || index >= (NSInteger)gNativeButtons.count) {
        NSLog(@"[DKDemoGlass] 占位项被点击，无原生按钮可转发（index=%ld）", (long)index);
        return;
    }
    id native = gNativeButtons[(NSUInteger)index];
    if ([native isKindOfClass:UIControl.class]) {
        [(UIControl *)native sendActionsForControlEvents:UIControlEventTouchUpInside];
        NSLog(@"[DKDemoGlass] 已转发点击 -> %@", NSStringFromClass([native class]));
    } else {
        NSLog(@"[DKDemoGlass] 原生项不是 UIControl：%@", NSStringFromClass([native class]));
    }
}

- (void)handlePlusTap {
    UIControl *native = gPlusNativeButton;
    if (!native) {
        NSLog(@"[DKDemoGlass] 没有找到拍摄按钮，圆键为占位");
        return;
    }
    [native sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSLog(@"[DKDemoGlass] 已转发拍摄点击 -> %@", NSStringFromClass([native class]));
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self showMenu];
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

    capsule.hidden = YES;
    plusKey.hidden = YES;
    DKDemoRestoreNative(bar);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
    gFloatButton.frame = CGRectMake(window.bounds.size.width - side - 6.0,
                                    window.bounds.size.height - 150.0, side, side);

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

static void DKDemoRebuild(AWENormalModeTabBar *bar, NSArray *buttons, NSString *signature) {
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
    [bar addSubview:gCapsule];

    gPlusKey = [[DKDemoGlassCapsule alloc] initWithFrame:CGRectZero];
    gPlusKey.preset = DKDemoPreset();
    gPlusKey.capsuleCornerRadius = kDKDemoPlusKeySide * 0.5;
    [bar addSubview:gPlusKey];

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
        for (NSUInteger i = 0; i < gNativeButtons.count; i++) {
            id button = gNativeButtons[i];
            long long type = -1;
            if (DKDemoButtonType(button, &type) && type == kDKDemoPlusButtonType) continue;
            if (![button isKindOfClass:UIView.class]) continue;

            NSString *title = DKDemoButtonTitle(button);
            UIImage *icon = DKDemoButtonIcon(button);
            DKDemoItemView *item = DKDemoMakeItem(title, icon, (NSInteger)i, DKDemoButtonSelected(button));
            [gCapsule.contentView addSubview:item];
            [gItems addObject:item];
        }
    }

    // 拍摄圆键：图标镜像原生，读不到就用相机占位。
    UIImage *plusIcon = nil;
    if (gPlusNativeButton) plusIcon = DKDemoButtonIcon(gPlusNativeButton);
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

    gSignature = [signature copy];
}

static void DKDemoLayout(AWENormalModeTabBar *bar) {
    if (!gCapsule || !gPlusKey) return;

    CGRect bounds = bar.bounds;
    CGFloat bottomInset = bar.safeAreaInsets.bottom;

    // 底栏的真实高度 = 内容区 + home indicator 安全区。iPhone 13 Pro Max 上典型是 49 + 34 = 83，
    // 胶囊只能活在内容区里，所以高度跟着内容区走（约 45pt），不硬写 62——硬写会顶出底栏被裁。
    CGFloat available = MAX(bounds.size.height - bottomInset, 0.0);
    CGFloat margin = 2.0;
    CGFloat maxHeight = MAX(available - margin * 2.0, 0.0);
    CGFloat height = MIN(kDKDemoCapsuleHeight, maxHeight);
    if (height < 36.0 && available > 0.0) height = MIN(available, 36.0);
    if (height <= 0.0) height = available > 0.0 ? available : kDKDemoCapsuleHeight;

    CGFloat y = MAX(bounds.size.height - bottomInset - margin - height, 0.0);

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

        NSArray *buttons = DKDemoNativeButtons(bar);
        NSString *signature = DKDemoSignature(buttons);
        if (!gCapsule || ![signature isEqualToString:gSignature ?: @""]) {
            DKDemoRebuild(bar, buttons, signature);
        }

        DKDemoHideNative(bar);
        DKDemoLayout(bar);
        DKDemoRefreshSelection();

        UIUserInterfaceStyle style = DKDemoStyle(bar);
        [gCapsule applyStyle:style];
        [gPlusKey applyStyle:style];
        DKDemoUpdateFloatButton(bar.window);

        CGRect barBounds = bar.bounds;
        NSUInteger mirrored = gItems.count > 0 ? gItems.count - 1 : 0;
        gDiagnostics = [NSString stringWithFormat:@"底栏 %@ %.0f×%.0f 安全区=%.0f 镜像=%lu/%lu",
                        NSStringFromClass(bar.class), barBounds.size.width, barBounds.size.height,
                        bar.safeAreaInsets.bottom,
                        (unsigned long)mirrored, (unsigned long)buttons.count];

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

    // 浮标兜底：底栏钩子没命中时（类名变了 / 页面还没建），这个是唯一能看到诊断的入口。
    [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *timer) {
        DKDemoUpdateFloatButton(DKDemoKeyWindow());
    }];
}
