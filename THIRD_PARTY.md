# 第三方组件与对应源码

本 App 随附以下动态库，使用 Homebrew 官方二进制包并校验 SHA-256；具体版本、软件包摘要、源码地址见同目录 `manifest.json`（源码工程中为 `Vendor/manifest.json`）。

| 组件 | 许可证 | 对应资料 |
| --- | --- | --- |
| libimobiledevice | LGPL-2.1-or-later | Licenses/libimobiledevice；Sources 中含对应发布源码与构建配方 |
| libimobiledevice-glue | LGPL-2.1-or-later | Licenses/libimobiledevice-glue；Sources 中含对应发布源码与构建配方 |
| libplist（C 运行库） | LGPL-2.1-or-later | Licenses/libplist；Sources 中含对应发布源码与构建配方 |
| libusbmuxd | LGPL-2.1-or-later | Licenses/libusbmuxd；Sources 中含对应发布源码与构建配方 |
| OpenSSL | Apache-2.0 | Licenses/openssl@4，含许可及上游要求保留的通知；Sources 中含 Homebrew 构建配方 |

第三方组件的完整著作权与许可声明位于上述 Licenses 子目录，以随附原文为准。LGPL 发布源码归档和构建配方包含在 App 的 Contents/Resources/ThirdParty/Sources 中，也包含在源码工程 Vendor/Sources 中。Homebrew 构建配方记录了构建选项；本项目的 scripts/bundle-libraries.sh 记录库路径重定位及本地签名步骤。二进制库只做动态库路径重定位和本地签名，没有修改其实现。

允许依照相应 LGPL 条款为个人使用修改、调试和替换这些动态库，并为调试对库的修改而进行所需的逆向工程。应用通过公共 C 接口动态加载这些库，未启用阻止用户替换库的强化运行时库验证。替换后请重新签名修改的库和 App；操作方法见项目 README。

本项目不隶属于 Apple、Homebrew 或 libimobiledevice 项目。SwiftUI、Foundation、Observation、CryptoKit 和 AppKit 由 Apple macOS SDK 提供。所有组件均按各自许可证提供，不附加对第三方组件许可权利的限制。
