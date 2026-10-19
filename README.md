# DKDemoGlass —— iOS 16 磨砂胶囊底栏最小验证

在 **iPhone 13 Pro Max / iOS 16.3.1 / TrollStore + TrollFools（无越狱）** 上验证一条路：**不用 iOS 26 的 `UIGlassEffect`，靠自己画一块胶囊 + 系统模糊材质，能不能做出接近 DYKiller 悬浮玻璃底栏的观感。**

这是 demo，不是成品。它只回答三个问题：

1. 材质观感够不够接近（屏幕右侧那个 DK 浮标可以实时切三档对比）；
2. 在 13 Pro Max 上性能扛不扛得住（底栏下面是视频）；
3. 抖音 40.7.0 在 iOS 16 上的底栏，能不能被接管（类名 / KVC 键 / 背景层）。

## 你这个环境意味着什么

| 项 | 值 | 影响 |
|---|---|---|
| 设备 | iPhone 13 Pro Max（A15 / arm64） | 抖音二进制是 arm64，所以 dylib 只出 arm64 一片 |
| 系统 | iOS 16.3.1 | 没有 `UIGlassEffect`、没有悬浮 platter，全部自绘 |
| 越狱 | **无** | 没有 CydiaSubstrate / ElleKit，也没有 SSH 和 `killall` |
| 注入 | **TrollFools** | 直接把 dylib 塞进 App 的 Mach-O，dyld 启动时加载 |
| 抖音 | 必须是 **TrollStore 装的解密版 40.7.0** | App Store 加密版注入不了 |

两个直接后果：

- **不产 deb**。TrollFools 要的是一枚 dylib，所以构建目标是 `make dylib`，产物是 `DKDemoGlass.dylib`。
- **没有 substrate 依赖**。Logos 用 `internal` 生成器，钩子全部是 ObjC runtime swizzle；`%ctor` 在 dylib 被 dyld 加载时执行。这正是 TrollFools 环境能跑的前提，构建后 CI 会检查 dylib 有没有误链 substrate。

## 编译

### 云端（你在 Windows 上只能走这条）

把 `DKDemoGlass/` 推到一个 GitHub 仓库，Actions 会自动装 Theos、出 dylib，产物在 **Artifacts → DKDemoGlass-dylib**。

同时会打印 `otool -D` / `otool -L`，如果链接了 substrate 会给出 warning——真出现了把日志发我。

> 这个 workflow 我没法在 Windows 上验证，第一次跑可能要调 1–2 次（多半是 `brew install` 的包名）。

### 本地 macOS

```bash
cd DKDemoGlass
make dylib
# 产物：packages/DKDemoGlass.dylib
```

需要 macOS + Xcode + [Theos](https://theos.dev)，**不需要 iOS 26 SDK**——这正是它存在的意义。

## 注入（TrollFools）

1. 确认桌面上的抖音是 **TrollStore 安装的那份**（TrollStore → Apps 列表里能看到）。App Store 原版是加密的，注入必失败。
2. 打开 TrollFools → 选「抖音」。
3. 点 **+** / 「注入」→ 选 `DKDemoGlass.dylib`。
4. TrollFools 会把它拷进 App 包的 `Frameworks/`、写入 `LC_LOAD_DYLIB`、重新签名。
5. **彻底退出抖音**（上滑杀掉），再打开。TrollFools 注入不需要 respring。

注意事项：

- 抖音更新 / 重装会丢掉注入，要重新注入一次。
- **不要同时注入 DYKiller**。两者都改 `AWENormalModeTabBar`，同开会互相覆盖，出问题分不清是谁的。
- 注入对抖音本体有修改，出问题可以在 TrollFools 里「移除」还原。

## 验证

### 先找那个 "DK" 浮标

dylib 一旦加载成功，屏幕右下角（底栏上方 150pt）会出现一个 40pt 的 **DK** 圆按钮。

- **有浮标** → dylib 加载成功。
- **没浮标** → 注入没生效（或在 TrollFools 里被禁用了），跟界面代码无关，先解决这一步。

点它出菜单，里面就是全部诊断信息：底栏类名、尺寸、安全区、镜像成功几个、扫描到的 TabBar 类。**这是 TrollStore 环境下的主要反馈通道**——没有 SSH 也能看到。

长按底栏上的胶囊 / 拍摄圆键也能出同一个菜单。

### 看日志（可选，但信息更全）

Windows 上装 [libimobiledevice](https://libimobiledevice.org/) 后：

```powershell
idevicesyslog | Select-String "DKDemoGlass"
```

启动 6 秒后应该有两行：

```
[DKDemoGlass] 首次同步 底栏 AWENormalModeTabBar 428×83 安全区=34 镜像=4/5
[DKDemoGlass] 底栏类扫描：
AWENormalModeTabBar@8
```

第一行的 **428×83 / 安全区 34 / 镜像 4/5** 是我最想确认的数。

### 期望看到什么

底栏变成：**左侧一条磨砂胶囊（4 项，图标在上、文字在下）+ 右侧一个独立圆形拍摄键**，两侧留 16pt。

## 为什么胶囊只有约 45pt 高

13 Pro Max 上抖音底栏总高约 83pt，其中 34pt 是 home indicator 安全区，**内容区只剩 49pt**。胶囊要待在内容区里，就只能 45pt 左右。iOS 26 上那个 62pt 的胶囊，是因为系统的悬浮底栏本身就更高。

想更接近 iOS 26 的体量，下一步得连底栏一起加高——那是要改抖音自身布局的，风险和工作量都上一个台阶。

## 已知差距（先说清楚）

1. **没有折射 / 透镜**。iOS 16 没这套 API，这里只有模糊 + 染色 + 亮边 + 高光。远看很像，近看是磨砂玻璃，不是液态玻璃。
2. **没有随触摸流动的镜面高光**，按压只有 0.94 的缩放。
3. **图标 / 文字是镜像原生按钮的**。抖音在 iOS 16 上若换了绘制方式，可能读不到，会退化成占位图标（菜单里会显示 `镜像=0/0`）。
4. 浮标是 demo 专用，菜单里可以关掉。

## 排障

| 现象 | 判断 | 处理 |
|---|---|---|
| 注入后抖音一开就闪退 | dyld 加载失败 | `idevicesyslog` 里找 `dyld: Library not loaded` / `code signature invalid`；多半是 install_name 或签名，把日志发我 |
| 抖音正常，但没有 DK 浮标 | dylib 没被加载 | TrollFools 里确认这条注入是启用状态；确认抖音是 TrollStore 版 |
| 有浮标，但底栏没变 | 钩子没命中 | 点浮标看「底栏类扫描」，把扫描结果发我 |
| 底栏整个消失 | 原生视图被隐藏但胶囊没建出来 | 点浮标看诊断；把 `DKDemoHideNative` 改成先不隐藏再试 |
| 胶囊出现但底下是白/黑实心 | 背景层不在 `AWENormalModeTabBar` 的子视图里 | 把该容器类名发我 |
| 点了某项没反应 | 那个按钮不是 UIControl | 把 `idevicesyslog` 里 `原生项不是 UIControl` 那行发我 |

## 顺带：DYKiller 本身也能这样装

它的 dylib 同样是 substrate-free（Logos internal 生成器），所以可以把 release 里 `arm64-rootless.deb` 解开，取出 `DYKiller.dylib`，用 TrollFools 注入进解密版抖音——iOS 16 上除了「液态玻璃」那几项会灰显（`(iOS26+)`），其余功能理论上都能用。

不过别和这个 demo 同时注入。

## 文件

```
DKDemoGlass/
├── Makefile                        make dylib → packages/DKDemoGlass.dylib
├── .github/workflows/build.yml     云端出 dylib
├── control / DKDemoGlass.plist     越狱环境的元数据，TrollFools 流程用不到，留着备查
├── README.md
└── src/
    ├── DKDemoGlassCapsule.h/.m     材质胶囊（可整块搬进 DYKiller）
    └── DKDemoTabBar.xm             底栏钩子 / 镜像 / 布局 / 浮标与菜单
```
