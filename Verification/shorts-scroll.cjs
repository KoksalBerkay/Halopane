const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const location = { hostname:'www.youtube.com', pathname:'/shorts/example' };
const root = {};
const rect = {left:10,top:10,right:100,bottom:100,width:90,height:90};
const makeButton = () => ({
    hits:0, matches:()=>true, getClientRects:()=>[rect], getBoundingClientRect:()=>rect, getAttribute:()=>null,getRootNode:()=>({}),
    click() {
        this.hits++;
    }
});
const next = makeButton();
const previous = makeButton();
const video = { matches:()=>false, getRootNode:()=>({}), scrollHeight:100, clientHeight:100 };
const comments = {...video, matches:s=>s.includes('engagement-panel')};
let hit = video;
let showButtons = true;
let modal = null;
const hiddenDialog = {...makeButton(),hidden:true};
const visibleDialog = makeButton();
const document = {
    elementFromPoint:()=>hit, scrollingElement:root,
    querySelector(selector) {
        return showButtons ? (selector.endsWith('down') ? next : previous) : null;
    },
    querySelectorAll:selector=>selector?.includes("aria-modal") && modal ? [modal] : []
};
const ctx = vm.createContext({document,location,innerWidth:1000,innerHeight:625,getComputedStyle:el=>({overflowY:el.overflowY ?? 'visible'})});
vm.runInContext(fs.readFileSync(path.join(__dirname,'../Resources/trackpad-scroll.js'),'utf8'),ctx);
assert.equal(ctx.vxrShortsRoute(.5,.5),'reel');
assert.equal(ctx.vxrStepShort(1),'arrow');
assert.equal(ctx.vxrStepShort(-1),'arrow');
assert.deepEqual([next.hits,previous.hits],[1,1]);
next.disabled = true;
assert.equal(ctx.vxrStepShort(1),'no-control');
assert.equal(next.hits,1);
hit = comments;
assert.equal(ctx.vxrShortsRoute(.5,.5),'comments-or-dialog');
hit = video;
modal = hiddenDialog;
assert.equal(ctx.vxrShortsRoute(.5,.5),'reel');
assert.equal(ctx.vxrStepShort(-1),'arrow');
modal = visibleDialog;
assert.equal(ctx.vxrShortsRoute(.5,.5),'visible-modal');
assert.equal(ctx.vxrStepShort(-1),'visible-modal');
assert.equal(previous.hits,2);
modal = {...visibleDialog,getBoundingClientRect:()=>({...rect,top:800,bottom:890})};
assert.equal(ctx.vxrShortsRoute(.5,.5),'reel');
modal = null;
ctx.vxrMarkShort();
assert.equal(ctx.vxrShortChanged(),'unavailable');
location.pathname = '/shorts/another';
assert.equal(ctx.vxrShortChanged(),'changed');
location.pathname = '/watch';
assert.equal(ctx.vxrShortsRoute(.5,.5),'not-shorts');
assert.equal(ctx.vxrStepShort(-1),'not-shorts');
location.pathname = '/shorts/example';
location.hostname = 'youtube.com.invalid';
assert.equal(ctx.vxrStepShort(-1),'not-shorts');

// Mobile layout with adjacent shorts and no arrow buttons.
showButtons = false;
location.hostname = 'm.youtube.com';
const feed = {
    overflowY:'auto', scrollHeight:1500, clientHeight:500, getClientRects:()=>[{}],
    querySelector:()=>video, querySelectorAll:()=>[active,adjacent], contains:el=>el === active,
    scrollBy(options) {
        this.shift=options.top;
    }
};
const active = { parentElement:feed, hasAttribute:()=>true,getBoundingClientRect:()=>({top:0}) };
const adjacent = { parentElement:feed, hasAttribute:()=>false,getBoundingClientRect:()=>({top:500}) };
document.querySelectorAll = selector=>selector.includes("aria-modal") ? [] : [feed];
assert.equal(ctx.vxrStepShort(1),'adjacent-item');
assert.equal(feed.shift,500);
assert.equal(ctx.vxrStepShort(-1),'no-control');
const playing = {paused:false,currentSrc:'blob:old',getClientRects:()=>[rect]};
feed.querySelector = selector=>selector === 'video' ? playing : active;
active.querySelector = ()=>playing;
active.getAttribute = ()=>null;
ctx.vxrMarkShort();
assert.equal(ctx.vxrShortChanged(),'unchanged');
playing.currentSrc = 'blob:new';
assert.equal(ctx.vxrShortChanged(),'video-source-changed');
console.log('Hidden vs visible modal, true no-advance, and active-video observation checks passed.');
console.log('Shorts routing: forward, backward, feed fallback, comments, modal and origin checks passed.');
