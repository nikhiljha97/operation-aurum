// Mock of TradingView's Paper Trading order dialog, built from the user's probe output.
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ args: ['--remote-debugging-port=9334'] });
  const p = await b.newPage();
  await p.goto('about:blank');
  await p.setContent(`<title>TV mock</title>
  <button aria-label="Collapse account manager">Paper Trading</button><div data-name="Paper.orders-table"></div><div data-name="Paper.positions-table"></div>
  <div role="tab" id="ot">Orders 9</div>
  <div data-name="order-dialog-popup" style="width:300px">
    <div role="button" data-name="side-control-sell">Sell 4,126.857</div><div role="button" data-name="side-control-buy">Buy 4,127.082</div>
    <div role="tab">Market</div><div role="tab" aria-selected="true">Limit</div><div role="tab">Stop</div>
    <div>Bid + 1509 <input id="px" class="input-H0xdCnFS priceInput-xBCAz8DE" value="4128.366"></div>
    <div><button id="mg">USD margin</button><button id="un">0 units</button><input id="q" aria-label="USD margin" value="412.84"></div>
    <label>Take profit price <input type="checkbox" id="tpc"></label><div>75 ticks <input id="tp" value="4128.291"></div>
    <label>Stop loss price <input type="checkbox" id="slc"></label><div>25 ticks <input id="sl" value="4128.391"></div>
    <button data-name="place-and-modify-button" id="pl">Buy 0 GOLD @ 4,128.366 LIMIT</button>
  </div>
  <script>
    var side="Buy"; var $=function(i){return document.getElementById(i)};
    function upd(){ var q = $('q').getAttribute('aria-label')==='units' ? $('q').value : '0';
      $('pl').innerText = side+' '+q+' GOLD @ '+Number($('px').value).toLocaleString('en-US',{minimumFractionDigits:3})+' LIMIT'; }
    document.querySelector('[data-name=side-control-sell]').onclick=function(){side='Sell';upd()};
    document.querySelector('[data-name=side-control-buy]').onclick=function(){side='Buy';upd()};
    $('un').onclick=function(){ $('q').setAttribute('aria-label','units'); $('q').value='0'; $('un').innerText='units'; upd(); };
    ['px','q','tp','sl'].forEach(function(i){ $(i).addEventListener('input',upd); $(i).addEventListener('blur',upd); });
    $('pl').onclick=function(){ var n=+$('ot').innerText.match(/\\d+/)[0]; $('ot').innerText='Orders '+(n+1); window.PLACED=(window.PLACED||[]).concat($('pl').innerText+' TP '+$('tp').value+' SL '+$('sl').value); };
  </script>`);
  // keep the URL pattern the bot looks for
  await p.evaluate(() => history.replaceState(null, '', '#'));
  await new Promise(r => setTimeout(r, 170000)); await b.close();
})();
