# periphery

依赖 LOVE20 协议**已部署合约**的外围合约。本仓的定位是「可随时替换」：它读取 `core` 的状态、
写入 `core` 的账本，但自己**不持有账本、不发行凭证、不折叠协议状态**。

判据是一条编译期事实：`periphery` 的合约 `import @core/`，`tools` 的合约不 import 任何协议合约。
新增合约归属哪个仓库按「是否依赖协议已部署合约」判定，见
[repositories.md](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/repositories.md)。

## 合约

| 合约 | 角色 |
| --- | --- |
| `src/LOVE20Hub.sol` | 双边流动性质押、双边组 LP、报价 |

`LOVE20Hub` 覆盖原 `UniswapV2Zap` 的全部能力，并在此之上追加一笔 `Stake.stakeLiquidity` 记账。
**四条写入口全部接受双边期望量**，任一侧为 0 表示该侧不给——单币输入就是「一侧为 0」的特例：

| 入口 | 资金形态 | 代币对范围 |
| --- | --- | --- |
| `stakeLiquidityWithToken` | ERC20 `transferFrom` | 限定：已注册社区币 ↔ 它的 parent |
| `stakeLiquidityWithNative` | `payable` | 限定 + parent 必须是 WBNB |
| `addLiquidityWithToken` | ERC20 `transferFrom` | **不限**任意 `tokenA` / `tokenB` |
| `addLiquidityWithNative` | `payable` | 不限（另一侧是 WBNB） |

质押两支在组 LP 之上再调一次 `Stake.stakeLiquidity`；组 LP 两支把 LP 直接发给 `to`，不产生质押记账。
**两条路径的范围不同**：质押限定在社区币上（读 `Launch` / `ILOVE20Token` / `Stake`），组 LP 不读任何
协议合约、pair 由 DEX factory 派生。不把组 LP 拆出去的理由见
[ADR 2026-11-14](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/adr/2026-11-14-periphery-hub-dual-sided-and-generic-lp.md)。

**报价**四个，纯 `view` 试算：`quoteLp` / `quoteLpWithNative` / `quoteStakeLiquidity` /
`quoteStakeLiquidityWithNative`。全部返回 `hasLiquidity`（区分首次注资）与 `suggested*Min`；质押报价
必须带 `memberId` 与 `promisedWaitingPhases`，并额外返回 `liquiditySharesAdded` / `liquidityShares` /
`govVotesAdded`——流动性质押对外可读的是**份额、治理票与承诺解锁期**，LP 只是 core 的内部记账。

swap、折算、退款三者的实现在四条写入口之间**共用一份**，数学只存在一处。

### 空池与缺池

- **pair 不存在**：组 LP 路径接受它——两侧都要 > 0，不 swap，由 Router 的 `_addLiquidity` 内部
  `createPair`；质押路径仍要求 pair 存在（`Launch._ensurePair` 保证社区币的 pair 必然存在）。
- **pair 存在但储备为 0**：两条路径都接受首次注资（两侧都要 > 0），不 swap，LP 为
  `sqrt(a·b) − 1000`。这正是新币冷启动的场景：`Launch` 建 token 时就 `createPair` 但从不注资。
- **只有一侧 > 0 且无储备**：`PairWithoutLiquidity`，因为没有价格可以定价 swap。

### 依赖注入与 DEX 费率

构造函数接受三个参数：注入的 `stakeAddress`，以及两个 **DEX 费率**（1e18 定点比例）。地址依赖全部
由 `stakeAddress` 派生：

```text
stakeAddress
├─ ROUTER_ADDRESS        ← Stake.ROUTER_ADDRESS()
├─ PAIR_FACTORY_ADDRESS  ← Stake.PAIR_FACTORY_ADDRESS()
├─ LAUNCH_ADDRESS        ← Stake.LAUNCH_ADDRESS()
├─ MEMBER_NFT_ADDRESS    ← Stake.MEMBER_NFT_ADDRESS()
└─ WRAPPED_NATIVE_ADDRESS ← Router.WETH()
```

全部 `immutable` + 全大写。没有 `init`、没有 `initialized`。

**费率必须是部署参数**：Hub 可能指向任意 Uniswap V2 兼容 DEX，而各家的费率不同，且**协议抽成公式
只能从 `Mint` 事件反推、`view` 调用拿不到**，所以无法在运行时可靠探测。两个参数按「手续费的两个
去向」表达，都是 1e18 定点：

| 参数 | 含义 | 本地 `dex` | Uniswap V2 | Pancake 主网 | Pancake 测试网 |
| --- | --- | --- | --- | --- | --- |
| `SWAP_FEE_FOR_LP_RATIO` | 留给 LP 的手续费 | `3000000000000000` | `2500000000000000` | `1700000000000000` | `1500000000000000` |
| `SWAP_FEE_FOR_PROTOCOL_RATIO` | 协议抽走的手续费 | `0` | `500000000000000` | `800000000000000` | `500000000000000` |
| 合计（= swap 费率） | | 0.30% | 0.30% | 0.25% | 0.20% |

这个形状不是审美选择：三个已知 profile 的两个值**全部是 1e18 精确整数**，而 `k/(a+k)` 形式下
Uniswap 的 `1/6` 除不尽。swap 费率由 `1e18 − (lp + proto)` 推出，不需要第三个参数。

派生结果与两个费率由 `DeployHub.s.sol` 在**广播前**逐项复核（并用一次真实的 `getAmountsOut` 反解
交叉验证费率），`21_check_hub.sh` 在部署后独立再复核一次。

### 协议抽成公式

Hub 的报价要预测「pair 会先给协议铸多少 LP」，否则 `expectedLiquidity` 会偏高。三种实现的公式都能
写成同一个族：

```text
feeLp = supply · (rootK − rootKLast) · k / (a·rootK + k·rootKLast)
```

其中 `k/a` 就是两个费率之比（`lp` 与 `proto` 约分后）。Uniswap V2 是 `1/5`（增长量的 1/6），
Pancake 主网是 `8/17`（32%），Pancake 测试网是 `1/3`（25%）。`proto == 0` 时整段是 no-op。

### 价格保护

`core` 的 `stakeLiquidity` 已删除 `slippage`，只按 Pair 储备把收到的两种币尽可能放进质押，放不下的
留在调用者手里。Hub 的入参因此只有 `tokenAmountMin` / `parentTokenAmountMin`：

- 语义是**全链路终点**——「最终至少有多少社区币 / 父币进入质押（或进入 LP）」，不是 swap 段的
  `amountOutMin`；
- 校验方式是 Hub 调 `core` **之后**以自身余额差取 `prepared − remaining`，与 Min 比较；
- **不在 Hub 里复刻 core 的折算公式**：core 扣掉多少完全由它自己决定，Hub 只观测余额变化。

**没有 swap 段的内部输出界**（旧版的 `SWAP_OUTPUT_TOLERANCE_RATIO` 已删除）。原因是它给的是假保护：
Hub 自己的 `_amountOut` 与 Router 的 `getAmountOut` 是逐项相同的整数公式、读的是同一个 pair，而同一笔
内储备不会在「读储备」与「swap」之间移动（社区币与 WBNB 都是无钩子 ERC20），所以那个 99% 的下界恒被
满足；夹子发生在交易**之前**，Hub 读到的已经是被人推过的储备，按那组储备算出的 99% 自然还是过。

现在 `amountOutMin` 传 `1`，唯一作用是「Router 不得返回 0」；真正的价格保护是调用者的终点 Min。报价
里的输出量一律取 Router 的真实返回（`getAmountsOut`），Hub 不自己预测，这样报价与写入逐 wei 相等。

### `promisedWaitingPhases` 经 Hub 时没有自由度（重要）

`core` 的等待期规则依赖**调用者是不是该 `memberId` 的 NFT 持有人**：非持有人在目标已写过等待期时
只能**精确沿用**现有值（见 `core/docs` 规格 `04-stake.md` 的拒绝条件表）。而 Hub 调
`stakeLiquidity` 时 `msg.sender` 是 **Hub 自己**，永远不会等于 NFT 持有人，所以：

- **未写过**（该成员记录在该社区的 `promisedWaitingPhases` 仍为 `0`）：可自由指定，含 `MAX`；
- **已写过**（非零）：**必须精确传入当前值**，否则回滚 `PromisedWaitingPhasesRewritten`。经 Hub 无法
  提升等待期。

这是 core 鉴权语义的必然结果，不是 Hub 的额外限制。要提升等待期，由持有人**直接调用**
`Stake.stakeLiquidity`；Hub 不提供这条路径，也不打算复制它。

前端调用前应先读 `Stake.memberStake(tokenAddress, memberId)` 的 `promisedWaitingPhases` 并原样回填。

### 退款

退款形态由**函数分支唯一定确定**，没有 `refundAsNative` 之类的入参：

- ERC20 分支原样退 ERC20；
- 原生币分支退原生币（先 `WBNB.withdraw` 再转发）；
- WETH 退款统一按 WBNB 量纲记数，形态不进事件——事件区分不出、也不该区分。

## 事件

**按事实拆两族**，登记在 `script/events/event-families.txt`，槽位规则见
[event-standards.md §6.1](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/event-standards.md#61-字段顺序)。
拆族的判据是根键不同，而且**机器可守**：

| 族 | 根键 | 事件 | 三个 indexed 槽 |
| --- | --- | --- | --- |
| `periphery.hub` | 社区币 | `HubLiquidityStakedWithToken` / `...WithNative` | `tokenAddress` / `memberId` / `caller` |
| `periphery.pair` | pair | `HubLiquidityAddedWithToken` / `...WithNative` | `pairAddress` / `to` / `caller` |

若合并成一族（根键「`tokenAddress` 或 `pairAddress`」），`check-events.py` 只能校验「首字段是这两个
之一」，一条质押事件写错成 `pairAddress` 也能通过——约束就降级成人眼约定。

组 LP 事实里既没有「社区币」也没有「parent」角色，所以它的四个金额字段是 `preparedAmountA` /
`preparedAmountB` / `remainingAmountA` / `remainingAmountB`；质押事实保持 `preparedTokenAmount` 等。

`pairAddress` 在 pair 尚不存在时（组 LP 冷启动、由 Router 建池）于 `addLiquidity` 返回后回读一次。
**不用 CREATE2 预算**：pair init code hash 在 `dex` 与 Pancake 不同，作为构造参数填错时静默发错地址。

**Hub 事件只记编排事实**：`prepared*` / `remaining*` 四个量。份额、票权、等待期、各种 `total*` 一律
不复制——那些由同一笔交易里 `core` 的 `LiquidityStaked` 提供，两处各记一遍就是双份对账源。
`prepared − remaining` 恒等于实际入池量（质押对 core、组 LP 对 Router），写成跨层验收断言而不是加
派生字段。不加 `inputTokenSymbol`（机器可读值不得用 `string`），不加 Router 地址（不可变部署参数
不进事件）。

事件名保留 `Hub` 前缀，但它是**可读性约定、不承担唯一性职责**：链下必须按发射合约地址区分同名事件
（[event-standards.md §5.1.1](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/event-standards.md#511-唯一性的边界)）。

## 门禁

```bash
forge build --force --deny warnings
forge test
forge lint
python3 script/events/check-events.py
python3 test/deploy_scripts_test.py
```

`forge build --sizes` 的单合约上限（24,576 字节）同样纳入门禁，见 `.github/workflows/ci.yml`。
`test/deploy_scripts_test.py` 守的是 shell 脚本的回归（`forge test` 看不到的那一层）。

## 依赖

### 工具链前置

| 工具 | 用途 |
| --- | --- |
| Foundry `1.8.1`+（`forge`） | 编译、测试、lint、脚本 |
| `python3` | `script/events/check-events.py`、`test/deploy_scripts_test.py`；部署脚本 `21_check_hub.sh` 也用它读 ABI |

| 依赖 | 用途 |
| --- | --- |
| `lib/core` | `IStake` / `ILaunch` / `IMemberNFT` / `ILOVE20Token`；`libs` 与 OpenZeppelin 经它传递 |
| `lib/forge-std` | 测试与脚本工具链 |

`remappings.txt` 列出实际 import 所需的三个别名：`@core/`、`@openzeppelin/contracts/`、`@forge-std/`。
`foundry.toml` 设 `auto_detect_remappings = false`，别名只追加不重指。

> **本地开发用软链，发布时改子模块。** 工作区里 `lib/core` 与 `lib/forge-std` 是指向
> `../../core` 与 `../../core/lib/forge-std` 的相对软链（与 `compatibility`、`anvil` 一致），
> 这样跨仓改动可以就地编译验证而不用反复 `forge update`。`.gitmodules` 已按 `action` 的形态写好
> 两个子模块的真实 URL，**首次推送前**需要把它们替换成真实 gitlink：
>
> ```bash
> git submodule add https://github.com/LOVE20BSC/core.git lib/core
> git submodule add https://github.com/foundry-rs/forge-std.git lib/forge-std
> forge install --no-commit   # 或按 action 的方式固定 lock
> ```
>
> 软链形态下 `forge build --locked` 会因 `foundry.lock` 与「不是子模块」冲突而失败，因此本仓在
> 软链阶段不提交 `foundry.lock`；切成真实子模块时再一并提交 `foundry.lock`。

## 部署

本仓的**已部署合约集合未冻结**（每个新外围合约都是一个新模块），因此按
[dev-standards.md §6.1](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/dev-standards.md#61-deploy-脚本)
**只按模块给入口，不设全仓统一的 `one_click_deploy.sh`**：统一入口要么重复部署已在链上的合约，
要么覆盖不了下一个新模块。

```bash
script/deploy/one_click_deploy_hub.sh <network>   # 入口：编排 11 → 21 → 31
script/deploy/11_deploy_hub.sh <network>          # 部署，写 addresses.hub.params
script/deploy/21_check_hub.sh <network>           # 只读复核，可重复运行
script/deploy/31_verify_hub.sh <network>          # 开源验证（按 VERIFY_SKIP_CHAIN_IDS 跳过）
```

新增模块 = 一套自包含脚本（`one_click_deploy_<x>.sh` + 自己的步骤脚本 + 自己的参数文件 + 自己的
`addresses.<x>.params`），编号在仓内按模块分段（`11`/`21`/`31`、`12`/`22`/`32`）。各模块的部署输入
互不要求存在。

### 网络配置

`script/network/<链名><链id>_<部署类型>/` 下：

| 文件 | 内容 |
| --- | --- |
| `.account` | keystore 账户与密码（**不入库**，模板见 `.account.example`） |
| `network.params` | `CHAIN_ID`、`RPC_URL`、`ETHERSCAN_API_KEY` |
| `hub.params` | 本模块的 DEX 费率 profile：`SWAP_FEE_FOR_LP_RATIO` / `SWAP_FEE_FOR_PROTOCOL_RATIO`，以及可选的 `SWAP_FEE_PROBE_TOKEN`（广播前交叉校验用） |
| `addresses.core.params` | 依赖方 `core` 的地址簿（从 `core` 复制） |
| `addresses.uniswapv2.params` | 依赖方 DEX 的 Router / Factory / WrappedNative（从 `dex` 复制） |
| `addresses.hub.params` | 本模块部署产物（`HUB_ADDRESS`） |

`script/network/verifier.params` 由所有网络共用：`ETHERSCAN_VERIFIER_URL` 与
`VERIFY_SKIP_CHAIN_IDS`。验证默认开启，只有列在跳过名单里的链才跳过——漏配的后果是该步骤失败，
而不是一条没验证的部署看起来像成功。`56` / `97` 不得出现在跳过名单。

## 测试

`test/` 下的 mock 使用**真实 constant-product 数学**，不是桩：

- `MockUniswapV2Pair` / `MockUniswapV2Router02`：`getAmountOut` 逐字照搬 `UniswapV2Library`，
  `mint` 含首铸锁定 `MINIMUM_LIQUIDITY` 与 `_mintFee` 的 1/6 协议费分支；
- `MockStake`：`_optimalAmounts` 逐字照搬 `core/src/Stake.sol`，并按折算结果**只拉折算后的量**，
  这样 `prepared − remaining` 才真的能观测到 core 的行为。

覆盖：单币与**双边**输入各一笔成功用例（双边在失衡池上换掉超额侧）；空池首次注资与缺池建池；
`prepared − remaining >= Min` 不满足即回滚（两个方向）；`prepared − remaining` 恒等于 core
`LiquidityStaked` 的入池量（同 tx 两层日志联立）；组 LP 与报价入口；报价与写入结果逐 wei 相等，且
**在三种真实 DEX profile 下都相等**；报价纯 `view` 不改状态；协议费分支（含「本地区块链不抽成」与
「Pancake 主网抽成」两侧）；退款形态；事件两个族的根键与三个 indexed 槽；「恰好备齐、无剩余」/
「比例失衡、有剩余」两类夹具；构造期费率校验与闭式解的溢出边界。
