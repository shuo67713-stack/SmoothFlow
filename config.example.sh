# SmoothFlow 5.0.5 可选配置
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 硕
# 复制到 /data/adb/smoothflow/config.sh 后，执行 action.sh stop 再 start（或重启）生效。
# 只接受 白名单键=纯数字；不执行任何 Shell 代码，不支持变量展开。
# 频率单位 kHz；不在内核频率表内时会自动对齐到最接近的可用值（升频取 ≥，上限取 ≤，其余取绝对值最近）。
# 仅支持 OPD2513 / SM8850 / Adreno 840 设备；设备身份、CPU policy 或必需 WALT 节点不符时拒绝写入。

# 日常档频率语义：raise = 只升不降（默认，厂商给得更高时不动）；set = 强制写入配置值
# ON_HS_POLICY=raise

# ---- 日常档（亮屏、非游戏）----
# ON_HS0=1497600        # 低性能簇 hispeed_freq
# ON_LOAD0=88           # 触发 hispeed 的负载百分比
# ON_RTG0=1209600       # 渲染线程 rtg_boost_freq
# ON_MIN0=0             # 0 = 不抬高最低频率
# ON_HS6=1804800
# ON_LOAD6=88
# ON_RTG6=1497600
# ON_MIN6=0
# ON_DOWN_RATE=20000    # 降频迟滞（微秒），越大越稳定、越小越省电
# ON_UP_RATE=0          # 0 = 保持内核默认（通常 0，即立刻升频）
# ON_MAX0=0             # 0 = 不限制上限

# ---- 游戏档 ----
# GAME_HS0=1804800
# GAME_LOAD0=80
# GAME_RTG0=1555200
# GAME_MIN0=0
# GAME_HS6=2496000
# GAME_LOAD6=80
# GAME_RTG6=1996800
# GAME_MIN6=0
# GAME_DOWN_RATE=8000
# GAME_UP_RATE=0
# GAME_UCLAMP=20        # 游戏时 top-app 组 uclamp.min（%）
# DISPLAY_UCLAMP=10     # SurfaceFlinger 所在 display 组 uclamp.min（%）
# TOP_UCLAMP=0          # 非 0 时覆盖游戏档 top-app uclamp

# ---- 省电档 ----
# ECO_MAX0=2496000
# ECO_MAX6=1996800
# ECO_MIN0=787200
# ECO_MIN6=883200
# ECO_HS0=1555200
# ECO_HS6=1804800
# ECO_LOAD=92
# ECO_UCLAMP=0

# ---- 游戏包名规则（空格分隔，支持 * 通配）----
# GAME_PATTERNS="com.tencent.tmgp.* com.miHoYo.* com.example.mygame"

# 5.0 说明：
# 帧时间闭环控制暂未启用。未完成 OPD2513 实机数据源验证前，
# 不添加猜测性的 FPS 估算、不自动调 GPU、不改厂商温控策略。
