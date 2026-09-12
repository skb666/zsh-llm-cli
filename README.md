# zsh-llm-cli Zsh Plugin

`zsh-llm-cli` 是一个把多个 LLM CLI 后端（kimi / opencode / omp / 用户自定义）统一集成进 Zsh 的插件。每个后端用"字符 + `[后端名]`"形式的标签化前缀字符标记一行命令，按 Enter 后整行作为 prompt 转发给对应后端的二进制。

- 按 `Ctrl-X` toggle 当前激活后端的标签化前缀——buffer 加/去 `<char>[<name>]` 前缀，**首次按下后 prefix 持续显示直到再次按下 Ctrl-X 关闭**，期间每条新行 `zle-line-init` 自动恢复同一前缀
- 按 `Ctrl-N` 在加载顺序中 cycle 切换当前激活后端——若旧当前激活后端处于"带前缀"状态，buffer 中的旧标签前缀**同步替换**为新当前激活后端的标签前缀
- buffer 中的标签前缀**不可被 Backspace 删除**（guard widget 守护）——prefix 边界处按 Backspace 只发出蜂鸣

Plugin **不读任何系统环境变量**，也**不向 RPROMPT 追加任何内容**（RPROMPT 完全由用户主题/配置决定）。所有面向用户的开关（flag 注入、sd 包装、键位）从 INI 文件读取。

## 用法

```
✨[kimi] 滨江今日天气           # 调用 kimi 后端
🔮[opencode] 重构 auth 模块    # 调用 opencode 后端
💠[omp] 写个 hello world 脚本   # 调用 omp 后端
```

按 `Ctrl-X` 给当前行加上当前激活后端的标签化前缀（再按一次去掉）。首次按下后，标签前缀**持续显示**直到再次按 `Ctrl-X` 关闭——期间：

- 新行（无论是命令输出完成后新行、还是 `Enter` 提交后新行）buffer 自动以同一前缀开头
- buffer 中的标签前缀不可被 Backspace / `Ctrl-W` 等删除（边界处发出蜂鸣）
- 用户调出**不含前缀**的历史命令（如 `git status`）时，plugin 不覆盖 buffer

按 `Ctrl-N` 在加载顺序中 cycle 当前激活后端：

- 若当前 buffer 已含旧当前激活后端的标签前缀，cycle 后 buffer 中的前缀**同步替换**为新当前激活后端的标签前缀
- 若当前 buffer 不含前缀（之前 toggle 关闭过），cycle 仅切当前后端名，不动 buffer

## 依赖

- Zsh 5.4+
- 内建后端：`kimi` / `opencode` / `omp` 二进制在 `$PATH` 上
- 可选：`sd`（[Streamdown](https://github.com/day50-dev/Streamdown)）用于流式 markdown 渲染

> 本插件取代 `zsh-kimi-cli` / `zsh-opencode-cli` / `zsh-omp-cli` 三个独立 plugin——同时加载时后 source 的 `command_not_found_handler` 会覆盖前一个；本插件已统一三者的交互模型。

## 安装

按你使用的 Zsh 框架挑一种。

### 手动（`.zshrc`）

```zsh
# clone 到任意目录
git clone https://example.invalid/zsh-llm-cli.git ~/.zsh/llm-cli

# 在 .zshrc 里加载插件
source ~/.zsh/llm-cli/llm-cli.plugin.zsh
```

打开新 shell（或 `exec zsh`）即可激活 handler。

### Oh My Zsh

```zsh
git clone https://example.invalid/zsh-llm-cli.git \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/llm-cli

# in ~/.zshrc
plugins=(... llm-cli)
```

重启 Zsh 以加载插件。

### Antigen

```zsh
antigen bundle example/zsh-llm-cli
antigen apply
```

### Zinit

```zsh
zinit light example/zsh-llm-cli
```

### Znap

```zsh
znap source example/zsh-llm-cli
```

### Fig

```zsh
fig plugin install example/zsh-llm-cli
```

### Zplug

```zsh
zplug "example/zsh-llm-cli", as:plugin
```

## 配置

Plugin **不读任何系统环境变量**，也**不向 RPROMPT 追加任何内容**。所有配置通过两个 INI 文件声明。

### 全局配置 `config.ini`

主仓库 `./zsh-llm-cli/config.ini` 提供默认值；用户 `~/.config/zsh-llm-cli/config.ini`（若存在）**整文件覆盖**主仓库版本。

```ini
[cycle]
key_toggle = ^X   ; toggle 当前激活后端标签化前缀
key_next = ^N     ; cycle 后端
```

`key_toggle` / `key_next` 接受 zsh `bindkey` 同种语法（如 `^X`、`^[X`、`^[[B`）。

`[ui]` section 保留以备未来扩展，当前 plugin 不读取其中任何字段——RPROMPT 完全由用户主题（如 agnoster / p10k）决定，plugin 不介入。

### 后端配置 `backends/*.backend.ini`

主仓库 `./zsh-llm-cli/backends/` 含三个内建后端；用户 `~/.config/zsh-llm-cli/backends/*.backend.ini` 可新增或覆盖。

```ini
[backend]
name = my-llm            ; 后端唯一名
prefix = 🤖              ; 单字符前缀字符(plugin 自动构造完整标签 🤖[my-llm])
bin = my-llm-binary      ; $PATH 上能找到的可执行文件

[args]
always = --verbose       ; 始终拼入命令行的 flag(每个值一行)
always = --mode=fast

[stream]
use_sd = auto            ; 0=禁用 sd, 1=强制启用, auto=自动检测 $PATH 上的 sd
```

`[env]` 段不存在——所有 flag 直接由 `[args]` 段以字面值形式给出，plugin 不读任何环境变量。

### 同名后端用户覆盖

`~/.config/zsh-llm-cli/backends/omp.backend.ini` 与内建同名时，用户版本覆盖主仓库版本：

- plugin 输出 `zsh-llm-cli: user override for omp` 提示
- 用户可改 `prefix` 字段让标签字符串与内建不同（如内建 `💠[omp]` → 用户 `🔮[omp]`）
- 用户不改 prefix 时标签字符串与内建相同，但后端的 flag / sd 行为已被用户版本替换

主仓库内部重名或用户目录内部重名会导致 plugin 加载中止。

## 自定义后端

在 `~/.config/zsh-llm-cli/backends/` 下放 `*.backend.ini` 即可，无需修改主仓库：

```ini
# ~/.config/zsh-llm-cli/backends/gemini.backend.ini

[backend]
name = gemini
prefix = 🌟
bin = gemini-cli

[args]
always = --yolo

[stream]
use_sd = 1
```

plugin source 时按文件名序加载所有后端；`Ctrl-N` 按该顺序 cycle。

## 行为说明

- plugin 把 prompt 整段作为单个双引号包裹的元素（如 `"你好 今天"`）传给后端二进制；后端把 argv 当字符串处理，LLM 容忍字面 `"` 字符。
- plugin **不会**对 prompt 内容做二次解释（不展开 `$var`、不执行反引号/`$()`、不做 word-splitting）——它把整段 prompt 作为单元素转发，后端收到的 argv 不会被切碎。
- 但用户在 zsh 输入时，**外层 shell 会按 shell 规则先展开** prompt 里的 `$var`、`$(...)`、反引号、引号配对等。要让 `$world` 按字面传给后端，在 shell 输入层用单引号保护：`✨[kimi] '写个 "hello $world" 测试'`。
- sd 集成走 pipe 模式（`omp ... | sd`），不依赖 `sd -e EXEC` 的字符串 split 路径（split 不处理引号/转义，会切断含空格的 prompt）。
- 后端二进制不在 `$PATH` 上时，handler 返回 127 并输出明确错误；不会静默调用其他命令。
- `[stream] use_sd=1` 但 sd 找不到时，handler 同样返回 127 并报错，不静默退化到无 sd 模式。
- plugin 会保留加载前已存在的 `command_not_found_handler`，对不带标签化前缀的命令行委托给它。

## 从旧 plugin 迁移

既有 `zsh-kimi-cli` / `zsh-opencode-cli` / `zsh-omp-cli` 用户切换到本插件：

1. `.zshrc` 里把 source 三个旧 plugin 的三行改为 source 本插件一行
2. `.zshrc` / shell init 里 `export KIMI_CLI_*` / `export OPENCODE_CLI_*` / `export OMP_CLI_*` 等所有行**删除**——新 plugin 不读任何 env var
3. 把对应 flag 值改写到对应后端 INI 的 `[args]` 段：
   ```ini
   # 旧: export OPENCODE_CLI_AGENT=orchestrator
   [args]
   always = run
   always = --agent
   always = orchestrator
   ```
   ```ini
   # 旧: export OMP_CLI_THINKING=high
   [args]
   always = -p
   always = --thinking
   always = high
   ```
4. 用户配置目录从 `~/.zsh/llm-cli.d/` 改为 `~/.config/zsh-llm-cli/`：`mv ~/.zsh/llm-cli.d/* ~/.config/zsh-llm-cli/backends/`
5. 输入习惯从单字符前缀改为标签化前缀：`✨ foo` → `✨[kimi] foo`，或 `Ctrl-X` 让 plugin 自动加上当前激活后端的标签化前缀（首次按下后 prefix 持续显示，按 `Ctrl-X` 关闭）
6. 打开新 shell（或 `exec zsh`），验证 `✨[kimi] hello` 走 kimi 后端、`Ctrl-X` toggle 标签前缀、`Ctrl-N` cycle 同步替换 buffer 中前缀、buffer 中前缀不可被 Backspace 删除

env var → INI 字段迁移参考表：

| 旧 env var | 新位置 |
|---|---|
| `KIMI_CLI_USE_SD` | 对应后端 INI `[stream] use_sd = 0\|1\|auto` |
| `OPENCODE_CLI_AGENT` | 对应后端 INI `[args]` 新增 `always = --agent` 与 `always = <值>` |
| `OPENCODE_CLI_MODEL` | 对应后端 INI `[args]` 新增 `always = -m` 与 `always = <值>` |
| `OPENCODE_CLI_USE_SD` | 对应后端 INI `[stream] use_sd = 0\|1\|auto` |
| `OMP_CLI_MODEL` | 对应后端 INI `[args]` 新增 `always = --model=<值>` |
| `OMP_CLI_THINKING` | 对应后端 INI `[args]` 把 `always = auto` 改为 `always = <档位>` |
| `OMP_CLI_USE_SD` | 对应后端 INI `[stream] use_sd = 0\|1\|auto` |

旧三个 plugin 文件保留在原目录（`./zsh-kimi-cli/`、`./zsh-opencode-cli/`、`./zsh-omp-cli/`），不动——它们作为参考实现与历史保留。