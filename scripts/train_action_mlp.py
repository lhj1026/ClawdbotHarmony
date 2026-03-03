#!/usr/bin/env python3
"""
train_action_mlp.py
用 numpy 训练 71→64→40 MLP，导出权重为 action_weights.h

用法:
  python3 scripts/train_action_mlp.py

输出:
  entry/src/main/cpp/context_engine/action_weights.h
"""
import json, os, sys
import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT    = os.path.dirname(SCRIPT_DIR)

DATA_PATH = os.path.join(SCRIPT_DIR, 'training_data.json')
OUT_PATH  = os.path.join(PROJECT, 'entry/src/main/cpp/context_engine/action_weights.h')

# ── 超参 ────────────────────────────────────────────────────────────
HIDDEN   = 64
EPOCHS   = 2000
LR       = 0.01
REG      = 1e-4     # L2 正则
SEED     = 42

np.random.seed(SEED)

# ── 加载数据 ─────────────────────────────────────────────────────────
print(f"读取训练数据: {DATA_PATH}")
with open(DATA_PATH) as f:
    data = json.load(f)

samples = data['samples']
FEAT_DIM = data['meta']['feat_dim']  # 71
ACT_DIM  = data['meta']['act_dim']   # 40
print(f"样本数: {len(samples)}, feat_dim={FEAT_DIM}, act_dim={ACT_DIM}")

X = np.array([s['x'] for s in samples], dtype=np.float32)   # (N, 71)
Y = np.array([s['y'] for s in samples], dtype=np.float32)   # (N, 40)

# ── 稀有动作上采样（防止高频动作淹没稀有动作）─────────────────────
# 统计每个动作的正样本数，对出现 < median 次的动作的样本重复采样
act_counts = (Y > 0).sum(axis=0)       # 每个动作出现次数
median_count = np.median(act_counts[act_counts > 0])
print(f"动作出现次数: min={act_counts[act_counts>0].min()}, "
      f"median={median_count:.0f}, max={act_counts.max()}")

extra_X, extra_Y = [], []
for act_idx in range(ACT_DIM):
    cnt = act_counts[act_idx]
    if cnt == 0: continue
    repeat = max(1, int(median_count / cnt)) - 1  # 稀有动作额外重复几次
    if repeat > 0:
        mask = Y[:, act_idx] > 0
        extra_X.append(np.repeat(X[mask], repeat, axis=0))
        extra_Y.append(np.repeat(Y[mask], repeat, axis=0))

if extra_X:
    X_oversample = np.vstack(extra_X)
    Y_oversample = np.vstack(extra_Y)
    X = np.vstack([X, X_oversample])
    Y = np.vstack([Y, Y_oversample])
    print(f"上采样后: {len(X)} 个样本")

# 数据扩增：添加轻微噪声
N = len(X)
noise = np.random.randn(N, FEAT_DIM).astype(np.float32) * 0.03
X_aug = np.clip(X + noise, 0, 1)
X_all = np.vstack([X, X_aug])
Y_all = np.vstack([Y, Y])
print(f"扩增后样本数: {len(X_all)}")

# ── 初始化权重（Xavier）────────────────────────────────────────────
def xavier(fan_in, fan_out):
    limit = np.sqrt(6.0 / (fan_in + fan_out))
    return np.random.uniform(-limit, limit, (fan_out, fan_in)).astype(np.float32)

W1 = xavier(FEAT_DIM, HIDDEN)   # (64, 71)
b1 = np.zeros(HIDDEN, np.float32)
W2 = xavier(HIDDEN, ACT_DIM)    # (40, 64)
b2 = np.zeros(ACT_DIM, np.float32)

# ── 前向/后向 ───────────────────────────────────────────────────────
def relu(z):    return np.maximum(0, z)
def drelu(z):   return (z > 0).astype(np.float32)
def softmax(z):
    e = np.exp(z - z.max(axis=1, keepdims=True))
    return e / e.sum(axis=1, keepdims=True)

def forward(Xb):
    z1 = Xb @ W1.T + b1          # (B, 64)
    a1 = relu(z1)
    z2 = a1 @ W2.T + b2          # (B, 40)
    out = softmax(z2)
    return z1, a1, out

def mse_loss(pred, target):
    return ((pred - target) ** 2).mean()

# ── 训练循环（mini-batch SGD + Adam）─────────────────────────────────
m_W1 = np.zeros_like(W1); v_W1 = np.zeros_like(W1)
m_b1 = np.zeros_like(b1); v_b1 = np.zeros_like(b1)
m_W2 = np.zeros_like(W2); v_W2 = np.zeros_like(W2)
m_b2 = np.zeros_like(b2); v_b2 = np.zeros_like(b2)
beta1, beta2, eps_adam = 0.9, 0.999, 1e-8

def adam_update(p, g, m, v, t):
    m = beta1 * m + (1 - beta1) * g
    v = beta2 * v + (1 - beta2) * g**2
    mh = m / (1 - beta1**t)
    vh = v / (1 - beta2**t)
    p -= LR * mh / (np.sqrt(vh) + eps_adam)
    return p, m, v

BATCH = min(32, len(X_all))
best_loss = float('inf')
best_W1 = W1.copy(); best_b1 = b1.copy()
best_W2 = W2.copy(); best_b2 = b2.copy()

for epoch in range(1, EPOCHS + 1):
    # shuffle
    idx = np.random.permutation(len(X_all))
    Xs, Ys = X_all[idx], Y_all[idx]
    epoch_loss = 0.0
    t = (epoch - 1) * (len(X_all) // BATCH) + 1

    for start in range(0, len(Xs), BATCH):
        Xb = Xs[start:start+BATCH]
        Yb = Ys[start:start+BATCH]
        B = len(Xb)

        # forward
        z1, a1, pred = forward(Xb)

        # MSE loss on soft labels
        loss = mse_loss(pred, Yb)
        epoch_loss += loss

        # backward
        dL_dpred = 2 * (pred - Yb) / (B * ACT_DIM)  # (B, 40)

        # softmax jacobian: dL/dz2 = pred * (dL - sum(dL*pred))
        dL_dz2 = pred * (dL_dpred - (dL_dpred * pred).sum(axis=1, keepdims=True))

        dL_dW2 = dL_dz2.T @ a1 + REG * W2          # (40, 64)
        dL_db2 = dL_dz2.sum(axis=0)                 # (40,)
        dL_da1 = dL_dz2 @ W2                        # (B, 64)
        dL_dz1 = dL_da1 * drelu(z1)                 # (B, 64)
        dL_dW1 = dL_dz1.T @ Xb + REG * W1           # (64, 71)
        dL_db1 = dL_dz1.sum(axis=0)                 # (64,)

        W2, m_W2, v_W2 = adam_update(W2, dL_dW2, m_W2, v_W2, t)
        b2, m_b2, v_b2 = adam_update(b2, dL_db2, m_b2, v_b2, t)
        W1, m_W1, v_W1 = adam_update(W1, dL_dW1, m_W1, v_W1, t)
        b1, m_b1, v_b1 = adam_update(b1, dL_db1, m_b1, v_b1, t)
        t += 1

    if epoch % 200 == 0 or epoch == 1:
        print(f"  epoch {epoch:4d}/{EPOCHS}  loss={epoch_loss:.6f}")
    if epoch_loss < best_loss:
        best_loss = epoch_loss
        best_W1 = W1.copy(); best_b1 = b1.copy()
        best_W2 = W2.copy(); best_b2 = b2.copy()

print(f"\n最优 loss: {best_loss:.6f}")

# ── 验证 Top-3 命中率 ────────────────────────────────────────────────
_, _, pred_all = forward(X)
hits = 0
for i in range(len(X)):
    top3_pred = set(np.argsort(pred_all[i])[-3:])
    top3_true = set(np.argsort(Y[i])[-3:])
    if top3_pred & top3_true: hits += 1
print(f"Top-3 命中率: {hits}/{len(X)} = {100*hits/len(X):.1f}%")

# ── 导出 C++ header ─────────────────────────────────────────────────
def arr_to_cpp(name, arr, fmt="{:.8f}f"):
    flat = arr.flatten()
    vals = ", ".join(fmt.format(v) for v in flat)
    return f"static const float {name}[{len(flat)}] = {{{vals}}};\n"

actions_comment = "\n".join(
    f"//   [{i:2d}] {a['code']} {a['name']}"
    for i, a in enumerate(data['actions'])
)

header = f"""/**
 * action_weights.h — 自动生成，请勿手动编辑
 * 由 scripts/train_action_mlp.py 生成
 *
 * MLP 结构: {FEAT_DIM} → {HIDDEN} → {ACT_DIM}
 * 训练样本: {len(samples)} 个状态行（来自推荐矩阵）
 * 最终 MSE: {best_loss:.6f}
 *
 * 动作索引：
{actions_comment}
 */
#pragma once
namespace context_engine {{

constexpr int ACT_MLP_IN  = {FEAT_DIM};
constexpr int ACT_MLP_H1  = {HIDDEN};
constexpr int ACT_MLP_OUT = {ACT_DIM};

// Layer 1: [{HIDDEN}][{FEAT_DIM}]
{arr_to_cpp("ACT_W1", best_W1)}
{arr_to_cpp("ACT_B1", best_b1)}
// Layer 2: [{ACT_DIM}][{HIDDEN}]
{arr_to_cpp("ACT_W2", best_W2)}
{arr_to_cpp("ACT_B2", best_b2)}
}} // namespace context_engine
"""

with open(OUT_PATH, 'w') as f:
    f.write(header)
print(f"✅ 权重已导出 → {OUT_PATH}")
print(f"   W1:{best_W1.shape} b1:{best_b1.shape} W2:{best_W2.shape} b2:{best_b2.shape}")
