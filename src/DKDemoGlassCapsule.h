//
//  DKDemoGlassCapsule.h
//  DKDemoGlass
//
//  iOS 16 可用的「仿液态玻璃」材质视图：一个自带模糊、染色、渐变亮边、顶部高光与外阴影的胶囊。
//  它只负责"看起来像玻璃"，不含任何 iOS 26 API，也不关心底栏业务。
//
//  移植到 DYKiller 时，这个类可以直接顶替 DKGlassMakeGlassEffect 产出的材质层：
//  上层几何 / 镜像 / 代理逻辑都不用改。
//

#ifndef DKDemoGlassCapsule_h
#define DKDemoGlassCapsule_h

#import <UIKit/UIKit.h>

/// 三档观感，对应真机上要 A/B 的三个方向。
typedef NS_ENUM(NSInteger, DKDemoGlassPreset) {
    DKDemoGlassPresetThin = 0,     // 清透：超薄材质 + 极淡染色，最接近 iOS 26 Clear
    DKDemoGlassPresetFrosted = 1,  // 磨砂：薄材质 + 轻染色，默认档
    DKDemoGlassPresetChrome = 2,   // 厚雾：chrome 材质 + 较重染色，可读性最好
};

@interface DKDemoGlassCapsule : UIView

/// 圆角。默认取高度的一半（胶囊）。
@property (nonatomic, assign) CGFloat capsuleCornerRadius;

/// 观感档位。赋值会立刻按上一次 applyStyle: 的外观重刷。
@property (nonatomic, assign) DKDemoGlassPreset preset;

/// 内容容器。业务按钮加到这里，会被圆角裁切。
@property (nonatomic, strong, readonly) UIView *contentView;

/// 按外观（浅色 / 深色）刷材质、染色、描边与高光。幂等，可反复调用。
- (void)applyStyle:(UIUserInterfaceStyle)style;

/// 关掉外阴影（贴在视频上时偶尔会显脏，留个开关）。
- (void)setShadowVisible:(BOOL)visible;

@end

#endif /* DKDemoGlassCapsule_h */
