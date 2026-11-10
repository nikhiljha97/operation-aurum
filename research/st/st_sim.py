"""Python port of ST AI PRO's core (factor clustering + trailing stop) on synthetic trend/chop/trend prices."""
import math, random
random.seed(5)
# synthetic 1m-like closes: 600 bars up-trend, 600 bars chop, 600 bars down-trend
px = [4100.0]
for t in range(1800):
    drift = 0.08 if t < 600 else (0.0 if t < 1200 else -0.08)
    px.append(px[-1] + drift + random.gauss(0, 0.6))
hi = [p + abs(random.gauss(0, 0.4)) for p in px]; lo = [p - abs(random.gauss(0, 0.4)) for p in px]
hl2 = [(h + l) / 2 for h, l in zip(hi, lo)]
def atr_series(n=10):
    out, a = [], None
    for i in range(len(px)):
        tr = hi[i] - lo[i] if i == 0 else max(hi[i] - lo[i], abs(hi[i] - px[i-1]), abs(lo[i] - px[i-1]))
        a = tr if a is None else (a * (n - 1) + tr) / n
        out.append(a)
    return out
atr = atr_series()
facs = [1.0 + 0.5 * i for i in range(9)]
up = [hl2[0]] * 9; dn = [hl2[0]] * 9; tr = [0] * 9; out = [hl2[0]] * 9; per = [0.0] * 9
alpha = 2 / 11
uB = lB = None; os = 0; stDir = 0
flips = {0: 0, 1: 0, 2: 0}; strength_sum = {0: 0.0, 1: 0.0, 2: 0.0}; fac_seen = []
den = None
for i in range(1, len(px)):
    c, c1 = px[i], px[i-1]
    for k, f in enumerate(facs):
        u, d = hl2[i] + atr[i] * f, hl2[i] - atr[i] * f
        t = 1 if c > up[k] else 0 if c < dn[k] else tr[k]
        tr[k] = t
        up[k] = min(u, up[k]) if c1 < up[k] else u
        dn[k] = max(d, dn[k]) if c1 > dn[k] else d
        di = (c1 > out[k]) - (c1 < out[k])
        per[k] += alpha * ((c - c1) * di - per[k])
        out[k] = dn[k] if t == 1 else up[k]
    s = sorted(per); cent = [s[2], s[4], s[6]]
    for _ in range(25):
        lab = [min(range(3), key=lambda j: abs(v - cent[j])) for v in per]
        new = [sum(v for v, l in zip(per, lab) if l == j) / max(1, sum(1 for l in lab if l == j)) if any(l == j for l in lab) else cent[j] for j in range(3)]
        if new == cent: break
        cent = new
    best = max(range(3), key=lambda j: cent[j])
    sel = [k for k in range(9) if lab[k] == best]
    factor = sum(facs[k] for k in sel) / len(sel)
    fac_seen.append(factor)
    den = abs(c - c1) if den is None else den + alpha * (abs(c - c1) - den)
    strength = max(sum(per[k] for k in sel) / len(sel), 0) / den if den > 0 else 0
    u, d = hl2[i] + atr[i] * factor, hl2[i] - atr[i] * factor
    uB = u if uB is None else (min(u, uB) if c1 < uB else u)
    lB = d if lB is None else (max(d, lB) if c1 > lB else d)
    os = 1 if c > uB else 0 if c < lB else os
    nd = 1 if os == 1 else -1
    phase = 0 if i < 600 else 1 if i < 1200 else 2
    if stDir != 0 and nd != stDir: flips[phase] += 1
    stDir = nd
    strength_sum[phase] += strength
names = {0: 'up-trend', 1: 'chop    ', 2: 'down-trend'}
for p in range(3):
    print(f"{names[p]}: flips {flips[p]:3d} · avg strength {strength_sum[p] / 600:.2f}")
print(f"factor stayed within {min(fac_seen):.2f}–{max(fac_seen):.2f} (allowed 1.00–5.00)")
