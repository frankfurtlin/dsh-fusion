> **已废弃（2026-11-24）**：正式包不再由 GitHub Actions 构建，改由 **CNB**
> 编译（未签名）+ 本机签名发布，见 [`docs/build.md`](../build.md) §14。
> 本文保留作为历史记录：仓库已从 `dsh-Go` 改名为 `dsh-pocket`，发布密钥的
> 证书主体也已从 `CN=dsh-Go` 改为 `CN=DSH Fusion`，文中提到 `CN=dsh-Go`
> 与 Actions 流程的步骤都不要再照做。

# Android APK 的 CI 构建与发布签名

本文记录 2026-11-20 起 APK 的两条产出路径：**本机脚本**（快速验证）和 **GitHub Actions**（正式出包）。
发版流程本身（构建号、三条线路、更新通道）仍以 [`docs/release.md`](../release.md) 为准，本文只补「在哪里构建、怎么签名」。

---

## 1. 背景：为什么不再在本机构建正式包

本机是 2 vCPU / 8GB，跑 release 构建的实测数据：

```text
assembleRelease #1   1326s (22 分钟)
assembleRelease #2   2793s (46 分钟)
```

原因不只是慢：

- Gradle daemon 常驻 **3.5GB RSS**，构建结束后不退出
- 两次构建期间 swap 被占满（6143/6143），整机进入直接回收
- DSH 的 cgroup 因此长时间停在 `D` 状态（`mem_cgroup_handle_over_high`），Web 端整站超时

结论：本机只做**快速验证**，正式包交给 CI。

---

## 2. 仓库关系

| 仓库 | 用途 | 权限 |
|---|---|---|
| `ccch1mneyyy/dsh-Go` | 上游，只读，**不接收 PR** | 只读 |
| `frankfurtlin/dsh-Go` | 自用维护仓库（fork），CI 与发版都在这里 | 读写 |

改动路径：本地改 → 推到 `frankfurtlin/dsh-Go` 的 `main` → 在 Actions 里触发。

---

## 3. 工作流：`.github/workflows/android-apk.yml`

### 触发方式

| 方式 | 说明 |
|---|---|
| `workflow_dispatch` | Actions 页面手动运行，可选 `mode`（release/debug）和 `abi`（`all` / `android-arm64` / `android-x64`） |
| push `v*` tag | 自动按 release + all 构建 |

默认输入是 **`release` + `all`**，即一次出两个包：

```text
app-arm64-release.apk   ≈ 70MB   （真机）
app-x64-release.apk     ≈ 73MB   （模拟器）
```

### 关键步骤

| 步骤 | 作用 |
|---|---|
| `Set up JDK 17` | AGP 9.x 要求 JDK 17+ |
| `Set up Flutter` | 固定 `3.50.0` stable |
| `Cache Gradle` / `Cache pub` | key 覆盖 `*.gradle*`、`wrapper.properties`、`gradle.properties` |
| `Restore release keystore` | 从 secrets 还原 keystore 与 `key.properties`；**缺失直接失败** |
| `Resolve build flags` | 拼 `--release --android-skip-build-dependency-validation [--target-platform …]` |
| `Build APK` | 产物存在即判成功（见 §6 坑 1） |
| `Verify release signature` | `apksigner` 打印证书，并核对 `CN=dsh-Go` 与指纹 `E5:30:D8:AD` |
| `Upload APK` | artifact，保留 14 天 |

### 拿产物

Actions → 选中的 run → 页面底部 **Artifacts** → `dshgo-release-<sha>`。

---

## 4. 发布签名

### 材料

| 项 | 值 |
|---|---|
| keystore | `/root/.config/dshgo/release.keystore`（`600`） |
| 别名 | `dshgo` |
| 算法 | RSA 4096 |
| 有效期 | 2026-11-20 → 2054-04-07 |
| 证书 SHA-256 | `E5:30:D8:AD:73:CB:6E:AF:E4:B9:D3:D6:E4:4A:C0:95:AC:FD:2D:11:A5:F6:C2:74:2C:E1:C5:D1:70:31:70:6F` |
| 签名方案 | v1 + v2 + v3 全开（`app/build.gradle.kts`） |

### GitHub Secrets（仓库 Settings → Secrets → Actions）

| Secret | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 的 base64（`base64 -w0 release.keystore`） |
| `ANDROID_KEY_PROPERTIES` | `key.properties` 全文；CI 会把 `storeFile` 改写成 `release.keystore` |

工作流把 keystore 写到 `app/android/app/release.keystore`，`key.properties` 写到 `app/android/key.properties` —— 对应 `build.gradle.kts` 里 `file(storeFile)` 相对 `app/android/app` 的解析。

### 签名不可用时会怎样

- **CI**：`Restore release keystore` 直接 `::error::` 失败，不会产出 debug 签名的包。
- **本机**：`build.gradle.kts` 在缺少 `key.properties` 时回落到 debug key（仅供本地调试，不可发布）。

### 备份与恢复

加密备份（AES-256-CBC + PBKDF2 600k 迭代）已上传 COS；口令离线保存，**不要和链接放在一起**。

```sh
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in dshgo-release-keystore-<date>.tar.gz.enc -out ks.tar.gz -pass pass:<口令>
tar xzf ks.tar.gz
# release.keystore → app/android/app/
# key.properties   → app/android/
```

> ⚠️ 这是该应用**唯一的发布身份**。丢失后已安装的旧版本无法覆盖升级，只能卸载重装。轮换密钥必须换 package name 或走应用商店的密钥轮换流程。

---

## 5. 本机脚本（两条，用途不同）

| 脚本 | 用途 | 说明 |
|---|---|---|
| `tooling/build-apk.sh` | **正式构建入口**（见 `docs/release.md`） | flavor 化（arm64/x64/all）、构建号、runtime 校验、结束自动 `gradlew --stop` |
| `tools/build-apk.sh` | agent / 调试用（见 `docs/toolchain.md`） | `--detach` 丢 systemd、`--pub-get-only`、`--all-abis` |

2026-11-20 对 `tools/build-apk.sh` 的改动：

- 默认 `TARGET_PLATFORM=android-arm64`，需要双 ABI 时显式 `--all-abis`
- 用构建开始时打的 `STAMP` 判断「本轮产出的 APK」，修掉 per-ABI 输出导致的假失败
- 构建结束 `./gradlew --stop`（`--keep-daemon` 可关）
- `--detach` 的 systemd 单元加 `MemoryHigh=3G / MemoryMax=4G`，避免拖垮宿主

`app/android/gradle.properties` 增加的全局项：

```properties
org.gradle.caching=true
org.gradle.workers.max=2        # 对齐 2 核
org.gradle.parallel=true
org.gradle.configuration-cache=true
org.gradle.configuration-cache.problems=warn
org.gradle.vfs.watch=false
```

---

## 6. 已知坑

1. **per-ABI 输出导致假失败**
   Flutter 3.5x 在 `abiFilters` 按 flavor 分块的项目里会输出 `app-<abi>-release.apk`，然后找不到 `app-release.apk` 就返回 1。
   → 判据改成「本轮有 APK 就成功」，本机脚本与 CI 都做了。

2. **`--target-platform android-arm64` 不一定只出一个包**
   本项目 `build.gradle.kts` 按 flavor 写 `abiFilters`，两个 flavor 都构建时仍会各出一个包。要真正单包，必须改 flavor 配置，不是加参数。

3. **Gradle daemon 常驻 3.5GB**
   构建结束后必须 `./gradlew --stop`，否则它会一直占着内存和 swap。

4. **首次 CI 约 22 分钟**
   无 Gradle 缓存时与 4 核本机差不多；缓存命中后主要省 dex/R8。shader 编译是固定成本。

5. **`flutter build` 的 stdout 很长**
   CI 里 `tee build-ci.log` 只为失败时上传；不要把整段日志塞进 artifact。

---

## 7. 验收清单

出包后逐条核对：

- [ ] run 状态 `success`，`Build APK` / `Verify release signature` / `Upload APK` 三步都绿
- [ ] artifact 里两个包都在，体积在 70MB / 73MB 量级
- [ ] `apksigner verify --print-certs` 显示 `CN=dsh-Go` 与指纹 `E5:30:D8:AD…`
- [ ] `versionCode` 符合 `docs/release.md` 的构建号公式
- [ ] 真机覆盖安装成功（同签名才能覆盖）
