# shell-deploy

Ubuntu 环境下的 Bash 部署与运行管理工具。已提供 A 的初始化模块和 B 的运行管理模块，完整 Ubuntu 验收仍待完成。

Ubuntu 上的正常入口为 `bash deploy.sh setup`，初始化成功后执行 `bash deploy.sh start`。

## 开发阶段运行

需要 Bash、g++、make、curl、iproute2（`ss`）、util-linux（`flock`）和 coreutils。Ubuntu 的具体支持版本仍待双方确定。

在项目根目录执行（已有 `config.conf` 时保留原配置）：

```bash
test -e config.conf || cp config.example config.conf
mkdir -p data
make
bash deploy.sh start
bash deploy.sh status
bash deploy.sh logs
bash deploy.sh restart
bash deploy.sh stop
```

自定义配置时编辑 `config.conf`，并预先创建数据目录。例如：

```bash
PORT=8080
DATA_DIR="./my data"
```

端口必须为 1024..65535；相对数据路径以项目根目录解析，含空格的路径需要引用。配置是 **可信的 Bash 代码**，读取时会执行，只使用自己维护的配置。A 生成配置时，推荐用 `printf 'PORT=%q\nDATA_DIR=%q\n' "$PORT" "$DATA_DIR"` 保存值。

应用使用 `bin/app --port "$PORT" --data-dir "$DATA_DIR"`，以前台方式运行，由管理脚本放入后台。就绪条件是 `/health` 成功返回 `ok`，等待约 10 秒。访问地址为 `http://127.0.0.1:8080`（使用自定义端口时相应修改）。当前示例应用只监听回环地址，只能从服务所在机器访问。

## 管理行为及接口

- 公共函数：`start_service`、`stop_service`、`restart_service`、`status_service`、`show_logs`，位于 `scripts/service.sh`，可直接 source 后调用。
- `start` 检查配置、可执行文件、数据目录、端口与就绪状态；重复启动不会创建第二个实例。
- `stop` 发送 SIGTERM，等待约 10 秒。超时返回失败、保留记录，不自动发送 SIGKILL。再次执行 `stop` 可以重试。
- `restart` 只有在停止成功后才启动；同一项目的管理命令通过 `flock` 串行执行，等待锁超过 15 秒则失败。
- `status` 校验真实进程身份，运行时返回 0，未运行或 PID 记录无效时返回 3。这表示进程状态，不表示实时 HTTP 健康状态。
- `logs` 显示 `logs/app.log` 最后 100 行，不持续跟随；日志不存在时明确报错。日志以追加方式写入。
- 启动失败会尝试停止本次启动的进程；清理超时则保留 PID 记录供重试。错误消息提供日志位置。
- `stop`、`status`、`logs` 不依赖配置或编译产物，因此删除配置或重新编译后仍可管理已有进程。
- 其他失败返回非零；入口参数错误返回 2。支持从其他工作目录调用，也支持项目路径包含空格。

`run/app.pid` 为四行内部记录：PID、Linux 进程启动时刻、系统 boot ID、可执行文件的设备号及 inode。它不只是一个 PID 数字。停止前重新校验记录，避免对已复用的 PID 发信号；过期记录不会触发停止操作。记录和锁文件仅供本工具维护，请勿手动伪造。纯 Bash 的校验与发信号之间仍存在很小的竞态窗口，不提供内核 pidfd 级别的原子性保证。

## 与 A 集成

`deploy.sh setup` 加载 `scripts/common.sh`、`scripts/setup.sh` 并调用 `setup_project`。A 的模块负责系统/依赖检查、交互配置、运行目录创建、编译以及重复初始化处理。B 没有修改这两个模块。`config.example` 与 A 使用的 Bash 配置格式兼容，其余约定见上文。

交接时需由 A 处理：依赖检查补充 `ss`（iproute2）和 `flock`（util-linux）；自定义绝对路径赋值应为 `DATA_DIR="$data_input"`，当前误写为 `DATA_DIR="data_input"`；配置生成失败分支的清理参数应为 `"$temp_file"`；配置交互阶段还需检查端口占用。B 的 `start` 已独立检查端口占用和运行依赖。

运行管理集成测试在 openSUSE Leap 16.0 上执行；不代表已经完成 Ubuntu 的完整初始化验收。

## 运行管理回归测试

```bash
python3 tests/test_service.py
```

测试需要上述依赖和 Python 3，在临时目录编译并运行测试服务，不修改项目本地配置。覆盖生命周期、并发启动、异常配置、端口占用、过期 PID、无关进程保护、立即退出、就绪超时、停止超时、含空格路径以及从其他目录调用。
