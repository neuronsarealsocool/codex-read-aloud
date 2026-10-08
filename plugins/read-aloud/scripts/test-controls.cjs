const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch({channel: 'chrome', headless: true});
  try {
    const page = await browser.newPage();
    await page.setContent(fs.readFileSync(path.join(__dirname, '..', 'controls.html'), 'utf8'));
    await page.evaluate(() => {
      window.sentCommands = [];
      window.openai = {sendFollowUpMessage: async args => {window.sentCommands.push(args);}};
    });
    const buttons = page.locator('button[data-action]');
    assert.equal(await buttons.count(), 18);
    for (let i = 0; i < 18; i++) {
      await buttons.nth(i).click();
      await page.waitForFunction(() => document.querySelector('[data-feedback]').textContent === 'Command sent to the chat.');
    }
    const requests = await page.evaluate(() => window.sentCommands);
    assert.equal(requests.length, 18);
    assert(requests[1].prompt.includes('stop current and queued speech'));
    assert(requests[6].prompt.includes('increase reading speed'));
    assert(requests[7].prompt.includes('Microsoft Zira Desktop'));
    assert(requests[11].prompt.includes('enable spoken narration'));
    assert(requests[12].prompt.includes('disable spoken progress'));
    assert(requests[13].prompt.includes('af_heart'));
    assert(requests[14].prompt.includes('bf_emma'));
    assert(requests[15].prompt.includes('Microsoft George'));
    assert(requests[16].prompt.includes('Microsoft Hazel Desktop'));
    assert(requests[17].prompt.includes('Microsoft Susan'));
    assert(requests.every(item => typeof item.prompt === 'string' && item.prompt.length > 0));
    await page.evaluate(() => {delete window.openai;});
    await page.locator('[data-action="stop"]').click();
    assert((await page.locator('[data-feedback]').textContent()).includes('cannot send commands'));
    await page.evaluate(() => {window.openai = {sendFollowUpMessage: async () => {throw new Error('cancelled');}};});
    await page.locator('[data-action="stop"]').click();
    await page.waitForFunction(() => document.querySelector('[data-feedback]').textContent.includes('Command was not sent'));
    assert.equal(await page.locator('button:disabled').count(), 0);
    console.log('PASS: all 18 buttons submit their commands; missing host bridge and cancelled commands report errors and keep controls usable.');
  } finally {await browser.close();}
})().catch(error => {console.error(error); process.exitCode = 1;});
