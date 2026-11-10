"""Losing streaks, R:R trade-offs and trades-per-day for The5ers High Stakes 5K (Classic: 8%/5% targets,
10% static max loss, 5% daily loss). Cost 0.08R/trade. Funded payout: +4% ($200) before -10%, 80% split -> $160.
Fee $39. Rules from third-party pages; verify on the5ers.com."""
import random
random.seed(11)
out=[]
def P(s): out.append(s); print(s)

# 1) Exact probability of a losing streak >= k within n trades (DP), loss prob q
def p_streak(q,n,k):
    # state: current run length 0..k-1 ; absorbing when reaches k
    st=[1.0]+[0.0]*(k-1); hit=0.0
    for _ in range(n):
        new=[0.0]*k
        for r,pr in enumerate(st):
            new[0]+=pr*(1-q)
            if r+1==k: hit+=pr*q
            else: new[r+1]+=pr*q
        st=new
    return hit
P("1) P(at least one losing streak of >= k) at 45% win rate (q=0.55)")
P("   k:      " + "".join(f"{k:>7d}" for k in range(4,13)))
for n in (20,50,100,200):
    P(f"   n={n:<4d} " + "".join(f"{p_streak(0.55,n,k):7.0%}" for k in range(4,13)))
def exp_max(q,n): return sum(p_streak(q,n,k) for k in range(1,n+1))
P("   expected longest losing streak: " + ", ".join(f"n={n}: {exp_max(0.55,n):.1f}" for n in (20,50,100,200)))

# 2) Breakeven win rate & expectancy by R:R ; equal-edge comparison
P("\n2) R:R vs breakeven win rate (incl. 0.08R cost) and expectancy at 45%")
for rr in (1,1.5,2,3):
    be=(1+0.08)/(rr+1)
    P(f"   1:{rr:<4} breakeven {be:5.1%}   expectancy at 45% = {0.45*rr-0.55-0.08:+.2f}R")

N=100000
def run(risk,target,dd,p,rr=2,tpd=1,daily=250,daystop=None,regime=0.0,cost=0.08):
    bal=0.0;n=0;maxrun=0;run_=0;days=0
    while True:
        days+=1; start=bal; losses=0
        pd = p+regime if random.random()<0.5 else p-regime   # day-to-day correlated quality
        for _ in range(tpd):
            n+=1
            if random.random()<pd: bal+=rr*risk; run_=0
            else: bal-=risk; run_+=1; losses+=1; maxrun=max(maxrun,run_)
            bal-=cost*risk
            if bal<=-dd or start-bal>=daily: return 0,n,days,maxrun
            if bal>=target: return 1,n,days,maxrun
            if daystop and losses>=daystop: break
def acct(**k):
    s=t=d=0
    for _ in range(N):
        r,n,dy,_=run(**k); s+=r;t+=n;d+=dy
    return s/N,t/N,d/N
def full(risk,p=0.45,rr=2,**k):
    a,ta,da=acct(risk=risk,target=400,dd=500,p=p,rr=rr,**k)
    b,tb,db=acct(risk=risk,target=250,dd=500,p=p,rr=rr,**k)
    f,tf,df=acct(risk=risk,target=200,dd=500,p=p,rr=rr,**k)
    pp=a*b*f
    return pp, pp*160-39, ta+tb+tf, da+db+df

P("\n3) Equal edge, different R:R (same +0.27R expectancy after costs), 1 trade/day, risk 0.5%")
for rr,wr in ((1.5,0.54),(2,0.45),(3,0.3375)):
    pp,ev,t,d=full(25,p=wr,rr=rr)
    P(f"   1:{rr:<4} WR {wr:.1%}: P(first payout)={pp:.2f}  EV=${ev:+.0f}  trades~{t:.0f}")

P("\n4) The5ers HS 5K, 45% WR, 1:2 -- trades per day x risk x day-quality correlation")
P("   (regime=0.15 means a day's win rate is 30% or 60%; avg still 45%)")
P(f"   {'risk':6s}{'tpd':>4s}{'regime':>7s}{'daystop':>8s} {'P(payout)':>9s} {'EV':>6s} {'trades':>7s} {'days':>6s}")
for risk in (25,50):
    for tpd in (1,3,5):
        for regime in (0.0,0.15):
            for ds in (None,2):
                if tpd==1 and ds: continue
                pp,ev,t,d=full(risk,tpd=tpd,regime=regime,daystop=ds)
                P(f"   {('0.5%' if risk==25 else '1%'):6s}{tpd:>4d}{regime:>7.2f}{str(ds):>8s} {pp:9.2f} {ev:+6.0f} {t:7.0f} {d:6.0f}")
open('results_streak.txt','w').write("\n".join(out)+"\n")
