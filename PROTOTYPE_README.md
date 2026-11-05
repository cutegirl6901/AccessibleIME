# 无障碍拼音输入法（原型）

面向使用旁白的视障用户设计的 iOS 中文输入法原型，明眼用户同样可用。

本原型基于 Universe Keyboard 二次开发，但已改为**独立项目**：独立的标识、独立的资源布局、独立的学习数据，不与原工程共享任何运行时状态。

## 当前状态

**早期原型，未经编译验证。** 所有改动均基于静态分析，尚未在任何设备上运行过。

## 与原工程的差异

| 方面 | 原工程 | 本原型 |
|---|---|---|
| 完全访问 | 要求开启 | 关闭，核心输入不依赖 |
| 共享容器 | 使用 App Group | 不使用，资源与数据都在键盘扩展沙盒内 |
| 输入资源 | 主应用部署，扩展读取 | 随键盘扩展打包，首次启动复制到沙盒 |
| 主应用 | 完整设置、同步、诊断 | 仅保留测试说明入口（待实现） |
| bundle ID | com.DoubleShy0N.Universe-Keyboard | com.accessibleime.prototype |
| 显示名称 | Universe Keyboard | 无障碍拼音 |
| 开发者团队 | C33N6HTS9N | 已清空，由安装方重新签名 |
| 构建产物 | 无 IPA 流程 | 新增未签名 IPA 云端构建 |

## 目录说明

```
Keyboard/                    键盘扩展（实际输入界面）
Keyboard/RimeBuiltin/        随扩展打包的 RIME 资源（26 个文件，约 33 MB）
Packages/KeyboardCore/       输入语义与状态机
Packages/RimeBridge/         librime 桥接
Universe Keyboard/           主应用
docs/                        项目文档
```

## 构建

需要 macOS 与 Xcode。

```bash
# 1. 获取 RIME 二进制依赖（约 42 MB，首次必需）
bash scripts/ensure_rime_vendor.sh fetch

# 2. 编译
xcodebuild -project "Universe Keyboard.xcodeproj" \
  -scheme "Universe Keyboard" \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build
```

或使用 GitHub Actions 的「原型 IPA 构建」工作流，手动触发后下载未签名 IPA。

## 安装

使用 SideStore 安装未签名 IPA，由 SideStore 使用你的 Apple ID 重新签名。

免费 Apple ID 签名通常每 7 天需要重新签名。

## 已知风险

1. 代码未经编译验证，可能存在编译错误。
2. RIME 二进制依赖仍指向原作者的发布地址，存在被删除的风险。
3. 键盘扩展有内存上限，内置完整资源可能触发限制，尚未实测。
4. 无障碍交互（旁白朗读、候选操作、双指撤销）尚未实现。
5. 关闭完全访问后 librime 能否正常初始化，尚未在真机验证。

## 文档

- `docs/ACCESSIBLE_IME_BASELINE.md` — 项目基线与决策记录
- `docs/plans/accessible-direct-touch-spike.md` — 直接触摸实验提案
- `docs/GLOSSARY.md` — 术语表
