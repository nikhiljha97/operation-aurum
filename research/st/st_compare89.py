"""89 paired runs: full vs lightweight SuperTrend AI on identical simulated price series."""
import math, statistics as S
src = open(__file__.replace('st_compare89.py', 'st_compare.py')).read().split('for mode in (')[0]
g = {}
exec(src, g)
N = 89
rows = []
for seed in range(1, N + 1):
    f = g['run']('full', seed * 7919)
    l = g['run']('lite', seed * 7919)
    rows.append((f, l))
def ci(xs):
    m = S.mean(xs); se = S.stdev(xs) / math.sqrt(len(xs)); return m, m - 1.96 * se, m + 1.96 * se
def sep(r): return r[2] / r[3] if r[3] > 0 else float('nan')
metrics = {
    'separation (trend÷chop strength)': (lambda r: sep(r)),
    'whipsaws in trends (1200 bars)': (lambda r: r[0]),
    'whipsaws in chop (600 bars)': (lambda r: r[1]),
}
print(f"{N} paired runs · 95% confidence intervals\n")
print(f"{'metric':36s} | {'full':>18s} | {'lightweight':>18s} | lightweight − full (paired)")
for name, fn in metrics.items():
    fv = [fn(f) for f, l in rows]; lv = [fn(l) for f, l in rows]
    d = [b - a for a, b in zip(fv, lv)]
    mf, _, _ = ci(fv); ml, _, _ = ci(lv); md, lo, hi = ci(d)
    verdict = "no significant difference" if lo <= 0 <= hi else ("lightweight HIGHER" if lo > 0 else "lightweight LOWER")
    print(f"{name:36s} | {mf:18.2f} | {ml:18.2f} | {md:+.2f} [{lo:+.2f}, {hi:+.2f}] → {verdict}")
wins = sum(1 for f, l in rows if sep(l) >= sep(f))
print(f"\nlightweight separated trend from chop at least as well as full in {wins}/{N} runs")
