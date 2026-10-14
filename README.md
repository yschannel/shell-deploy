# shell-deploy

基于 Bash 的 Ubuntu 应用部署与运行管理工具。

用户获取项目后，通过 `setup` 完成依赖检查、配置生成和编译，再通过 `start`、`stop` 等命令管理应用。项目用于 Shell 编程实验，配套一个 C++ HTTP 示例服务，演示从环境初始化到应用运行的完整流程。

> 当前适配本仓库中的指定应用，不自动识别任意项目的部署方式。示例服务提供首页和健康检查接口，尚未实现图书管理或数据存储业务。

## 功能概览

| 模块 | 已实现功能 |
| --- | --- |
| 环境初始化 | 识别 Ubuntu，检查依赖，征得用户同意后安装缺少的软件包 |
| 配置管理 | 默认或自定义端口、数据目录，校验端口范围，保留已有配置 |
| 构建 | 创建运行目录，调用 Makefile，检查可执行产物，保存构建日志 |
| 服务管理 | 启动、停止、重启、状态查询、日志查看 |
| 启动检查 | 配置与目录检查、端口占用检查、HTTP 就绪检查、重复启动保护 |
| 进程管理 | 记录并核对进程身份、清理过期记录、通过文件锁协调并发管理操作 |

## 环境要求

- Ubuntu；开发使用 Ubuntu 24.04.4 LTS。当前脚本检查系统标识为 Ubuntu，尚未限定或验证所有 Ubuntu 版本。
- Bash、GNU coreutils，以及正常挂载的 Linux `/proc`。
- C++17 编译器与下表所列工具。
- 安装依赖时需要网络连接及 `sudo` 权限；平时以普通用户运行脚本。
- 使用 Git 获取代码时需要 Git；自动化测试额外需要 Python 3。

`setup` 会检查并按需安装：

| 命令 | Ubuntu 软件包 | 用途 |
| --- | --- | --- |
| `g++` | `g++` | 编译 C++ 示例应用 |
| `make` | `make` | 执行构建规则 |
| `curl` | `curl` | 检查 HTTP 服务响应 |
| `ss` | `iproute2` | 检查监听端口 |
| `flock` | `util-linux` | 串行执行服务管理操作 |

## 快速开始

以下命令在 Ubuntu 终端执行。

### 1. 获取项目

```bash
git clone https://github.com/yschannel/shell-deploy.git
cd shell-deploy
```

### 2. 初始化

```bash
bash deploy.sh setup
```

初始化依次执行：

```text
检查系统 → 检查并按需安装依赖 → 收集配置 → 创建目录和配置文件 → 编译应用
```

- 缺少依赖时输入 `y` 同意安装；直接回车默认拒绝，初始化停止。
- 配置方式直接回车采用默认值：端口 `8080`，项目下的 `data` 目录。
- 自定义端口允许 `1024..65535`；路径支持绝对路径、相对路径以及空格。
- 在交互提示中直接输入路径，不额外添加引号。输入中的 `~` 不会自动展开。
- 任一步骤失败则停止；编译失败时显示构建日志位置。

**已有 `config.conf` 时，本次初始化会停止并保留原文件，不会应用刚输入的新配置。** 此检查发生在配置收集之后。修改配置和重新构建的方法见后文。

### 3. 启动并访问

```bash
bash deploy.sh start
```

使用默认配置时，在运行服务的 Ubuntu 中访问：

- 首页：[http://127.0.0.1:8080](http://127.0.0.1:8080)
- 健康检查：[http://127.0.0.1:8080/health](http://127.0.0.1:8080/health)

也可以在终端验证：

```bash
curl --noproxy '*' --fail --max-time 3 http://127.0.0.1:8080/health
```

预期返回 `ok`。使用自定义端口时相应修改地址。`--noproxy '*'` 让本机请求绕过环境中的代理。

示例服务仅监听 `127.0.0.1`。在 Ubuntu 虚拟机运行时，应使用虚拟机内部的浏览器或终端访问；Windows 宿主机的同名地址不指向虚拟机。

### 4. 停止

```bash
bash deploy.sh stop
```

## 命令说明

| 命令 | 行为 |
| --- | --- |
| `bash deploy.sh setup` | 交互初始化并编译 |
| `bash deploy.sh start` | 后台启动，等待约 10 秒检查就绪；已运行时不重复启动 |
| `bash deploy.sh stop` | 发送 SIGTERM，等待约 10 秒；已停止时正常提示 |
| `bash deploy.sh restart` | 停止成功后再启动 |
| `bash deploy.sh status` | 查询记录对应进程的存活与身份 |
| `bash deploy.sh logs` | 显示应用日志最后 100 行，不持续跟随 |
| `bash deploy.sh --help` | 显示可用命令 |

`status` 检查进程状态，不代表实时 HTTP 健康状态。启动时才执行 HTTP 就绪检查。

常用返回值：

| 返回值 | 含义 |
| --- | --- |
| `0` | 操作成功；或 `status` 确认运行中 |
| `1` | 常见操作失败 |
| `2` | 入口参数数量或命令错误 |
| `3` | `status` 判断未运行或 PID 记录无效 |

其他系统命令错误也可能产生非零返回值。执行命令后立即用 `echo $?` 查看。

## 配置和重新构建

`config.example` 为配置模板，`setup` 生成本地 `config.conf`。例如：

```bash
PORT=8080
DATA_DIR="./my data"
```

相对数据路径以项目根目录解析。自动生成的配置使用 Bash 的 `printf %q` 转义，出现 `my\ data` 等形式属于正常现象。

**配置是会被 `source` 执行的 Bash 文件，只使用本项目生成或自己维护的可信配置。**

修改配置时：

1. 在项目根目录执行 `bash deploy.sh stop`，确认停止成功。
2. 用 `nano config.conf` 修改端口或数据目录。
3. 如果换了数据目录，提前创建该目录并确认当前用户可写。
4. 执行 `bash deploy.sh start` 并验证响应。

例如将数据目录设为 `./my data` 后：

```bash
mkdir -p -- "./my data"
bash deploy.sh start
```

如果初始化已经生成配置，但编译失败，修正日志中的问题后可在项目根目录直接执行：

```bash
make
```

确认编译成功后再执行 `bash deploy.sh start`。修改源代码后重新构建，也应先停止正在运行的服务。手动执行 `make` 的输出显示在终端，不自动更新 `logs/build.log`。

## 项目结构

```text
shell-deploy/
├── deploy.sh              # 统一命令入口
├── scripts/
│   ├── common.sh          # 项目路径和公共提示函数
│   ├── setup.sh           # 初始化、依赖、配置与编译
│   └── service.sh         # 运行管理与进程检查
├── src/
│   └── main.cpp           # C++ HTTP 示例服务
├── Makefile               # 构建 bin/app
├── config.example         # 配置模板
├── tests/
│   └── test_service.py    # 运行管理集成测试
├── .gitignore
└── README.md
```

默认运行产物：

| 路径 | 用途 |
| --- | --- |
| `config.conf` | 用户本地配置 |
| `bin/app` | 编译后的应用 |
| `data/` | 默认数据目录 |
| `logs/build.log` | 最近一次 setup 构建日志 |
| `logs/app.log` | 追加保存的应用运行日志 |
| `run/app.pid` | 进程身份记录 |
| `run/service.lock` | 服务管理锁文件 |

以上默认产物由 `.gitignore` 排除。若自定义数据目录位于仓库内的其他路径，需另行添加忽略规则。

## 架构与关键实现

```text
用户命令
    ↓
deploy.sh
    ├── setup → common.sh + setup.sh
    │              ↓
    │       config.conf + 运行目录 + bin/app
    │
    └── start / stop / restart / status / logs
                   ↓
               service.sh
                   ↓
          应用进程、PID 记录、运行日志
```

### 初始化模块

各步骤封装为函数，通过 `函数名 || return 1` 在失败时结束流程。配置先写入临时文件，再通过硬链接生成正式配置，目标已存在时不覆盖。

### 运行管理模块

- 使用 `nohup` 和后台执行启动程序，将标准输出和错误输出追加到日志。
- 使用 `ss` 检查端口，使用 `curl` 请求 `/health`，响应为 `ok` 且进程身份仍匹配时报告就绪。
- PID 文件保存四行信息：PID、Linux 进程启动时刻、系统 boot ID、可执行文件设备号及 inode。停止前再次核对，降低 PID 复用造成误操作的风险。
- 通过 `flock` 串行执行同一项目的管理命令，等待锁超过 15 秒则失败；后台应用不持有管理锁。
- 停止超时保留记录，不自动发送 SIGKILL；启动失败后，在已确认进程身份的情况下尝试清理本次启动的进程。
- `stop`、`status`、`logs` 不依赖配置文件或当前编译产物，但仍需要对应运行记录、日志及基础命令。

纯 Bash 的身份检查与发送信号之间仍有很小的竞态窗口，不提供内核 pidfd 级别的原子性保证。

### 应用接口

```bash
bin/app --port "$PORT" --data-dir "$DATA_DIR"
```

应用以前台方式运行，由管理脚本负责后台化。替换示例应用时，应同时适配依赖清单、Makefile、启动参数和健康检查方式。

## 验证方法

### Shell 语法检查

在项目根目录逐条执行：

```bash
bash -n deploy.sh
bash -n scripts/common.sh
bash -n scripts/setup.sh
bash -n scripts/service.sh
```

### 手动验收

在新检出的项目目录中执行 `setup`，成功后按顺序验证：

```bash
bash deploy.sh start
bash deploy.sh status
bash deploy.sh start
bash deploy.sh logs
bash deploy.sh restart
bash deploy.sh stop
bash deploy.sh status
echo $?
```

预期：正常启动，重复启动不产生新实例，日志可读，重启和停止成功；最后未运行状态返回 `3`。还应验证自定义端口、含空格及绝对数据路径、拒绝安装依赖、重复初始化保留配置，以及编译失败提示。

### 自动化运行管理测试

安装好运行依赖和 Python 3 后执行：

```bash
python3 tests/test_service.py
```

测试在临时目录中编译并运行测试程序，不修改项目本地配置。当前包含 8 个测试方法，覆盖生命周期、并发启动、错误配置、端口占用、过期 PID、无关进程保护、立即退出、就绪超时和停止超时等场景，并使用含空格的路径与不同工作目录。

这组测试主要验证运行管理，不覆盖完整交互式 setup。历史交接记录说明运行管理曾在 openSUSE Leap 16.0 上测试；Ubuntu 上的完整验收应以实际执行结果为准，不能仅凭存在测试文件认定全部通过。

## 常见问题

| 现象 | 处理方式 |
| --- | --- |
| setup 提示配置已存在 | 已有配置得到保留；按上文修改配置或直接重新构建 |
| 端口已占用 | 选择空闲端口修改配置，或自行确认占用程序后处理；脚本不会停止其他服务 |
| 找不到 bin/app | 查看构建日志，修复问题后执行 make |
| 启动超时或立即退出 | 执行 logs，检查配置、目录及应用错误 |
| stop 超时 | 查看日志与进程状态，保留 PID 记录后再次尝试 stop |
| Windows 浏览器打不开虚拟机内服务 | 当前只监听 Ubuntu 回环地址，请在 Ubuntu 内部访问 |
| 本机 curl 受代理影响 | 使用上面的 `--noproxy '*'` 参数 |
| 依赖安装失败 | 检查 Ubuntu 软件源、网络和 sudo 权限后重试 |

## 分工与实验内容

| 成员 | 负责内容 |
| --- | --- |
| A | 系统与依赖检查、交互配置、目录与配置生成、构建 |
| B | 启动、停止、重启、状态、日志、进程身份与并发管理 |
| 共同 | 接口约定、示例应用集成、验收和使用文档 |

涉及的 Shell 知识包括函数、数组、条件判断、循环、返回值、重定向、后台进程、信号、trap 和文件锁。

## 当前边界与后续改进

- 仅适配指定的 Ubuntu/C++ 示例服务，未提供跨发行版部署、版本更新回滚或开机自启。
- setup 校验端口格式与范围；实际占用检查在 start 阶段。
- 重复 setup 会停止，不会自动复用已有配置继续构建；计划完善失败重试与重新配置。
- 示例 HTTP 服务用于本机教学演示，数据目录暂未承担业务存储。
- 后续可补充 setup 自动化测试、明确版本兼容范围，以及日志轮转。

