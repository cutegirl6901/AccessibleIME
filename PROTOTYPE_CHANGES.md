# 原型变更清单

> 基线：Universe Keyboard `main` @ `145d2416`
>
> 日期：2026-11-05
>
> 状态：**未经编译验证**。以下改动全部基于静态分析。

## 一、新增文件

| 文件 | 用途 |
|---|---|
| `Packages/RimeBridge/Sources/RimeBridge/RimeConfigManager+LocalRuntime.swift` | 键盘扩展本地 RIME 运行时解析与资源安装 |
| `.github/workflows/prototype-ipa.yml` | 云端构建未签名 IPA |
| `PROTOTYPE_README.md` | 原型说明 |
| `PROTOTYPE_CHANGES.md` | 本文件 |
| `Keyboard/RimeBuiltin/` | 随键盘扩展打包的 RIME 资源（26 个文件） |

## 二、修改文件

### 2.1 关闭完全访问

**`Keyboard/Info.plist`**
- `RequestsOpenAccess`：`true` → `false`

### 2.2 移除共享容器

**`Universe Keyboard/Universe Keyboard.entitlements`**
**`Keyboard/Keyboard.entitlements`**
- 清空 `com.apple.security.application-groups` 声明

### 2.3 键盘启动改为本地资源优先

**`Keyboard/Controllers/KeyboardViewController+Bootstrap.swift`**
- `prepareRimeRuntimeAvailability()` 改为三级顺序：
  1. 扩展本地资源（新增）
  2. App Group（保留为回退）
  3. 内存回退引擎（缺失时）

### 2.4 设置与日志回退到本地存储

**`Keyboard/Controllers/KeyboardViewController.swift`**
- 新增 `effectiveDefaults`，App Group 不可用时回退到标准存储
- `sharedDefaults` 改用 `effectiveDefaults`

**`Keyboard/Controllers/KeyboardViewController+Feedback.swift`**
- T9 就绪检测改为优先读取本地资源目录

**`Packages/KeyboardCore/Sources/KeyboardCore/Logger.swift`**
- 新增 `resolvedDefaults`，改用本地存储

**`Packages/KeyboardCore/Sources/KeyboardCore/LoggerWriter.swift`**
- 三处读写改用 `Logger.resolvedDefaults`

**`Packages/RimeBridge/Sources/RimeBridge/RimeRuntimeSelectionBridge.swift`**
- 新增 `localDefaults`，方案选择默认读取本地存储

**`Packages/RimeBridge/Sources/RimeBridge/RimeConfigManager+Preferences.swift`**
- 偏好读取增加标准存储回退

### 2.5 工程标识

**`Universe Keyboard.xcodeproj/project.pbxproj`**
- bundle ID 全部改为 `com.accessibleime.prototype` 系列（18 处）
- `DEVELOPMENT_TEAM` 清空（18 处）
- 显示名称设为「无障碍拼音」（4 处）

## 三、关键设计说明

### 3.1 为什么资源要随扩展打包

关闭完全访问后，键盘扩展无法访问主应用的数据容器。因此 RIME 资源必须随扩展一起分发。

首次启动时，扩展把包内资源复制到自己的 `Application Support/Rime/shared`，之后按代际标记复用，不在按键热路径做重型 IO。

### 3.2 为什么要重写方案清单

内置 `default.yaml` 声明了六个输入方案（朙月、注音、仓颉、速成、笔画、地球拼音），但资源包只包含朙月和笔画。

首次启动时写出一份最小的 `default.custom.yaml`，只启用已打包的两个方案，避免 librime 反复加载缺失方案。

### 3.3 为什么保留 App Group 代码路径

原工程的 App Group 逻辑被保留为回退分支，不删除。原因是：
- 将来若使用付费账号，可以恢复共享能力
- 删除会牵动大量代码，增加原型失败风险

## 四、未验证的风险

| 风险 | 说明 | 严重度 |
|---|---|---|
| 编译错误 | 改动未经过任何编译器检查 | 高 |
| librime 无完全访问初始化 | 尚未在真机验证关闭完全访问后能否启动 | 高 |
| 键盘内存上限 | 33 MB 资源可能导致扩展被杀 | 中 |
| 资源打包方式 | Xcode 同步组对资源的处理尚未验证 | 中 |
| RIME 依赖来源 | 仍指向原作者发布地址 | 中 |
| 主应用仍引用旧标识 | 部分界面文案和路径未同步 | 低 |

## 五、下一步

1. 推送代码到 GitHub 仓库
2. 触发「原型 IPA 构建」工作流
3. 确认能否编译通过
4. 用 SideStore 安装到手机
5. 验证无完全访问下能否启动并输入
