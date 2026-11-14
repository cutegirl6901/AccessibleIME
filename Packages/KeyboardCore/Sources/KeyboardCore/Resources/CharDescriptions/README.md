# 汉字朗读描述资源

VoiceOver 朗读中文候选时，用这里的字符描述补充逐字解释，
帮助视障用户确认同音字。例如候选「我们」朗读为：

    我们，我们的我，我们的们

## 文件

| 文件 | 来源 | 条目 |
|---|---|---|
| `zh_CN.compact.txt` | NVDA 简体中文字典 | 26,705 |
| `zh_TW.compact.txt` | NVDA 繁体中文字典 | 22,180 |
| `SOURCES.md` | 上游版权与派生说明 | — |

两个 `.compact.txt` 是 NVDA `characterDescriptions.dic` 的精简派生：
只保留「字符 → 第一条描述」，去掉注释、空行与多字符脏数据行。
原始字典受 GPL 约束，完整副本未随包分发，见 `SOURCES.md`。

## 格式

每行以真实 Tab 分列：

    我<Tab>(我们的我)
    们<Tab>(我们的们)
    好<Tab>(好坏的好)

第一列是单个字符，第二列是第一条描述。

## 朗读规则

由 `CharacterDescriptionSpeech` 实现：

1. 描述被 ASCII 括号完整包围 → 去掉外层括号直接用。
   `(我们的我)` → `我们的我`
2. 描述没有外层括号 → 拼成「描述＋的＋原字」。
   繁体 `我們` → `我們的我`
3. 查不到描述 → 回退原字符。
4. 同一字符只解释一次，避免「我们的我的我」。
5. 按字素簇遍历，不拆坏扩展汉字。

组合结果：

    我们  → 我们，我们的我，我们的们
    中国  → 中国，中央的中，国家的国
    输入法 → 输入法，运输的输，进入的入，方法的法

## 代码入口

- `CharacterDescriptionTable.parse(_:)` — 解析文本
- `CharacterDescriptionTable.load(languageCode:bundle:)` — 从资源加载
- `CharacterDescriptionTableProvider.shared` — 懒加载单例
- `CharacterDescriptionSpeech.announcement(for:table:)` — 生成朗读文案

## 更新资源

1. 从 NVDA 取对应语言的 `characterDescriptions.dic`
2. 按 Tab 分列读取，保留前两列，跳过注释/空行/多字符键
3. 覆盖对应 `.compact.txt`，并在 `SOURCES.md` 记录来源版本

## 语言选择

`CharacterDescriptionTableProvider.preferredLanguageCode()` 读取系统首选语言：
繁体地区（`zh-TW`/`zh-HK`/`zh-MO`/`zh-Hant`）走繁体表，其余中文走简体表。
资源缺失时返回空表，朗读退回原词，不影响输入。
