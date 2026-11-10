"""Full (k-means volatility, every bar) vs lite (percentile regimes, refit every 5 bars) SuperTrend AI."""
import math, random
def series(seed):
    random.seed(seed); px = [4100.0]
    for t in range(1800):
        drift = 0.08 if t < 600 else (0.0 if t < 1200 else -0.08)
        px.append(px[-1] + drift + random.gauss(0, 0.6))
    hi = [p + abs(random.gauss(0, 0.4)) for p in px]; lo = [p - abs(random.gauss(0, 0.4)) for p in px]
    return px, hi, lo
def atr_series(px, hi, lo, n):
    out, a = [], None
    for i in range(len(px)):
        tr = hi[i] - lo[i] if i == 0 else max(hi[i] - lo[i], abs(hi[i] - px[i-1]), abs(lo[i] - px[i-1]))
        a = tr if a is None else (a * (n - 1) + tr) / n
        out.append(a)
    return out
def kmeans1d(vals, init, iters):
    c = list(init)
    for _ in range(iters):
        lab = [min(range(3), key=lambda j: abs(v - c[j])) for v in vals]
        new = [sum(v for v, l in zip(vals, lab) if l == j) / sum(1 for l in lab if l == j) if any(l == j for l in lab) else c[j] for j in range(3)]
        if new == c: break
        c = new
    return c, lab
def pct(vals, p):
    s = sorted(vals); return s[min(len(s) - 1, max(0, int(math.ceil(p / 100 * len(s))) - 1))]
def run(mode, seed, atr_n=21, mem=89, fmin=3.0, fmax=5.0, step=0.5, volw=89):
    px, hi, lo = series(seed); hl2 = [(h + l) / 2 for h, l in zip(hi, lo)]
    atr = atr_series(px, hi, lo, atr_n)
    facs = [fmin + step * i for i in range(int((fmax - fmin) / step) + 1)]; nf = len(facs)
    up = [hl2[0]] * nf; dn = [hl2[0]] * nf; tr = [0] * nf; out = [hl2[0]] * nf; per = [0.0] * nf
    al = 2 / (mem + 1); buf = []; q = None; factor = (fmin + fmax) / 2; pbest = 0.0
    uB = lB = None; os = 0; sd = 0; den = None
    flips = [0, 0, 0]; strength = [0.0, 0.0, 0.0]
    for i in range(1, len(px)):
        c, c1 = px[i], px[i-1]
        buf.append(atr[i]); buf = buf[-volw:]
        refit = (i % 5 == 0) if mode == 'lite' else True
        a = atr[i]
        if len(buf) >= 20:
            if mode == 'full':
                cent, _ = kmeans1d(buf, [pct(buf, 25), pct(buf, 50), pct(buf, 75)], 10)
            elif refit or q is None:
                q = [pct(buf, 17), pct(buf, 50), pct(buf, 83)]
            cent = cent if mode == 'full' else q
            a = min(cent, key=lambda x: abs(atr[i] - x))
        for k, f in enumerate(facs):
            u, d = hl2[i] + a * f, hl2[i] - a * f
            t = 1 if c > up[k] else 0 if c < dn[k] else tr[k]; tr[k] = t
            up[k] = min(u, up[k]) if c1 < up[k] else u
            dn[k] = max(d, dn[k]) if c1 > dn[k] else d
            di = (c1 > out[k]) - (c1 < out[k]); per[k] += al * ((c - c1) * di - per[k])
            out[k] = dn[k] if t == 1 else up[k]
        if refit:
            init = [pct(per, 25), pct(per, 50), pct(per, 75)] if mode == 'full' else [min(per), (min(per) + max(per)) / 2, max(per)]
            cent, lab = kmeans1d(per, init, 25 if mode == 'full' else 10)
            b = max(range(3), key=lambda j: cent[j]); sel = [k for k in range(nf) if lab[k] == b]
            factor = sum(facs[k] for k in sel) / len(sel); pbest = sum(per[k] for k in sel) / len(sel)
        den = abs(c - c1) if den is None else den + 2 / (mem + 1) * (abs(c - c1) - den)
        st = max(pbest, 0) / den if den > 0 else 0
        u, d = hl2[i] + a * factor, hl2[i] - a * factor
        uB = u if uB is None else (min(u, uB) if c1 < uB else u)
        lB = d if lB is None else (max(d, lB) if c1 > lB else d)
        os = 1 if c > uB else 0 if c < lB else os
        nd = 1 if os == 1 else -1; ph = 0 if i < 600 else 1 if i < 1200 else 2
        if sd != 0 and nd != sd: flips[ph] += 1
        sd = nd; strength[ph] += st
    return flips[0] + flips[2], flips[1], (strength[0] + strength[2]) / 1200, strength[1] / 600
for mode in ('full', 'lite'):
    r = [run(mode, s) for s in (5, 11, 23, 42, 77)]
    ft = sum(x[0] for x in r) / 5; fc = sum(x[1] for x in r) / 5; st = sum(x[2] for x in r) / 5; sc = sum(x[3] for x in r) / 5
    print(f"{mode:5s}: flips trend {ft:5.1f} · chop {fc:5.1f} | separation {st/sc:.2f}×")
