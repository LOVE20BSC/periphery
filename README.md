# periphery

依赖 LOVE20 协议**已部署合约**的外围合约。本仓的定位是「可随时替换」：它读取 `core` 的状态、
写入 `core` 的账本，但自己**不持有账本、不发行凭证、不折叠协议状态**。

判据是一条编译期事实：`periphery` 的合约 `import @core/`，`tools` 的合约不 import 任何协议合约。
新增合约归属哪个仓库按「是否依赖协议已部署合约」判定，见
[repositories.md](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/repositories.md)。

## 合约

| 合约 | 角色 |
| --- | --- |
| `src/LOVE20Hub.sol` | 单币流动性质押、单币组 LP、配对报价 |

`LOVE20Hub` 覆盖原 `UniswapV2Zap` 的全部能力，并在此之上追加一笔 `Stake.stakeLiquidity` 记账：

- **单币质押**：`stakeLiquidityWithToken`（ERC20 输入）/ `stakeLiquidityWithNative`（原生币输入）；
- **单币组 LP**：`addLiquidityWithToken` / `addLiquidityWithNative`，LP 直接发给 `to`，不产生质押记账；
- **报价**：`quoteSingleTokenLp` / `quoteSingleTokenStake`，纯 `view` 试算。

swap、折算、退款三者的实现在四条写入口之间**共用一份**，数学只存在一处。

### 依赖注入

构造函数只接受 `stakeAddress`，其余依赖全部由它派生：

```text
stakeAddress
├─ ROUTER_ADDRESS        ← Stake.ROUTER_ADDRESS()
├─ PAIR_FACTORY_ADDRESS  ← Stake.PAIR_FACTORY_ADDRESS()
├─ LAUNCH_ADDRESS        ← Stake.LAUNCH_ADDRESS()
├─ MEMBER_NFT_ADDRESS    ← Stake.MEMBER_NFT_ADDRESS()
└─ WRAPPED_NATIVE_ADDRESS ← Router.WETH()
```

全部 `immutable` + 全大写。没有 `init`、没有 `initialized`：构造期完成后没有任何可初始化的状态。
派生结果由 `DeployHub.s.sol` 在**广播前**逐项复核，`21_check_hub.sh` 在部署后独立再复核一次。

### 价格保护

`core` 的 `stakeLiquidity` 已删除 `slippage`，只按 Pair 储备把收到的两种币尽可能放进质押，放不下的
留在调用者手里。Hub 的入参因此只有 `tokenAmountMin` / `parentTokenAmountMin`：

- 语义是**全链路终点**——「最终至少有多少社区币 / 父币进入质押（或进入 LP）」，不是 swap 段的
  `amountOutMin`；
- 校验方式是 Hub 调 `core` **之后**以自身余额差取 `prepared − remaining`，与 Min 比较；
- **不在 Hub 里复刻 core 的折算公式**：core 扣掉多少完全由它自己决定，Hub 只观测余额变化。

`swap` 段另有一个 1% 的内部输出界（`SWAP_OUTPUT_TOLERANCE_RATIO`）。它不暴露为入参，只用于
把 swap 段的夹子变成回滚；同一笔内池子不可能在「读储备」与「swap」之间移动，所以按 swap 前储备算出的
`_amountOut` 就是 router 应当返回的值。

### `promisedWaitingPhases` 经 Hub 时没有自由度（重要）

`core` 的等待期规则依赖**调用者是不是该 `memberId` 的 NFT 持有人**：非持有人在目标已有仓位时
只能**精确沿用**现有等待期（见 `core/docs` 规格 `04-stake.md` 的拒绝条件表）。而 Hub 调
`stakeLiquidity` 时 `msg.sender` 是 **Hub 自己**，永远不会等于 NFT 持有人，所以：

- **空仓位**（该 `memberId` 在该社区还没有任何质押）：`promisedWaitingPhases` 可自由指定，含 `MAX`；
- **已有仓位**：**必须精确传入当前值**，否则回滚 `PromisedWaitingPhasesDecreased`。经 Hub 无法提升
  等待期。

这是 core 鉴权语义的必然结果，不是 Hub 的额外限制。要提升等待期，由持有人**直接调用**
`Stake.stakeLiquidity`；Hub 不提供这条路径，也不打算复制它。

前端调用前应先读 `Stake.memberStake(tokenAddress, memberId)` 的 `promisedWaitingPhases` 并原样回填。

### 退款

退款形态由**函数分支唯一定确定**，没有 `refundAsNative` 之类的入参：

- ERC20 分支原样退 ERC20；
- 原生币分支退原生币（先 `WBNB.withdraw` 再转发）；
- WETH 退款统一按 WBNB 量纲记数，形态不进事件——事件区分不出、也不该区分。

## 事件

事件族为 `periphery.hub`，登记在 `script/events/event-families.txt`，槽位规则见
[event-standards.md §6.1](https://github.com/LOVE20BSC/matt-gov/blob/main/docs/event-standards.md#61-字段顺序)。
三个 indexed 槽：

| 事件 | indexed 槽 |
| --- | --- |
| `HubLiquidityStakedWithToken` | `tokenAddress` / `memberId` / `caller` |
| `HubLiquidityStakedWithNative` | `tokenAddress` / `memberId` / `caller` |
| `HubLiquidityAddedWithToken` | `tokenAddress` / `to` / `caller` |
| `HubLiquidityAddedWithNative` | `tokenAddress` / `to` / `caller` |

组 LP 不产生质押记账，因此该族的两条 LP 事件不带 `memberId`，第二个槽给该事实实际需要的对象键
`to`（§6.1 periphery 族）。

**Hub 事件只记编排事实**：`prepared*` / `remaining*` 四个量。份额、票权、等待期、各种 `total*` 一律
不复制——那些由同一笔交易里 `core` 的 `LiquidityStaked` 提供，两处各记一遍就是双份对账源。
`prepared − remaining` 恒等于 core 的实际入池量，写成跨层验收断言而不是加派生字段。
不加 `inputTokenSymbol`（机器可读值不得用 `string`），不加 Router 地址（不可变部署参数不进事件）。

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
| `hub.params` | 本模块自己的参数（当前为空：Hub 除 `STAKE_ADDRESS` 外无构造参数） |
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

覆盖：ERC20 / 原生币两支各一笔成功用例；`prepared − remaining >= Min` 不满足即回滚（两个方向）；
`prepared − remaining` 恒等于 core `LiquidityStaked` 的入池量（同 tx 两层日志联立）；组 LP 与报价
入口；报价与写入结果逐 wei 相等；报价纯 `view` 不改状态；协议费分支；退款形态；事件三个 indexed
槽与「恰好备齐、无剩余」/「比例失衡、有剩余」两类夹具。
