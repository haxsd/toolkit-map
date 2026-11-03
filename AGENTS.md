# AGENTS.md —— 工具链发现契约

这个文件是给 AI agent 看的。它规定的不是"这个项目怎么写代码"，而是
**"你在这台机器上找工具、判断版本的时候，必须遵守什么规则"**。

适用范围是**所有工具**：语言运行时、编译器、CLI、逆向与渗透工具都算。

把本文件的内容复制到你实际使用的规则文件里（Cursor 的 `.cursor/rules/`、
`AGENTS.md`、`CLAUDE.md`，或任何会在会话开始时注入的上下文）。

---

## 一句话原则

> `node --version` 是解析器，不是盘点器。

它回答的是"按 PATH 顺序，第一个赢家是谁"，**不是**"这台机器上有哪些工具与版本"。
把前者当成后者，就会说出一句关于机器的错误陈述，而且说得很自信——

> "本机只有 Node 16" ← 这句话通常是**错的**。它真正的含义是"PATH 解析到了 Node 16"。

---

## 必须遵守的六条规则

### 规则 1：要用工具，先查地图拿绝对路径

```powershell
.\scripts\map.ps1 find <工具> -Json      # 返回 path（绝对路径）+ 版本 + 其他候选
.\scripts\map.ps1 status                 # 检查新鲜度；维护前取得用户同意
```

用返回的 `path` 去执行。地图是**索引**（这台机器上有什么、在哪），仓库是**存放地点**；

- **调用**：`find` 给的路径可能在统一仓库里，也可能在系统安装目录或管理器目录里——看 `source` 字段，不要假定它一定在仓库里；
- **新候选**：`find` 严格只读，不执行新候选、不写地图；本次搜索未发现可用副本不代表整台机器没有。需要验证或更新时，先取得用户同意，再使用 `scan`、`update` 或 `add`；只有用户明确需要时才讨论安装（规则 5）。

**不要**用 `Get-Command`、`where.exe`、`Test-Path` 或手工比较 PATH 来推测"该用哪个"——
实测会推错：同一个命令名在旧会话与新会话里可能跑的不是同一个文件
（`gh` 就撞过这个：一个是 mise 的 shim，一个是机器级 PATH 的副本）。

### 规则 2：先读声明，不要猜

| 位置 | 文件 | 作用 |
|---|---|---|
| 项目根目录及各级父目录 | `mise.toml` / `.mise.toml` / `.tool-versions` | 项目**要求**什么版本 |
| 项目根目录 | `.nvmrc` / `.python-version` / `package.json` 的 `engines` | 语言各自的传统声明 |
| 用户全局 | `~/.config/mise/config.toml` | 这台机器**提供**哪些版本 |

**默认按需**：全局声明留空，版本需求写进项目；只有确实要常备的版本才写进
`~/.config/mise/config.toml`——写进去的每一项都会被 `mise install` 立刻拉下来，
声明了却没装还会被 census 报 `[MISSING]`。

**项目声明比机器声明更具体**：项目内有声明时以项目为准，用 `mise exec -- <命令>` 执行；
地图给的是"机器事实"，项目声明是"项目意图"，两者冲突时意图优先。

### 规则 3：盘点要覆盖五类来源，缺一类就可能漏

1. **声明层** —— 项目与全局的声明文件
2. **纳管层** —— mise / fnm / uv / conda 等管理器管理的
3. **约定层** —— PATH 里带版本号的命名 shim（`node22`、`python312`）
4. **非纳管层** —— 版本管理器目录、系统安装目录、IDE 内置运行时、conda 环境
5. **解析层** —— 常见命令实际解析到哪个文件

`map.ps1 scan` 面向这五类来源，但搜索范围有限，不能把未发现当成全盘不存在；同时排除依赖特定环境的对象（conda 某个 env 里的小包、
venv / site-packages / node_modules）——它们离开环境就没有意义，不是"工具"。

### 规则 4：需要特定版本时用一次性激活，不要改全局状态

```bash
mise exec -- node -v              # 按当前项目声明执行，最推荐
mise exec node@22 -- node -v      # 显式指定版本
uv run --python 3.12 script.py    # Python 的等价物
```

**不要**为了让某条命令用上新版本去改 PATH、改系统环境变量、或全局安装。

### 规则 5：新工具装进统一仓库，已有的不要迁移

```powershell
.\scripts\map.ps1 install <工具>@<版本|latest>   # 落到 ~/toolchains/<工具>/<版本>/ 并登记
```

- **不要**往 PATH 里加指向具体版本的目录，PATH 是单值命名空间。
- **不要**装到随手找的位置（`~/nodejs`、`<盘符>:\nodejs`、桌面、临时目录）。
- **已有副本不要迁移**：它们的路径可能被项目配置、IDE 设置、CI 脚本写死。
  正确做法是 `map.ps1 add <工具> -Path <绝对路径>` 登记，而不是搬走。

### 规则 6：只读地探测，别把机器搞脏

扫描/探测**不得执行 shim**；`find` 更严格，既不执行新发现或指纹变化的候选，也不写地图。经用户授权的 `scan`、`update`、`add` 可能执行普通候选的版本探测。mise 的 shim 在目标工具缺失时可能自动安装
（实测过——只为取版本执行了一下 shim，就在 `mise\installs` 下装出了第二份 `gh`）。
地图对 shim 只登记路径、不执行；候选里的 `isShim` 就是这个意思。

---

## 接手一个锁旧版本的老项目

特征：`package.json` 有 `engines` 约束却没有任何声明文件，或者什么都没写、
只靠 PATH 上恰好存在的版本跑起来。后者最危险——它对版本的依赖完全没有记录。

正确做法是**补一个声明，而不是去改全局环境**：

1. 先确认它到底需要哪个版本（看 `engines`、lockfile、CI 配置，或直接问作者）。
2. 在项目根目录建声明文件：

   ```toml
   # mise.toml
   [tools]
   node = "16"
   ```

3. 取得用户同意后，让机器去满足它：`mise trust && mise install`（mise 自己拉版本，不需要手工下载配 PATH）。
4. 之后 `cd` 进这个项目就自动用对版本。

**不要**做这三件事：改全局 PATH 顺序把某个版本顶上"系统默认"；在项目里硬编码绝对路径
（`D:\nodejs\node.exe` 这种）；建只存在于文件名的私有约定（`node22` 那类）。

---

## 最容易踩的坑

### 坑 1：存在 ≠ 可用（但 0 字节也不等于一定坏）

`WindowsApps\python3.exe` 是 0 字节的商店别名：`Get-Command` 返回它，执行却无输出、退出码 9009。
但同一个目录下 `pwsh.exe`、`winget.exe` 也是 0 字节却能正常执行。
文件存在或大小本身不足以证明可用；`find` 不会为此执行别名。只有在用户授权且确认探测安全时，才另行验证。

### 坑 2：PATH 是单值命名空间

同名命令只有第一个生效。Windows 上 PATH 还是「机器级在前 + 用户级在后」拼起来的，
所以机器级的直接工具目录（如 Oracle 的 `javapath`）永远排在用户级 shims 之前；
`mise activate` 只在当前会话内前置 shims，cmd、图形程序、IDE 任务、`-NoProfile` 脚本
拿不到这个前置。判断"声明生效没有"必须区分**激活的会话**与**未激活的场景**。

### 坑 3：自定义命名约定会失传

`~/tools/bin/node22.cmd` 这类写法创造了一个只存在于文件名里的 API：想知道它存在，
你得先读过它。一旦发现这类约定，**必须登记**（写进声明文件，或 `map.ps1 add`），
否则换台机器、换个 agent 就彻底失传。

### 坑 4：IDE 自带的运行时

JetBrains 系 IDE 的 `jbr/` 里有完整 JDK，版本常常比用户自己装的还新。
**只在明确需要时使用**，不要当项目 JDK——那会让构建依赖某个 IDE 的私有安装。

### 坑 5：Windows PowerShell 5.1 的 `@()` 陷阱

`@($list)` 作用于 `List[object]` 会抛 `Argument types do not match`，要用 `$list.ToArray()`。

### 坑 6：声明会漂移（模板 ≠ 部署副本）

`templates/mise-config.toml` 是"想要的声明"，`~/.config/mise/config.toml` 是"实际的声明"。
两份独立文件，克隆到新机器或手工改过就会不一致，而扫描只能读到部署副本——
于是"模板里新加的工具"永远不会被安装。刷新用 `bootstrap -RefreshConfig`（覆盖前自动备份）。
注意：刷新是**按模板覆盖**，部署副本里的本机注释会被冲掉。

---

## 优先使用 MCP

如果当前客户端已经暴露 `toolkit_find` / `toolkit_status` / `toolkit_doctor` MCP 工具，直接调用它们；不要为同样的查询再启动 PowerShell 执行 `map.ps1`。若客户端还提供 `toolkit_scan` / `toolkit_update` / `toolkit_add`，先预览并向用户展示目标，取得明确授权后才请求执行；`confirm:true` 只是工作流护栏，不是真人授权证明。脚本是没有对应 MCP 工具时的回退。

## 查询契约（v2）

完整地图动作支持 Windows PowerShell 5.1/7。接入用 `setup -Project <目录>`，诊断用 `doctor`；技能中的脚本路径必须按技能实际位置确定，不能按项目工作目录猜。

查询用 `find <工具> -Project <项目目录> -Json`，检查 `ok`、`status`、`verification` 和 `requirement`。版本不匹配或要求无法判断时失败，不降级。搜索失败只说明本次范围未发现合适副本，不说明整台机器没有。shim 与未验证副本不得用于执行；IDE 副本只有经明确选择且已验证时才可使用。

地图 v2 的 `scannedAt` 是完整扫描时间，`updatedAt` 是局部更新时间；重扫保留已登记副本、备注与偏好。所有动作的 JSON stdout 是一个对象。

## 开工前的工具预检

```powershell
.\scripts\map.ps1 status            # 地图在不在、多旧
.\scripts\map.ps1 find <你要用的工具> -Json
```

看这几类告警（扫描内核 census 的 `warnings`）：`[MISSING]`（本次扫描范围没有发现声明的工具）、
`[PATH_ORDER]`（解析到的版本不满足声明）、`[STUB]`（命令指向跑不起来的文件）、
`[DRIFT]`（模板与实际声明不一致）、`[UNDECLARED]`（项目有版本约束却没有声明文件）。

**边界**：这套东西只管"工具与版本"这一层。应用为什么起不来——端口占用、`.env` 缺失、
依赖目录没装、后台服务没跑、脚本没有执行位——是另一类问题，不要用这里的结论替代那边的检查。

---

## 报告格式要求

向用户报告运行时状况时，明确区分三件事：

| 层次 | 说法 | 例子 |
|---|---|---|
| **声明** | "项目要求 X" | "`.tool-versions` 要求 nodejs 22.23.2" |
| **可用** | "这台机器上装了 X、Y、Z" | "装有 Node 16.20.2 和 22.23.2" |
| **解析** | "现在 `node` 会用到 X" | "当前 `node` 解析到 16.20.2" |

不要说"本机只有 X"，要说"PATH 上的 `node` 解析到 X，机器上另有 Y 未被 PATH 覆盖"。

---

## 项目接入清单

```powershell
# 1. 看项目声明了什么
Get-Content mise.toml, .tool-versions, .nvmrc -ErrorAction SilentlyContinue

# 2. 确认地图可用，并查清要用哪个
.\scripts\map.ps1 status
.\scripts\map.ps1 find <工具> -Json

# 3. 用户明确同意安装后，按声明补齐（而不是改项目去迁就机器）
mise trust; mise install

# 4. 用一次性激活执行命令
mise exec -- npm ci; mise exec -- npm test
```

第 3 步的方向很重要：**让机器去满足项目的声明，而不是改项目去迁就机器**。
因为版本对不上就改 `engines` 或降级依赖，会造成"在你机器上能跑、在 CI 上炸"的隐蔽问题。

## 仓库边界

公开仓库只放源码、文档、模板、示例与测试；内部计划、交接说明、账户/密钥、真实环境信息不进这里。当前树由 `tests/records-guard.ps1` 检查。
