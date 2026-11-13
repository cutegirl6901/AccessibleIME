import Foundation
import KeyboardCore
import RimeBridgeObjC

extension RimeConfigManager {
    /// 原型专用：解析键盘扩展自己的 RIME 运行时目录。
    ///
    /// 背景：
    /// - 官方与上游工程默认使用 App Group，主 App 负责部署，扩展只读共享目录。
    /// - 本原型关闭完全访问、不使用 App Group，因此资源与用户数据都落在
    ///   键盘扩展自己的沙盒内。
    /// - 资源在首次启动时从扩展包内复制一次，之后只做增量校验，避免在按键
    ///   热路径做重型 IO。
    ///
    /// 目录约定（均在扩展沙盒内）：
    /// - Application Support/Rime/shared：从扩展包复制出的只读资源
    /// - Application Support/Rime/user：librime 用户数据与学习数据
    public static func localRuntimeDirectories(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> (sharedDir: String, userDir: String)? {
        guard let supportRoot = applicationSupportRoot(fileManager: fileManager) else {
            return nil
        }
        let rimeRoot = supportRoot.appendingPathComponent("Rime", isDirectory: true)
        let sharedRoot = rimeRoot.appendingPathComponent("shared", isDirectory: true)
        let userRoot = rimeRoot.appendingPathComponent("user", isDirectory: true)

        do {
            try fileManager.createDirectory(at: userRoot, withIntermediateDirectories: true)
            try ensureLocalResourcesInstalled(
                sharedRoot: sharedRoot,
                bundle: bundle,
                fileManager: fileManager
            )
            try ensureMinimalDefaultCustomYaml(userRoot: userRoot, fileManager: fileManager)
            try ensureLocalRuntimeDeployed(
                sharedRoot: sharedRoot,
                userRoot: userRoot,
                fileManager: fileManager
            )
        } catch {
            Logger.shared.error(
                "Local RIME resources are unavailable: \(error)",
                category: .config
            )
            return nil
        }

        guard
            fileManager.fileExists(atPath: sharedRoot.path),
            fileManager.fileExists(atPath: userRoot.path)
        else { return nil }

        return (sharedRoot.path, userRoot.path)
    }

    private static func applicationSupportRoot(fileManager: FileManager) -> URL? {
        guard
            let base = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else { return nil }
        return base
    }

    /// 首次运行复制内置资源；已存在且通过清单校验时直接复用。
    private static func ensureLocalResourcesInstalled(
        sharedRoot: URL,
        bundle: Bundle,
        fileManager: FileManager
    ) throws {
        let manifestName = (RimeBuiltinResourceInstaller.manifestFileName as NSString)
            .deletingPathExtension
        guard
            let manifestURL = bundle.url(forResource: manifestName, withExtension: "json"),
            let manifest = try? JSONDecoder().decode(
                RimeBuiltinResourceInstaller.Manifest.self,
                from: Data(contentsOf: manifestURL)
            )
        else {
            throw RimeBuiltinResourceInstaller.InstallationError.manifestMissing
        }

        let generationMarker = sharedRoot.appendingPathComponent(".generation")
        if let existing = try? String(contentsOf: generationMarker, encoding: .utf8),
            existing == manifest.generationID,
            fileManager.fileExists(
                atPath: sharedRoot.appendingPathComponent("default.yaml").path
            )
        {
            return
        }

        // 资源缺失或代际不一致时整体重建。此处只在扩展首次启动或升级后执行，
        // 不在每次按键时触发。
        if fileManager.fileExists(atPath: sharedRoot.path) {
            try fileManager.removeItem(at: sharedRoot)
        }
        try fileManager.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        for entry in manifest.entries {
            let fileName = entry.path.components(separatedBy: "/").last ?? ""
            let resourceName = (fileName as NSString).deletingPathExtension
            let resourceExtension = (fileName as NSString).pathExtension
            guard
                !resourceName.isEmpty,
                let source = bundle.url(forResource: resourceName, withExtension: resourceExtension)
            else {
                throw RimeBuiltinResourceInstaller.InstallationError.resourceSetMismatch
            }
            let destination = sharedRoot.appendingPathComponent(entry.path)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }
        try manifest.generationID.write(to: generationMarker, atomically: true, encoding: .utf8)
        Logger.shared.info(
            "Local RIME resources installed fileCount=\(manifest.entries.count)",
            category: .config
        )
    }

    /// 内置 `default.yaml` 声明了朙月、注音、仓颉等六个方案，但本原型只随包携带
    /// 朙月与笔画资源。该文件写出一份最小方案清单，覆盖内置声明，避免 librime
    /// 在启动时反复尝试加载缺失方案。
    ///
    /// 与主应用部署路径的区别：这里不写主应用的 rime_deployed 偏好，扩展
    /// 用自己的 .rime_deployed 标记文件记录部署状态。
    private static func ensureMinimalDefaultCustomYaml(
        userRoot: URL,
        fileManager: FileManager
    ) throws {
        let target = userRoot.appendingPathComponent("default.custom.yaml")
        let payload = """
            patch:
              schema_list:
                - schema: luna_pinyin
                - schema: stroke
              menu/page_size: 8

            """
        if let existing = try? String(contentsOf: target, encoding: .utf8),
            existing.contains("luna_pinyin")
        {
            return
        }
        try payload.write(to: target, atomically: true, encoding: .utf8)
        Logger.shared.info("Wrote minimal default.custom.yaml for local runtime", category: .config)
    }

    /// 原型专用：在键盘扩展自己的沙盒里执行一次 RIME 全量部署。
    ///
    /// 背景：上游设计里部署由主 App 完成，产物经 App Group 交给扩展读取。
    /// 本原型关闭了完全访问、清空了 App Group，主 App 的部署路径必然失败，
    /// 因此必须由扩展自己完成。否则 librime 缺少部署元数据与词库关联，
    /// 表现为「英文能打、中文无候选」。
    ///
    /// 部署只在资源代际变化后执行一次，用标记文件记录结果。
    /// 失败不阻断键盘启动：返回目录仍可用，只是可能没有中文候选。
    private static func ensureLocalRuntimeDeployed(
        sharedRoot: URL,
        userRoot: URL,
        fileManager: FileManager
    ) throws {
        let marker = userRoot.appendingPathComponent(".rime_deployed")
        if fileManager.fileExists(atPath: marker.path) {
            return
        }

        Logger.shared.info(
            "Starting local RIME deployment (extension sandbox)",
            category: .deployment
        )

        let catalog = RimeDeployer()
        let succeeded = catalog.deploy(
            withSharedDataDir: sharedRoot.path,
            userDataDir: userRoot.path
        )

        if succeeded {
            try "deployed".write(to: marker, atomically: true, encoding: .utf8)
            Logger.shared.info("Local RIME deployment succeeded", category: .deployment)
        } else {
            Logger.shared.error(
                "Local RIME deployment failed; Chinese candidates may be unavailable",
                category: .deployment
            )
        }
    }
}
