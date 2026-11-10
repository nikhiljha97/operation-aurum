import sys, json, urllib.request, urllib.parse
src=open(sys.argv[1],encoding='utf-8').read()
req=urllib.request.Request('https://pine-facade.tradingview.com/pine-facade/translate_light?user_name=Guest&pine_id=00000000-0000-0000-0000-000000000000',
  data=urllib.parse.urlencode({'source':src}).encode(), headers={'Accept':'application/json','Content-Type':'application/x-www-form-urlencoded','Referer':'https://www.tradingview.com/','User-Agent':'Mozilla/5.0'})
r=json.load(urllib.request.urlopen(req,timeout=60))
inner=r.get('result') or {}
errs=inner.get('errors2') or []; warns=inner.get('warnings2') or []
print('success' if r.get('success') and not errs else 'FAILED', '| errors:',len(errs),'warnings:',len(warns))
for e in errs: print('  ERR  line',e.get('start',{}).get('line'),':',e.get('message'))
for w in warns: print('  warn line',w.get('start',{}).get('line'),':',w.get('message'))
if r.get('error'): print('  error:', r['error'])
