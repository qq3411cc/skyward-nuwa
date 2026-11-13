# Skyward for Xiaomi 13 Pro (nuwa)

小米 13 Pro（`nuwa`，本机系统 OS4.0.5.0.XPCCNXM，Android 17）可用的 Skyward recovery：**data 解密能用了**。

基于 [kirklin/skyward](https://github.com/kirklin/skyward) v0.2.0（GPL-3.0）自编译，补丁与自用改动沿用 [mariusarva/skyward-pudding](https://github.com/mariusarva/skyward-pudding) 的做法，设备配置按本机重做。

## 这一版做了什么

上游把 `nuwa` 列在「施工中」，并明说「不会解密 data 分区」。原因是 `devices/nuwa.toml` 里一条解密要用的 `[[service]]` 都没有：skyward 的解密实现（`crates/skyward-crypto`）编在 `/system/bin/recovery` 里，但要把手机 vendor 分区自己的 keymint / gatekeeper / qseecomd 拉起来才有密钥可用。

本机核对到的支撑事实（OS4.0.5.0.XPCCNXM，Android 17）：

| # | 事实 | 判据 |
|---|---|---|
| 1 | 密钥服务是 `/vendor/bin/hw/android.hardware.security.keymint-service-qti`，注册 `IKeyMintDevice`、`IRemotelyProvisionedComponent`、`ISecureClock`、`ISharedSecret` 四条 | `service list` 的 65～68 项 |
| 2 | 凭据服务是**旧的 HIDL 1.0** 那一类：`/vendor/bin/hw/android.hardware.gatekeeper@1.0-service-qti` | `service list` 里只有框架的 `android.service.gatekeeper.IGateKeeperService`，HAL 在 hwservicemanager 里 |
| 3 | 因此必须先起 `hwservicemanager`，recovery 自己不带，用装机系统里的 `/system_ext/bin/hwservicemanager` | `ls /system_ext/bin/hwservicemanager` |
| 4 | keymint 的 TA 由 qseecomd 从 `/vendor/firmware_mnt/image` 加载，原厂 recovery 不挂 modem 分区 | `strings /vendor/lib64/libkeymasterdeviceutils.so` 里有 `/vendor/firmware_mnt/image` |
| 5 | 用户 secret 绑在 **secdis + gatekeeper** 上，不是 weaver：`/data/system_de/0/spblob/184413d7cdf608b9.secdis` + `.pwd`，没有 `.weaver` | `ls /data/system_de/0/spblob` |
| 6 | 本机没有 weaver HAL，也不需要 weaver 回退 | `ls /vendor/bin/hw | grep weaver` 为空 |

所以 `devices/nuwa.toml` 补了六条服务（顺序即启动顺序）：

```
post_boot → touch_report → touchsensor
          → qseecomd                       (ready: vendor.sys.listeners.registered)
          → keymint-service-qti            (ready: IKeyMintDevice/default)
          → hwservicemanager               (ready: hwservicemanager.ready)
          → gatekeeper@1.0-service-qti     (ready: gatekeeper@1.0::IGatekeeper/default)
          → boot@1.2-service               (ready: boot@1.2::IBootControl/default)
```

以及两条挂载配置：

- `[firmware] partition = "modem"` —— 把 modem 挂到 `/vendor/firmware_mnt`，qseecomd 才找得到 keymaster 的 TA
- `[partitions] mounted = ["persist"]` —— 不能回滚的密钥要用的文件在 persist（`/mnt/vendor/persist/keytemp/keyinfo.txt`、`tee_priv_key`）

其余沿用上游 `nuwa.toml`：屏幕 1440×3200 / 560、触摸 `fts_touch_spi` + `touch_report` + `touchsensor`、WLAN `qca_cld3_kiwi_v2`、振动 `qcom-haptics`。

## 下载与刷入

到 [Releases](../../releases) 下最新的 `.img` 与 `SHA256SUMS`，校验后：

```sh
fastboot devices
fastboot getvar current-slot                 # 本机是 a
fastboot flash recovery_a skyward-nuwa-<日期>-<发布号>-OS4.0.5.0.XPCCNXM.img
fastboot reboot
adb reboot recovery                          # 从系统进
```

Release 里同时挂一份 `.zip`（只含一个 `.img`）：那是恢复里「设置 → 版本更新」认的格式，
从恢复里直接更新就用它，不用电脑。

- 需要已解锁 BL
- 只动 recovery 分区，`boot` / `init_boot` / `vendor_boot` 不碰
- 出问题刷回原厂或第三方 recovery 即可恢复
- 原厂 recovery 镜像（本版打包所用的底座，OS3.0.312.0.WMBCNXM）的 SHA-256：`04431f150316d32fc5fd38ac8caf7e48ee271fa47cd23a28ad7e067e5fcde273`

## 校验

镜像由 CI 现编，`SHA256SUMS` 随 Release 一起发布。自己复现：

```sh
sha256sum -c SHA256SUMS
```

## 从源码重建

```sh
# 1) 取上游
curl -L -o skyward.tar.gz https://codeload.github.com/kirklin/skyward/tar.gz/refs/tags/v0.2.0
tar xzf skyward.tar.gz && cd skyward-0.2.0

# 2) 打补丁（mariusarva/skyward-pudding 那一份，按提交钉死），再打本仓库的补丁
curl -L -o ../skyward.patch \
  https://raw.githubusercontent.com/mariusarva/skyward-pudding/ab6cf82cda6cef28457ae845901babf1c17dd0bb/patches/skyward-pudding-v0.2.49.patch
echo "20f169da07c912f5a5f9bdbae2df1e8bd4778fd8a2d9254d8af63f690dda6f9e  ../skyward.patch" | sha256sum -c -
patch -p1 < ../skyward.patch
patch -p1 < ../patches/skyward-nuwa-extra.patch
cp ../devices/nuwa.toml devices/nuwa.toml

# 3) 交叉编译（NDK r29 + cargo-ndk）
rustup target add aarch64-linux-android
cargo ndk -t arm64-v8a --platform 30 build --release -p skyward
RUSTFLAGS="-C target-feature=+crt-static" \
  cargo ndk -t arm64-v8a --platform 30 build --release -p skyward-system-init \
  --target-dir target/system-init
cargo build --release -p skyward-pack

# 4) 取原厂 recovery 并打包
target/release/skyward-pack stock --config devices/nuwa.toml --out stock/recovery.img
target/release/skyward-pack recovery \
  --stock stock/recovery.img \
  --binary target/aarch64-linux-android/release/skyward \
  --system-init target/system-init/aarch64-linux-android/release/system-init \
  --config devices/nuwa.toml \
  --font resources/fonts/MiSansVF.ttf \
  --mono resources/fonts/KirkMono-Regular.ttf \
  --mono-license resources/fonts/KirkMono-OFL.txt \
  --out skyward-nuwa.img
```

`skyward-pack stock` 直接从小米服务器上 `OS3.0.312.0.WMBCNXM` 的完整更新包里取 recovery 分区，只读这个分区所占的那 23 MB，并按 `devices/nuwa.toml` 的 `[stock] recovery` 核对 SHA-256。

`tools/payload_get.py` 是不依赖 Rust 的等价实现，用于只想把原厂 recovery 取下来的场合：

```sh
python3 tools/payload_get.py "<ota.zip 直链>" recovery recovery_stock.img \
  --sha256 04431f150316d32fc5fd38ac8caf7e48ee271fa47cd23a28ad7e067e5fcde273
```

## 上游更新了怎么办

代码 = **上游源码的某个 tag** + **mariusarva/skyward-pudding 的补丁** + **本仓库的补丁**。三者都钉死在 `upstream.json`：

```json
{
  "base":    { "repository": "kirklin/skyward", "tag": "v0.2.0", "tarball_sha256": "f46e0da3…" },
  "patches": { "repository": "mariusarva/skyward-pudding", "commit": "ab6cf82…",
               "path": "patches/skyward-pudding-v0.2.49.patch", "sha256": "20f169da…" }
}
```

构建只读这个文件：源码包哈希或补丁哈希对不上直接失败，不硬写任何版本号。

**自动**：`.github/workflows/sync-upstream.yml` 每天 04:00 查一次上游 `patches/` 目录，取版本号最大的那个补丁：

- 与钉的一样 → 结束
- 不一样 → 下新补丁，先 `--dry-run` 试打「新补丁 + `patches/skyward-nuwa-extra.patch`」
  - 都过得去 → 改 `upstream.json` 的 `commit` / `path` / `sha256`，提交，再 `gh workflow run build.yml` 出包
  - 有冲突 → 开 issue 把 `Hunk #N FAILED` 贴出来，运行标红等人合

**手动**：

```sh
scripts/sync-upstream.sh                  # 查最新补丁，与钉的比
scripts/sync-upstream.sh v0.2.52          # 指定补丁版本试打，报冲突位置
scripts/sync-upstream.sh v0.2.52 --write  # 打得进去就写回 upstream.json
```

合完冲突后重出补丁的办法见 `docs/开发记录.md`。

## 恢复里的「版本更新」

`devices/nuwa.toml` 的 `[update] skyward` 指向**本仓库**的 `docs/update.json`（走 `gh-proxy.com` 镜像）：

```toml
[update]
skyward = "https://gh-proxy.com/https://raw.githubusercontent.com/qq3411cc/skyward-nuwa/main/docs/update.json"
```

这个文件由 CI 每次构建后自动改写（tag、zip 的名字、大小、sha256、两个下载地址），所以恢复里点「版本更新」看到的就是本仓库最新那版。**不要**让它去问上游：上游的包是 pudding 的，装上去会把这份的改动全冲掉。

## 用 GitHub Actions 构建

`.github/workflows/build.yml`：按 tag（`v*`）或手动触发，整份镜像在 GitHub 的机器上编出来，产出 `skyward-nuwa-<日期>-<tag>-OS4.0.5.0.XPCCNXM.img` + `SHA256SUMS`；tag 触发时自动挂到该 tag 的 Release。不需要任何 secret。

## 已知限制

- 只在 `nuwa` / OS4.0.5.0.XPCCNXM 上核对过配置，其他机型不要刷
- 本机 ROM 的 `/data` **没有加密**（fstab 无 `fileencryption`、无 `metadata_encryption`、`/data/misc/vold` 无 user_keys），所以 recovery 里不需要密码，直接挂上就能读写；加密的机器仍走 keymint + gatekeeper 那条路
- 底座是 OS3.0.312.0.WMBCNXM 的原厂 recovery ramdisk（公开可下载的最新一版），装机的系统版本与它不同没关系：recovery 挂的是装机系统的分区，版本是运行时从属性读出来的
- 没有 weaver，所以走的是 gatekeeper + keymint 那条路；`ro.special_edition` 为空的机型都适用
- 本机路由器的 DNS（192.168.50.1）不答 53，recovery 里没有 netd，所以 WLAN 的联网判定要公共 DNS 兜底（`223.5.5.5 / 119.29.29.29 / 8.8.8.8`），这一段已编进镜像
- 记住密码（锁屏与 WiFi）都是**明文**存在 `/metadata`（0600，root），恢复出厂会清
- 触摸面板驱动要几秒才起来，前几秒只能按键，之后自动恢复（等待窗口 10 秒）

## 许可

沿用上游 GPL-3.0。本仓库的设备配置、脚本与文档同样以 GPL-3.0 发布；补丁取自 [mariusarva/skyward-pudding](https://github.com/mariusarva/skyward-pudding)（GPL-3.0，按提交钉死并核对 SHA-256），镜像内含 AOSP recovery 组件与 Skyward，来源与修改见 `docs/开发记录.md`。
