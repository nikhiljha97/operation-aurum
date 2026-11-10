"""Python port of the SK v7 Auto-ML block, run on synthetic trades with a regime flip.
Checks: skill > 0 when signal exists, skill drops at the flip, retrain fires, skill recovers,
and gating only happens while skill > gate."""
import math, random
random.seed(3)
K, H = 10, 6
NL, NN = 4, 2
M = NL + NN
lr = [0.02, 0.06, 0.15, 0.4, 0.05, 0.15]
l2 = [0.001, 0.01, 0.01, 0.05, 0.005, 0.005]
W = [[0.0] * K for _ in range(NL)]
def rnd(k):
    r = math.sin(k * 12.9898 + 78.233) * 43758.5453
    return r - math.floor(r) - 0.5
def init_nn(j, seed):
    return [[rnd(seed * 1000 + j * 97 + h * K + i) * 0.6 for i in range(K)] for h in range(H)], [0.0] * (H + 1)
N1, N2 = [None] * NN, [None] * NN
for j in range(NN):
    N1[j], N2[j] = init_nn(j, 1)
sig = lambda z: 1 / (1 + math.exp(-max(-30, min(30, z))))
def lgp(m, x): return sig(sum(W[m][i] * x[i] for i in range(K)))
def lgt(m, x, y, a, b):
    g = y - lgp(m, x)
    for i in range(K):
        W[m][i] += a * (g * x[i] - (0 if i == 0 else b * W[m][i]))
def nnp(j, x):
    z = N2[j][H]
    for h in range(H):
        z += N2[j][h] * math.tanh(sum(N1[j][h][i] * x[i] for i in range(K)))
    return sig(z)
def nnt(j, x, y, a, b):
    hs = [math.tanh(sum(N1[j][h][i] * x[i] for i in range(K))) for h in range(H)]
    z = N2[j][H] + sum(N2[j][h] * hs[h] for h in range(H))
    g = y - sig(z)
    for h in range(H):
        v = N2[j][h]; gh = g * v * (1 - hs[h] ** 2)
        N2[j][h] = v + a * (g * hs[h] - b * v)
        for i in range(K):
            N1[j][h][i] += a * (gh * x[i] - b * N1[j][h][i])
    N2[j][H] += a * g
P = lambda m, x: lgp(m, x) if m < NL else nnp(m - NL, x)
def T(m, x, y, d):
    (lgt if m < NL else nnt)(m if m < NL else m - NL, x, y, lr[m] * d, l2[m])
br = [0.25] * M
ens_br = base_br = 0.25
n = wins = retrains = last_rt = 0
buf = []
GATE, RETRAIN, COOL, EPOCHS, BUFN, HALF, MIN = 0.02, 0.0, 20, 2, 150, 30, 30
def ens(p):
    best = min(br); w = [math.exp(-40 * (br[m] - best)) for m in range(M)]
    return sum(w[m] * p[m] for m in range(M)) / sum(w)
log = []
for t in range(900):
    x = [1.0] + [random.gauss(0, 1) for _ in range(K - 1)]
    flip = -1 if t >= 300 and t < 600 else 1                 # regime: feature 1 predicts wins, then the reverse, then back
    y = 1.0 if random.random() < sig(-0.6 + 1.4 * flip * x[1] + 0.5 * x[2]) else 0.0
    preds = [P(m, x) for m in range(M)]
    pe = ens(preds)
    skill = 1 - ens_br / base_br if n >= 10 and base_br > 0 else None
    gating = n >= MIN and skill is not None and skill > GATE
    aw = 2 / (HALF + 1); pb = (wins + 1) / (n + 2)
    for m in range(M):
        br[m] += aw * ((preds[m] - y) ** 2 - br[m])
    ens_br += aw * ((pe - y) ** 2 - ens_br)
    base_br += aw * ((pb - y) ** 2 - base_br)
    d = 1 / math.sqrt(1 + n / 50)
    for m in range(M):
        T(m, x, y, d)
    buf.append((x, y)); buf = buf[-BUFN:]
    n += 1; wins += int(y)
    sk = 1 - ens_br / base_br if n >= 10 else None
    if n >= MIN and sk is not None and sk < RETRAIN and n - last_rt >= COOL:
        for m in range(M):
            if br[m] >= base_br:
                f = 0.5 if (retrains + m) % 2 == 0 else 2.0
                lr[m] = max(0.005, min(1.0, lr[m] * f)); l2[m] = max(0.0005, min(0.2, l2[m] * (2.0 if (retrains + m) % 3 == 0 else 0.7)))
                if m < NL: W[m] = [0.0] * K
                else: N1[m - NL], N2[m - NL] = init_nn(m - NL, retrains + 2)
                br[m] = base_br
                for _ in range(EPOCHS):
                    for bx, by in buf: T(m, bx, by, 1.0)
        retrains += 1; last_rt = n; ens_br = base_br
        log.append(t)
    if t % 50 == 49:
        print(f"trade {t+1:4d}  regime {'normal ' if flip == 1 else 'FLIPPED'}  rolling skill {sk:+.3f}  gating {str(gating):5s}  retrains so far {retrains}")
print("retrain fired at trades:", log)
