"""Monte Carlo: prop-firm pass & first-payout odds at a 45% win rate, strict 1:2 R:R.
Assumptions: 1 trade/day, each trade = -1R or +2R, cost 8% of R per trade (gold/oil spread+slippage),
trades independent. Drawdown modes: static (fixed floor), eod (trails end-of-day high, locks at start+$100).
Rules are taken from third-party pages and must be verified on each firm's site."""
import random
random.seed(7)
N=200000
def run(risk,target,dd,mode,p,cost=0.08,lock=100):
    bal=0.0;floor=-dd;peak=0.0;n=0
    while True:
        n+=1
        bal += (2*risk if random.random()<p else -risk) - cost*risk
        if bal<=floor: return 0,n
        if bal>=target: return 1,n
        if mode=='eod':
            peak=max(peak,bal); floor=max(floor,min(peak-dd,lock))
def est(*a,**k):
    s=t=0
    for _ in range(N):
        r,n=run(*a,**k); s+=r; t+=n
    return s/N,t/N
p=0.45
rows=[]
def acct(name,fee,risk,phases,funded,payout):
    prob=1.0;trades=0
    for tgt,dd,mode in phases:
        q,n=est(risk,tgt,dd,mode,p); prob*=q; trades+=n
    f,nf=est(risk,*funded,p)
    ev=prob*f*payout
    rows.append((name,fee,risk,prob,f,prob*f,ev,ev/fee,trades,nf))
# The5ers High Stakes 5K Classic: 8% / 5% targets, 10% static max loss; funded payout modelled at +4% ($200) x80%
for r in (50,25):
    acct(f"The5ers HS 5K Classic r=${r}",39,r,[(400,500,'static'),(250,500,'static')],(200,500,'static'),160)
    acct(f"The5ers HS 5K New r=${r}",35,r,[(500,500,'static'),(250,500,'static')],(200,500,'static'),160)
    acct(f"Maven 5K 2-Step r=${r}",22,r,[(400,400,'static'),(250,400,'static')],(200,400,'static'),182)
for r in (125,100):
    acct(f"Lucid 25K Flex EOD r=${r}",50,r,[(1250,1000,'eod')],(1000,1000,'eod'),450)
out=["Win rate 45%, 1:2 R:R, cost 0.08R/trade, 200k sims each",
     f"{'account':30s} {'fee':>4s} {'pass':>5s} {'fund->pay':>9s} {'P(payout)':>9s} {'E[payout]':>9s} {'EV/fee':>6s} {'eval trades':>11s} {'funded trades':>13s}"]
for name,fee,risk,pr,f,pp,ev,x,t,nf in rows:
    out.append(f"{name:30s} ${fee:>3d} {pr:5.2f} {f:9.2f} {pp:9.2f} ${ev:8.0f} {x:5.1f}x {t:11.0f} {nf:13.0f}")
open('results45.txt','w').write("\n".join(out)+"\n"); print("\n".join(out))
