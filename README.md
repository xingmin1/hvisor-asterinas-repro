# hvisor + Asterinas 复现配置

本仓库提供在 hvisor x86_64 QEMU 环境中运行 Asterinas 所需的开发环境和虚拟机配置。

- `flake.nix`、`flake.lock`：Nix 开发环境
- `toolchains/`：hvisor 与 Asterinas 使用的 Rust 工具链声明
- `zone1_asterinas.json`：交互式 Asterinas zone1 配置
- `zone1_asterinas_boot_hello.json`：最小启动验证配置
- `virtio_cfg_asterinas.json`：virtio-console 与块设备配置

本仓库不包含构建产物、运行镜像或测试日志。
