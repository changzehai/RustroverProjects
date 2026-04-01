# RustRover + J-Link 一键调试 STM32 教程

本文基于当前工程，完整说明如何在 RustRover 中实现“一键使用 J-Link 调试 STM32”，并把相关脚本、配置、运行项和原理全部整理出来，方便直接改写成教程博客。

本文覆盖：

- 工程中涉及的所有关键文件和位置
- RustRover 调试配置的完整内容
- J-Link 启动和下载脚本的完整内容
- 交叉编译、烧录、连接调试器的原理
- 整体流程图
- 常见问题和排查方法

## 一、目标效果

最终要实现的体验是：

1. 在 RustRover 中点击一次 `J-Link Debug`
2. IDE 自动编译 STM32 固件
3. 自动启动 `JLinkGDBServerCLExe`
4. 自动把 ELF 下载到 STM32
5. 自动连接 `arm-none-eabi-gdb`
6. 直接在 RustRover 里断点、单步、查看变量和寄存器

## 二、这套方案的核心思路

RustRover 本身主要负责 GDB 前端，也就是：

- 管理断点
- 控制单步执行
- 展示变量、寄存器、调用栈

但它不会自动替你完成这些嵌入式特有动作：

- 选择 STM32 芯片型号
- 启动 J-Link GDB Server
- 等待 GDB Server 端口就绪
- 把 ELF 下载进 Flash

所以这套方案的本质是把任务拆成两层：

### 第一层：脚本负责准备调试环境

脚本完成这些动作：

- 交叉编译 ELF
- 启动 `JLinkGDBServerCLExe`
- 用 `arm-none-eabi-gdb` 批处理执行 `load`
- 让目标芯片复位并停住

### 第二层：RustRover 接管调试会话

RustRover 再做这些动作：

- 连接 `localhost:2331`
- 加载 ELF 符号
- 提供完整 IDE 调试体验

所以，一键调试并不是 RustRover 直接“懂 J-Link + STM32”，而是：

`RustRover 调试配置 + 前置脚本 + J-Link GDB Server + ARM GDB`

共同组成了一条自动化链路。

## 三、工程中涉及的文件和位置

下面这些文件参与了整个一键调试流程。

### 1. Cargo 配置

- [`usart/Cargo.toml`](usart/Cargo.toml)
- [`usart/.cargo/config.toml`](usart/.cargo/config.toml)
- [`usart/memory.x`](usart/memory.x)

### 2. Rust 入口代码

- [`usart/src/main.rs`](usart/src/main.rs)

### 3. RustRover 运行配置

- [`usart/.run/J-Link_Server.run.xml`](usart/.run/J-Link_Server.run.xml)
- [`usart/.run/J-Link_Debug.run.xml`](usart/.run/J-Link_Debug.run.xml)

### 4. 自动化脚本

- [`usart/scripts/debug-server.sh`](usart/scripts/debug-server.sh)
- [`usart/scripts/debug-stop.sh`](usart/scripts/debug-stop.sh)
- [`usart/scripts/sync-project-name.sh`](usart/scripts/sync-project-name.sh)

### 5. 调试日志

- [`usart/.jlink-gdb.log`](usart/.jlink-gdb.log)
- [`usart/.jlink-load.log`](usart/.jlink-load.log)

## 四、工程截图

下面这张图展示了当前工程在 RustRover 中的实际布局，以及一键调试时会用到的几个核心文件：

- `.run/J-Link_Debug.run.xml`
- `.run/J-Link_Server.run.xml`
- `scripts/debug-server.sh`
- `scripts/debug-stop.sh`
- `scripts/sync-project-name.sh`
- `src/main.rs`

![RustRover 工程截图](./JLINK_DEBUG.assets/rustrover-project.png)

## 五、工程配置的完整内容

这一节把当前项目里真正起作用的配置全部列出来。

### 1. `Cargo.toml`

文件位置：

- [`usart/Cargo.toml`](usart/Cargo.toml)

完整内容：

```toml
[package]
name = "usart"
version = "0.1.0"
edition = "2024"

[[bin]]
name = "usart"
path = "src/main.rs"
test = false
bench = false

[dependencies]
cortex-m = "0.7.7"
cortex-m-rt = "0.7.5"
panic-halt = "1.0.0"
stm32f4 = { version = "0.16.0", features = ["stm32f407", "rt"] }
stm32f4xx-hal = { version = "0.23.0", features = ["stm32f407"] }

[profile.dev]
codegen-units = 1
debug = 2
incremental = false
lto = false

[profile.release]
codegen-units = 1
debug = 2
lto = true
```

这里最关键的是：

```toml
[[bin]]
name = "usart"
path = "src/main.rs"
test = false
bench = false
```

原因是 embedded Rust 工程通常是：

- `#![no_std]`
- `#![no_main]`

而如果 IDE 不小心触发 `cargo test` 风格构建，就会尝试引入 `test` crate。  
对于 `thumbv7em-none-eabihf` 这样的裸机目标，没有标准测试运行时，所以会报：

```text
can't find crate for `test`
```

显式关闭 `test` 和 `bench` 后，就能避免这个问题。

### 2. `.cargo/config.toml`

文件位置：

- [`usart/.cargo/config.toml`](usart/.cargo/config.toml)

完整内容：

```toml
[build]
target = "thumbv7em-none-eabihf"

[target.thumbv7em-none-eabihf]
rustflags = [
  "-C",
  "link-arg=--nmagic",
  "-C",
  "link-arg=-Tlink.x",
]
```

这段配置做了两件关键的事：

1. 固定默认构建目标为 `thumbv7em-none-eabihf`
2. 链接时显式指定 `link.x`

作用是让 `cargo build` 生成 STM32F4 运行所需的裸机 ELF，而不是宿主机可执行文件。

### 3. `memory.x`

文件位置：

- [`usart/memory.x`](usart/memory.x)

完整内容：

```ld
MEMORY
{
  FLASH : ORIGIN = 0x08000000, LENGTH = 512K
  RAM : ORIGIN = 0x20000000, LENGTH = 128K
}
```

这个文件告诉链接器目标芯片的内存布局。

如果这里的 Flash/RAM 配置和目标板不一致，常见后果包括：

- 程序无法正确下载
- 程序运行异常
- 调试符号和地址不匹配

### 4. `src/main.rs`

文件位置：

- [`usart/src/main.rs`](usart/src/main.rs)

完整内容：

```rust
#![no_main]
#![no_std]

use cortex_m_rt::entry;
use panic_halt as _;
use stm32f4::stm32f407 as pac;
use stm32f4xx_hal::{
    prelude::*,
    rcc::Config,
};

#[entry]
fn main() -> ! {
    let dp = take_device_peripherals();
    let cp = take_core_peripherals();

    let mut rcc = freeze_rcc(dp.RCC);
    let mut delay = make_delay(cp.SYST, &rcc.clocks);

    let gpioe = dp.GPIOE.split(&mut rcc);
    let mut led1 = gpioe.pe8.into_push_pull_output();
    let mut led2 = gpioe.pe9.into_push_pull_output();
    let mut led3 = gpioe.pe10.into_push_pull_output();
    let mut led4 = gpioe.pe11.into_push_pull_output();

    loop {
        led1.set_high();
        delay.delay_ms(500);
        led1.set_low();

        led2.set_high();
        delay.delay_ms(500);
        led2.set_low();

        led3.set_high();
        delay.delay_ms(500);
        led3.set_low();

        led4.set_high();
        delay.delay_ms(500);
        led4.set_low();
    }
}

#[inline(never)]
fn take_device_peripherals() -> pac::Peripherals {
    pac::Peripherals::take().unwrap()
}

#[inline(never)]
fn take_core_peripherals() -> cortex_m::Peripherals {
    cortex_m::Peripherals::take().unwrap()
}

#[inline(never)]
fn freeze_rcc(rcc: pac::RCC) -> stm32f4xx_hal::rcc::Rcc {
    rcc.freeze(Config::hsi().sysclk(84.MHz()))
}

#[inline(never)]
fn make_delay(
    syst: cortex_m::peripheral::SYST,
    clocks: &stm32f4xx_hal::rcc::Clocks,
) -> stm32f4xx_hal::timer::delay::SysDelay {
    syst.delay(clocks)
}
```

代码本身不是一键调试的重点，但这里的 `#![no_main]` 和 `#![no_std]` 解释了为什么这类项目不能沿用桌面 Rust 工程默认的 `cargo test` 逻辑。

## 六、RustRover 调试配置的完整内容

这一节是整个教程里最适合直接贴到博客中的部分。

### 1. `J-Link Server.run.xml`

文件位置：

- [`usart/.run/J-Link_Server.run.xml`](usart/.run/J-Link_Server.run.xml)

完整内容：

```xml
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="J-Link Server" type="ShConfigurationType">
    <option name="SCRIPT_TEXT" value="" />
    <option name="SCRIPT_PATH" value="$PROJECT_DIR$/scripts/debug-server.sh" />
    <option name="SCRIPT_WORKING_DIRECTORY" value="$PROJECT_DIR$" />
    <option name="INTERPRETER_PATH" value="/bin/zsh" />
    <option name="INDEPENDENT_SCRIPT_PATH" value="true" />
    <option name="INDEPENDENT_SCRIPT_WORKING_DIRECTORY" value="true" />
    <envs />
    <method v="2" />
  </configuration>
</component>
```

这个运行配置本质上就是让 RustRover 调用一个 shell 脚本：

- 脚本路径：`$PROJECT_DIR$/scripts/debug-server.sh`
- 解释器：`/bin/zsh`

它的职责不是打开 IDE 调试面板，而是“准备好远程调试环境”。

### 2. `J-Link Debug.run.xml`

文件位置：

- [`usart/.run/J-Link_Debug.run.xml`](usart/.run/J-Link_Debug.run.xml)

完整内容：

```xml
<component name="ProjectRunConfigurationManager">
  <configuration
      default="false"
      name="J-Link Debug"
      type="RsRemoteRunConfiguration"
      debuggerKind="USER_GDB"
      userDebuggerPath="/Applications/ArmGNUToolchain/15.2.rel1/arm-none-eabi/bin/arm-none-eabi-gdb"
      remoteCommand="localhost:2331"
      symbolFile="$PROJECT_DIR$/target/thumbv7em-none-eabihf/debug/__rustrover_current.elf"
      sysroot="">
    <method v="2">
      <option
          name="RunConfigurationTask"
          enabled="true"
          run_configuration_name="J-Link Server"
          run_configuration_type="ShConfigurationType" />
    </method>
  </configuration>
</component>
```

这里的关键字段分别表示：

- `type="RsRemoteRunConfiguration"`
  - 这是 RustRover 的远程调试配置
- `debuggerKind="USER_GDB"`
  - 使用用户指定的 GDB
- `userDebuggerPath=".../arm-none-eabi-gdb"`
  - 这里必须是 ARM 工具链里的 GDB，而不是系统默认 GDB
- `remoteCommand="localhost:2331"`
  - GDB 连接到本机 2331 端口，也就是 J-Link GDB Server
- `symbolFile=".../__rustrover_current.elf"`
  - IDE 用这个 ELF 加载调试符号
- `RunConfigurationTask`
  - 在真正调试前先运行 `J-Link Server`

所以 `J-Link Debug` 并不是直接自己启动 J-Link，而是：

1. 先跑 `J-Link Server`
2. 再连接已经准备好的 GDB server

## 七、脚本的完整内容

### 1. `scripts/debug-server.sh`

文件位置：

- [`usart/scripts/debug-server.sh`](usart/scripts/debug-server.sh)

完整内容：

```zsh
#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="thumbv7em-none-eabihf"
PROJECT_NAME="${PWD:t}"
SYMBOL_LINK="target/${TARGET}/debug/__rustrover_current.elf"
GDB_BIN="/Applications/ArmGNUToolchain/15.2.rel1/arm-none-eabi/bin/arm-none-eabi-gdb"
JLINK_GDB_SERVER="/Applications/SEGGER/JLink/JLinkGDBServerCLExe"
DEVICE="STM32F407ZE"
INTERFACE="SWD"
SPEED="4000"
GDB_PORT="2331"
SWO_PORT="2332"
TELNET_PORT="2333"
PID_FILE=".jlink-gdb.pid"
SERVER_LOG=".jlink-gdb.log"
LOAD_LOG=".jlink-load.log"

/bin/zsh scripts/debug-stop.sh

/bin/zsh scripts/sync-project-name.sh

cargo build --target "${TARGET}"

BINARY="target/${TARGET}/debug/${PROJECT_NAME}"

if [[ ! -f "${BINARY}" ]]; then
  echo "Missing ELF file: ${BINARY}" >&2
  exit 1
fi

ln -sfn "${PROJECT_NAME}" "${SYMBOL_LINK}"

if [[ ! -x "${GDB_BIN}" ]]; then
  echo "Missing GDB binary: ${GDB_BIN}" >&2
  exit 1
fi

nohup "${JLINK_GDB_SERVER}" \
  -device "${DEVICE}" \
  -if "${INTERFACE}" \
  -speed "${SPEED}" \
  -port "${GDB_PORT}" \
  -swoport "${SWO_PORT}" \
  -telnetport "${TELNET_PORT}" \
  -noir >"${SERVER_LOG}" 2>&1 &
server_pid=$!
echo "${server_pid}" > "${PID_FILE}"

for _ in {1..50}; do
  if grep -q "Listening on TCP/IP port ${GDB_PORT}" "${SERVER_LOG}" 2>/dev/null; then
    break
  fi
  if ! kill -0 "${server_pid}" 2>/dev/null; then
    echo "J-Link GDB server exited unexpectedly. See ${SERVER_LOG}:" >&2
    cat "${SERVER_LOG}" >&2 || true
    exit 1
  fi
  sleep 0.2
done

if ! grep -q "Listening on TCP/IP port ${GDB_PORT}" "${SERVER_LOG}" 2>/dev/null; then
  echo "Timed out waiting for J-Link GDB server to start. See ${SERVER_LOG}:" >&2
  cat "${SERVER_LOG}" >&2 || true
  exit 1
fi

if ! "${GDB_BIN}" \
  -q \
  -nx \
  -batch \
  "${BINARY}" \
  -ex "target extended-remote localhost:${GDB_PORT}" \
  -ex "monitor reset" \
  -ex "monitor halt" \
  -ex "load" \
  -ex "monitor reset" \
  -ex "monitor halt" \
  -ex "disconnect" >"${LOAD_LOG}" 2>&1; then
  echo "ELF load failed. See ${LOAD_LOG}:" >&2
  cat "${LOAD_LOG}" >&2 || true
  exit 1
fi
```

这个脚本是整个方案的核心。

#### 这段脚本做了什么

从头到尾，它依次执行：

1. 切换到工程根目录
2. 定义目标平台、GDB 路径、J-Link Server 路径、芯片型号、端口等参数
3. 先调用 `debug-stop.sh` 清理旧进程
4. 再调用 `sync-project-name.sh`，保证包名和目录名一致
5. 执行 `cargo build --target thumbv7em-none-eabihf`
6. 检查 ELF 是否存在
7. 创建 `__rustrover_current.elf` 符号链接
8. 启动 `JLinkGDBServerCLExe`
9. 循环等待 `2331` 端口就绪
10. 用 `arm-none-eabi-gdb` 连接 server 并执行 `load`

#### 几个关键变量的意义

```zsh
TARGET="thumbv7em-none-eabihf"
```

表示交叉编译目标架构。

```zsh
GDB_BIN="/Applications/ArmGNUToolchain/15.2.rel1/arm-none-eabi/bin/arm-none-eabi-gdb"
```

表示真正使用的 GDB 必须是 ARM 交叉工具链版本。

```zsh
JLINK_GDB_SERVER="/Applications/SEGGER/JLink/JLinkGDBServerCLExe"
```

表示实际与 J-Link 探针通信的服务端程序。

```zsh
DEVICE="STM32F407ZE"
INTERFACE="SWD"
```

告诉 J-Link：

- 目标芯片是什么
- 用哪种调试接口连接

```zsh
GDB_PORT="2331"
SWO_PORT="2332"
TELNET_PORT="2333"
```

这些端口分别用于：

- `2331`：GDB 连接
- `2332`：SWO
- `2333`：Telnet 控制台

#### 为什么要先 `load`

脚本里最重要的一段是：

```zsh
"${GDB_BIN}" \
  -q \
  -nx \
  -batch \
  "${BINARY}" \
  -ex "target extended-remote localhost:${GDB_PORT}" \
  -ex "monitor reset" \
  -ex "monitor halt" \
  -ex "load" \
  -ex "monitor reset" \
  -ex "monitor halt" \
  -ex "disconnect"
```

这表示脚本在 RustRover 接管之前，先用 GDB 完成一次自动下载。

也就是说，RustRover 真正开始调试时：

- 固件已经烧写到 Flash
- 芯片已经连接到 J-Link GDB Server
- 芯片已经停在一个可调试状态

这样 IDE 只需要做“连接 + 显示调试界面”。

### 2. `scripts/debug-stop.sh`

文件位置：

- [`usart/scripts/debug-stop.sh`](usart/scripts/debug-stop.sh)

完整内容：

```zsh
#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

PID_FILE=".jlink-gdb.pid"
GDB_PORT="2331"

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill "${pid}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
fi

pkill -f "JLinkGDBServerCLExe.*-port ${GDB_PORT}" 2>/dev/null || true
```

这个脚本的作用是防止重复启动 J-Link GDB Server。

如果你上一次调试结束后 server 没有退出，这里就会：

- 根据 pid 文件杀掉旧进程
- 再额外通过端口参数匹配的方式做一次兜底清理

这样可以避免最常见的问题：

```text
Address already in use
```

### 3. `scripts/sync-project-name.sh`

文件位置：

- [`usart/scripts/sync-project-name.sh`](usart/scripts/sync-project-name.sh)

完整内容：

```zsh
#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

project_name="${PWD:t}"
current_name="$(sed -nE 's/^name = "(.*)"/\1/p' Cargo.toml | head -n 1)"

if [[ -z "${current_name}" ]]; then
  echo "Failed to read package name from Cargo.toml" >&2
  exit 1
fi

if [[ "${current_name}" == "${project_name}" ]]; then
  exit 0
fi

tmp_file="$(mktemp)"

awk -v new_name="${project_name}" '
  BEGIN { in_package = 0; updated = 0 }
  /^\[package\]$/ { in_package = 1; print; next }
  /^\[/ && $0 != "[package]" { in_package = 0 }
  in_package && /^name = "/ && !updated {
    print "name = \"" new_name "\""
    updated = 1
    next
  }
  { print }
' Cargo.toml > "${tmp_file}"

mv "${tmp_file}" Cargo.toml
echo "Updated package name: ${current_name} -> ${project_name}"
```

这个脚本的存在，是为了配合下面这段逻辑：

```zsh
PROJECT_NAME="${PWD:t}"
BINARY="target/${TARGET}/debug/${PROJECT_NAME}"
```

脚本默认认为最终的 ELF 名字和当前目录名一致。  
为了避免包名和目录名不同导致找不到二进制，就在每次调试前自动同步 `Cargo.toml` 中的包名。

## 八、为什么需要 `__rustrover_current.elf`

在 `debug-server.sh` 里有这一句：

```zsh
ln -sfn "${PROJECT_NAME}" "${SYMBOL_LINK}"
```

而 `SYMBOL_LINK` 的值是：

```zsh
SYMBOL_LINK="target/${TARGET}/debug/__rustrover_current.elf"
```

这背后的目的很简单：

- Cargo 生成的真实 ELF 文件名通常跟包名有关
- RustRover 的调试配置更适合写一个固定的符号文件路径
- 所以脚本每次构建后都创建一个固定名字的符号链接

这样调试配置就可以长期固定为：

```xml
symbolFile="$PROJECT_DIR$/target/thumbv7em-none-eabihf/debug/__rustrover_current.elf"
```

不需要随着工程名变化而手动修改。

## 九、一键调试时到底发生了什么

这一节适合博客里用“执行链路”来解释。

### 分步说明

1. 你在 RustRover 中点击 `J-Link Debug`
2. RustRover 读取 `.run/J-Link_Debug.run.xml`
3. 它发现这个配置有一个前置任务 `J-Link Server`
4. RustRover 先执行 `.run/J-Link_Server.run.xml`
5. 这个运行配置启动 `scripts/debug-server.sh`
6. `debug-server.sh` 调用 `debug-stop.sh` 清理旧的 J-Link GDB Server
7. `debug-server.sh` 调用 `sync-project-name.sh`，保证包名和目录名一致
8. `debug-server.sh` 执行 `cargo build --target thumbv7em-none-eabihf`
9. 脚本确认生成的 ELF 文件存在
10. 脚本创建 `__rustrover_current.elf` 符号链接
11. 脚本启动 `JLinkGDBServerCLExe`
12. 脚本等待日志中出现 `Listening on TCP/IP port 2331`
13. 脚本调用 `arm-none-eabi-gdb` 批处理执行 `target/reset/halt/load`
14. 固件被下载到 STM32 的 Flash
15. 芯片被复位并停住
16. 前置脚本结束
17. RustRover 正式启动远程 GDB 调试
18. RustRover 用 `arm-none-eabi-gdb` 连接 `localhost:2331`
19. RustRover 读取 `__rustrover_current.elf` 的符号
20. 你开始在 IDE 中打断点、单步和查看变量

## 十、流程图

### 1. 一键调试流程图

```text
+----------------------+
| RustRover            |
| Click J-Link Debug   |
+----------+-----------+
           |
           v
+----------------------+
| J-Link Debug         |
| Remote GDB config    |
+----------+-----------+
           |
           | before launch
           v
+----------------------+
| J-Link Server        |
| Shell config         |
+----------+-----------+
           |
           v
+-------------------------------+
| scripts/debug-server.sh       |
+----------+--------------------+
           |
           +--> debug-stop.sh
           |
           +--> sync-project-name.sh
           |
           +--> cargo build
           |
           +--> create __rustrover_current.elf
           |
           +--> start JLinkGDBServerCLExe
           |
           +--> wait for port 2331
           |
           +--> arm-none-eabi-gdb batch load
           |
           v
+-------------------------------+
| STM32 firmware loaded         |
| target reset and halted       |
+----------+--------------------+
           |
           v
+-------------------------------+
| RustRover attaches via GDB    |
| remote = localhost:2331       |
| symbol = __rustrover_current  |
+----------+--------------------+
           |
           v
+-------------------------------+
| Breakpoint / Step / Inspect   |
+-------------------------------+
```

### 2. 组件关系图

```text
RustRover
  |
  | runs
  v
J-Link Debug.run.xml
  |
  | triggers before-launch task
  v
J-Link Server.run.xml
  |
  | executes
  v
scripts/debug-server.sh
  |
  +---- cargo build ------------------------------> target/thumbv7em-none-eabihf/debug/usart
  |
  +---- ln -sfn ---------------------------------> __rustrover_current.elf
  |
  +---- start JLinkGDBServerCLExe ---------------> J-Link probe
  |                                                 |
  |                                                 v
  |                                               STM32
  |
  +---- arm-none-eabi-gdb batch load ------------> J-Link GDB Server
  |
  v
RustRover arm-none-eabi-gdb attach
  |
  v
IDE debugging UI
```

### 3. 下载阶段时序图

```text
RustRover          debug-server.sh       JLinkGDBServer        arm-none-eabi-gdb         STM32
    |                     |                    |                       |                    |
    | run before task     |                    |                       |                    |
    |-------------------->|                    |                       |                    |
    |                     | start server       |                       |                    |
    |                     |------------------->|                       |                    |
    |                     | wait ready         |                       |                    |
    |                     |<-------------------| listening on 2331     |                    |
    |                     | run batch gdb      |                       |                    |
    |                     |------------------------------------------->|                    |
    |                     |                    |<----------------------| connect remote     |
    |                     |                    |---------------------->|                    |
    |                     |                    |<----------------------| monitor reset      |
    |                     |                    |------------------------------->| reset      |
    |                     |                    |<----------------------| monitor halt       |
    |                     |                    |------------------------------->| halt       |
    |                     |                    |<----------------------| load               |
    |                     |                    |------------------------------->| write flash|
    |                     |                    |<----------------------| reset/halt         |
    |                     |                    |------------------------------->| halt       |
    |                     |                    |<----------------------| disconnect         |
    |                     | done               |                       |                    |
    |<--------------------|                    |                       |                    |
    | attach gdb          |                    |                       |                    |
    |--------------------------------------------------------------->|                    |
    |                    debug session starts                         |                    |
```

## 十一、这套方案成立的原理

### 1. RustRover 只负责 GDB 前端

RustRover 本质上并不直接控制 J-Link 探针，而是通过 GDB 与远端调试服务通信。

它擅长的是：

- IDE 断点管理
- 源码级单步
- 变量查看
- 调用栈展示

它不擅长的是：

- 启动 J-Link GDB Server
- 识别具体 STM32 型号
- 自动下载裸机固件

所以这部分必须由脚本补足。

### 2. `JLinkGDBServerCLExe` 提供的是标准 GDB Remote 协议

J-Link GDB Server 启动后会监听 `2331`，暴露一个标准 GDB Remote 端口。  
无论前端是 RustRover、CLion 还是命令行 GDB，只要能连上这个端口，就能调试目标芯片。

因此这个方案的关键不是 RustRover 特性，而是：

- 让 J-Link 正确地对外提供一个 GDB 远程服务
- 让 RustRover 正确地连接这个服务

### 3. 先下载，再附加调试

这套方案没有让 RustRover 自己执行 `load`。  
而是由 `debug-server.sh` 用批处理 GDB 先完成下载。

这么做的好处是：

- 下载流程更可控
- 日志更独立
- RustRover 只做它擅长的事
- 出问题时可以分开定位是“下载失败”还是“IDE 连接失败”

### 4. 固定符号文件路径

RustRover 调试时需要一个 ELF 来加载符号。  
这个 ELF 不只是为了“启动程序”，更重要的是：

- 函数名解析
- 源码定位
- 断点映射
- 变量和栈信息解析

用 `__rustrover_current.elf` 这个固定名字做符号链接，相当于给 IDE 提供一个稳定入口。

## 十二、常见问题和排查方法

### 1. 报错 `can't find crate for 'test'`

原因：

- embedded 工程被按测试目标构建

解决：

- 在 `Cargo.toml` 里为 `[[bin]]` 增加：

```toml
test = false
bench = false
```

### 2. RustRover 连不上 `localhost:2331`

原因可能包括：

- J-Link GDB Server 没有成功启动
- 旧进程仍占用端口
- J-Link 没有连接板子
- 调试前置脚本执行失败

优先检查：

- [`usart/.jlink-gdb.log`](usart/.jlink-gdb.log)
- [`usart/.jlink-load.log`](usart/.jlink-load.log)

### 3. 报错 `Missing ELF file`

原因：

- `cargo build` 没成功
- 包名和目录名不一致
- 目标路径不匹配

排查：

- 手动执行 `cargo build --target thumbv7em-none-eabihf`
- 检查 `sync-project-name.sh`

### 4. 能烧进去，但断点不正常

原因可能包括：

- 符号文件不是当前固件
- `memory.x` 地址错误
- 芯片型号设置错误
- 编译优化影响源码级调试体验

重点检查：

- `symbolFile` 是否指向 `__rustrover_current.elf`
- `DEVICE="STM32F407ZE"` 是否匹配实际芯片
- `memory.x` 是否匹配板子

## 十三、教程博客可直接使用的总结

如果要把本文改写成博客，可以把结论概括成一句话：

> RustRover 本身只负责 GDB 前端，真正实现 STM32 一键 J-Link 调试的是一套“运行配置 + shell 脚本 + J-Link GDB Server + ARM GDB”的自动化链路。

更具体一点，这条链路由三部分组成：

1. Cargo 和链接脚本负责生成正确的嵌入式 ELF
2. `debug-server.sh` 负责启动 J-Link GDB Server 并下载程序
3. RustRover 负责连接 GDB Server 并提供 IDE 调试体验

最终用户只需要点击一次 `J-Link Debug`，但背后实际发生的是：

1. 编译
2. 启动 J-Link GDB Server
3. 下载 ELF 到 STM32
4. RustRover 连接远程 GDB
5. 开始断点调试

这就是当前工程中“一键 J-Link 调试 STM32”的完整实现方式。
