const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ args: ['--remote-debugging-port=9333'] });
  const p = await b.newPage();
  await p.setContent(`<title>Mock TV</title><div>Paper Trading ▾ Account Balance 100000</div>
    <div data-name="order-dialog"><button role="tab" aria-selected="true">Limit</button><label>Price <input data-name="price-input" value="4131.2"></label>
    <label>Units <input data-name="qty-input" value="1"></label><button data-name="place-order-button">Sell 1 XAUUSD @ 4131.2 LMT</button></div>`);
  await new Promise(r => setTimeout(r, 15000)); await b.close();
})();
