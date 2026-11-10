// Monte Carlo worker (runs on its own CPU core via worker_threads).
// Simulates prop-firm challenge paths from a trade-outcome model and returns aggregates plus a few
// sampled equity curves for the War Room fan chart. Bayesian: each path draws its own win rate from
// Beta(wins + 1, losses + 1), so small samples produce honestly wider outcomes.
import { parentPort } from 'node:worker_threads';

parentPort.on('message', (job) => {
  const { id, n, seed, P } = job;
  let s = (seed >>> 0) || 1;
  const rnd = () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
  const gauss = () => { let u = 0; while (u === 0) u = rnd(); const v = rnd(); return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v); };
  const gamma = (a) => {                    // Marsaglia–Tsang
    if (a < 1) return gamma(a + 1) * Math.pow(rnd() || 1e-12, 1 / a);
    const d = a - 1 / 3, c = 1 / Math.sqrt(9 * d);
    for (;;) {
      let x, v;
      do { x = gauss(); v = 1 + c * x; } while (v <= 0);
      v = v * v * v;
      const u = rnd();
      if (u < 1 - 0.0331 * x ** 4) return d * v;
      if (Math.log(u) < 0.5 * x * x + d * (1 - v + Math.log(v))) return d * v;
    }
  };
  const beta = (a, b) => { const x = gamma(a), y = gamma(b); return x / (x + y); };

  const H = P.horizon;
  const ddBins = new Array(41).fill(0);     // max drawdown 0 … 20 % in 0.5 % steps
  const stBins = new Array(31).fill(0);     // longest losing streak 0 … 30
  let pass = 0, breach = 0, daily = 0, open = 0, ttpSum = 0;
  const sampled = [];
  const every = Math.max(1, Math.floor(n / Math.max(1, P.sample)));
  for (let i = 0; i < n; i++) {
    const p = P.bayes ? beta(P.wins + 1, P.losses + 1) : P.wins / Math.max(1, P.wins + P.losses);
    let eq = 0, peak = 0, mdd = 0, run = 0, mrun = 0, res = 0, dayStart = 0, k = 1;
    const keep = i % every === 0 ? new Array(H + 1).fill(0) : null;
    for (; k <= H; k++) {
      if ((k - 1) % P.perDay === 0) dayStart = eq;
      const win = rnd() < p;
      eq += (win ? P.W : P.L) * P.risk;
      if (eq > peak) peak = eq;
      if (peak - eq > mdd) mdd = peak - eq;
      run = win ? 0 : run + 1;
      if (run > mrun) mrun = run;
      if (keep) keep[k] = eq;
      if (eq >= P.target) { res = 1; break; }
      if (eq <= -P.maxLoss) { res = -1; break; }
      if (dayStart - eq >= P.dailyLoss) { res = -2; break; }
    }
    if (keep) { for (let j = k + 1; j <= H; j++) keep[j] = eq; sampled.push({ r: res, e: keep.map(v => Math.round(v * 100) / 100) }); }
    if (res === 1) { pass++; ttpSum += k; } else if (res === -1) breach++; else if (res === -2) daily++; else open++;
    ddBins[Math.min(40, Math.floor(mdd / 0.5))]++;
    stBins[Math.min(30, mrun)]++;
  }
  parentPort.postMessage({ id, viz: !!job.viz, n, pass, breach, daily, open, ttpSum, ddBins, stBins, sampled });
});
