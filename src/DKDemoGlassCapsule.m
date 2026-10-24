//
//  DKDemoGlassCapsule.m
//  DKDemoGlass
//
//  结构与顺序（从下到上）：
//    self            承载外阴影（不能 masksToBounds，否则阴影被裁）
//    └ clipView      圆角裁切（masksToBounds + 连续曲率）
//       ├ effectView     UIVisualEffectView + UIBlurEffect，材质底
//       ├ tintView       染色层，模拟 UIGlassEffect.tintColor 的压暗 / 提亮
//       ├ highlightLayer 顶部高光，模拟玻璃上缘的镜面反射
//       ├ borderLayer    1pt 渐变描边（用 CAShapeLayer 当 mask 描出圆角环）
//       └ contentView    业务按钮
//
//  几个刻意的取舍：
//  · 描边不用 borderWidth：单色描边在深浅两档都容易"脏"，渐变才能做出上亮下暗的玻璃边。
//  · 高光只铺上面 52%：整块渐变会糊住图标。
//  · 阴影挂在 self 而不是 clipView：clipView 一裁，阴影就没了。
//

#import "DKDemoGlassCapsule.h"
#import <QuartzCore/QuartzCore.h>

@interface DKDemoGlassCapsule ()

@property (nonatomic, strong) UIView *clipView;
@property (nonatomic, strong) UIVisualEffectView *effectView;
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, strong) CAGradientLayer *highlightLayer;
@property (nonatomic, strong) CAGradientLayer *borderLayer;
@property (nonatomic, strong) CAShapeLayer *borderMask;
@property (nonatomic, strong, readwrite) UIView *contentView;

/// 上一次 applyStyle: 的外观，preset 变更时用它重刷。
@property (nonatomic, assign) UIUserInterfaceStyle lastStyle;
/// 上一次 applyStyle: 用到的档位，避免同一档反复重建材质（重建会打断过渡）。
@property (nonatomic, assign) DKDemoGlassPreset appliedPreset;

@end

@implementation DKDemoGlassCapsule

#pragma mark - 生命周期

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    _preset = DKDemoGlassPresetFrosted;
    _appliedPreset = (DKDemoGlassPreset)-1;
    _lastStyle = UIUserInterfaceStyleUnspecified;

    self.backgroundColor = UIColor.clearColor;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.28;
    self.layer.shadowRadius = 18.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 8.0);

    _clipView = [[UIView alloc] initWithFrame:self.bounds];
    _clipView.backgroundColor = UIColor.clearColor;
    _clipView.clipsToBounds = YES;
    [self addSubview:_clipView];

    _effectView = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    _effectView.frame = _clipView.bounds;
    _effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _effectView.userInteractionEnabled = NO;
    [_clipView addSubview:_effectView];

    _tintView = [[UIView alloc] initWithFrame:_clipView.bounds];
    _tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tintView.userInteractionEnabled = NO;
    [_clipView addSubview:_tintView];

    _highlightLayer = [CAGradientLayer layer];
    _highlightLayer.startPoint = CGPointMake(0.5, 0.0);
    _highlightLayer.endPoint = CGPointMake(0.5, 1.0);
    [_clipView.layer addSublayer:_highlightLayer];

    _borderLayer = [CAGradientLayer layer];
    _borderLayer.startPoint = CGPointMake(0.1, 0.0);
    _borderLayer.endPoint = CGPointMake(0.9, 1.0);
    _borderMask = [CAShapeLayer layer];
    _borderMask.fillColor = UIColor.clearColor.CGColor;
    _borderMask.strokeColor = UIColor.whiteColor.CGColor;
    _borderMask.lineWidth = 1.0;
    _borderLayer.mask = _borderMask;
    [_clipView.layer addSublayer:_borderLayer];

    _contentView = [[UIView alloc] initWithFrame:_clipView.bounds];
    _contentView.backgroundColor = UIColor.clearColor;
    [_clipView addSubview:_contentView];

    [self applyStyle:UIUserInterfaceStyleLight];
    return self;
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    CGFloat radius = self.capsuleCornerRadius > 0.0 ? self.capsuleCornerRadius : bounds.size.height * 0.5;

    _clipView.frame = bounds;
    _clipView.layer.cornerRadius = radius;
    _clipView.layer.cornerCurve = kCACornerCurveContinuous;

    _effectView.frame = _clipView.bounds;
    _tintView.frame = _clipView.bounds;
    _contentView.frame = _clipView.bounds;

    _highlightLayer.frame = CGRectMake(0.0, 0.0, bounds.size.width, bounds.size.height * 0.52);
    _borderLayer.frame = bounds;

    // 描边环：内缩 0.5，让 1pt 线正好压在边界上，不会被圆角裁掉一半。
    CGRect ring = CGRectInset(bounds, 0.5, 0.5);
    _borderMask.frame = bounds;
    _borderMask.path = [UIBezierPath bezierPathWithRoundedRect:ring
                                                  cornerRadius:MAX(radius - 0.5, 0.0)].CGPath;

    // 阴影路径用整块胶囊，比默认的 alpha 通道便宜得多（滚动 / 逐帧时不掉帧）。
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bounds
                                                         cornerRadius:radius].CGPath;
}

#pragma mark - 外观

- (void)setCapsuleCornerRadius:(CGFloat)radius {
    _capsuleCornerRadius = radius;
    [self setNeedsLayout];
}

- (void)setPreset:(DKDemoGlassPreset)preset {
    _preset = preset;
    UIUserInterfaceStyle style = self.lastStyle == UIUserInterfaceStyleUnspecified
        ? UIUserInterfaceStyleLight
        : self.lastStyle;
    [self applyStyle:style];
}

- (void)applyStyle:(UIUserInterfaceStyle)style {
    self.lastStyle = style;
    // 底栏浮在视频上，背景明暗随时在变；而且抖音把 window 钉成浅色，跟着外观走
    // 会得到"白玻璃 + 黑字"，压在深色画面上整条都看不见。这里统一用深色玻璃 + 白内容。
    BOOL dark = YES;
    (void)style;

    UIBlurEffectStyle blurStyle = UIBlurEffectStyleSystemThinMaterial;
    UIColor *tint = nil;
    UIColor *borderTop = nil;
    UIColor *borderBottom = nil;
    UIColor *highlight = nil;

    switch (self.preset) {
        case DKDemoGlassPresetThin:
            // 清透：材质本身已经足够透，染色只用来压一点对比，重点放在亮边。
            blurStyle = UIBlurEffectStyleSystemUltraThinMaterial;
            tint = dark ? [UIColor colorWithWhite:0.0 alpha:0.26] : [UIColor colorWithWhite:1.0 alpha:0.08];
            borderTop = [UIColor colorWithWhite:1.0 alpha:dark ? 0.52 : 0.85];
            borderBottom = [UIColor colorWithWhite:1.0 alpha:dark ? 0.06 : 0.16];
            highlight = [UIColor colorWithWhite:1.0 alpha:dark ? 0.12 : 0.30];
            break;

        case DKDemoGlassPresetChrome:
            // 厚雾：可读性优先，适合浅色内容 / 文字多的底栏。
            blurStyle = UIBlurEffectStyleSystemChromeMaterial;
            tint = dark ? [UIColor colorWithWhite:0.02 alpha:0.52] : [UIColor colorWithWhite:1.0 alpha:0.22];
            borderTop = [UIColor colorWithWhite:1.0 alpha:dark ? 0.42 : 0.75];
            borderBottom = [UIColor colorWithWhite:1.0 alpha:dark ? 0.05 : 0.12];
            highlight = [UIColor colorWithWhite:1.0 alpha:dark ? 0.10 : 0.24];
            break;

        case DKDemoGlassPresetFrosted:
        default:
            blurStyle = UIBlurEffectStyleSystemThinMaterial;
            tint = dark ? [UIColor colorWithWhite:0.0 alpha:0.40] : [UIColor colorWithWhite:1.0 alpha:0.14];
            borderTop = [UIColor colorWithWhite:1.0 alpha:dark ? 0.46 : 0.80];
            borderBottom = [UIColor colorWithWhite:1.0 alpha:dark ? 0.06 : 0.14];
            highlight = [UIColor colorWithWhite:1.0 alpha:dark ? 0.11 : 0.26];
            break;
    }

    // 同档位重复调用时不动材质：重建 UIVisualEffect 会打断系统正在做的过渡。
    if (_appliedPreset != self.preset) {
        _effectView.effect = [UIBlurEffect effectWithStyle:blurStyle];
        _appliedPreset = self.preset;
    }

    _tintView.backgroundColor = tint;
    _borderLayer.colors = @[ (id)borderTop.CGColor, (id)borderBottom.CGColor ];
    _highlightLayer.colors = @[ (id)highlight.CGColor,
                                (id)[highlight colorWithAlphaComponent:0.0].CGColor ];

    // 内容一律白色，跟深色玻璃配套。
    self.tintColor = UIColor.whiteColor;
}

- (void)setShadowVisible:(BOOL)visible {
    self.layer.shadowOpacity = visible ? 0.28 : 0.0;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection == nil) return;
    if (@available(iOS 13.0, *)) {
        if (![self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
            return;
        }
    }
    if (self.lastStyle != UIUserInterfaceStyleUnspecified) {
        [self applyStyle:self.traitCollection.userInterfaceStyle];
    }
}

@end
