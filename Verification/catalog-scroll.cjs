const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const W = 1000, H = 625;
const box = (left,top,right,bottom) => ({left,top,right,bottom,width:right-left,height:bottom-top});
const node = (rect, parentElement, range = 0) => ({
    parentElement, isConnected:true, scrollTop:0, scrollHeight:rect.height+range, clientHeight:rect.height,
    getBoundingClientRect:()=>rect, getClientRects:()=>[rect], getRootNode:()=>({}), getAttribute:()=>null,
    closest:()=>null, scrollTo({top}) {
        this.scrollTop = Math.min(range,Math.max(0,top));
    },
    style:{overflowY:range > 0 ? 'auto' : 'hidden'}
});
const root = node(box(0,0,W,H),null,100);
const header = node(box(0,0,W,150),root);
let catalog = node(box(0,150,W,H),root,1000);
let topHit = header;
const sidebar = node(box(850,150,W,H),catalog,400);
const dialog = node(box(50,50,450,450),root);
let modal = false;
const document = {
    scrollingElement:root,
    elementFromPoint:(x,y)=>y<150 ? topHit : x>850 ? sidebar : catalog,
    querySelectorAll:selector=>selector.includes('aria-modal') ? (modal ? [dialog] : []) : [catalog],
};
const location = {origin:'https://play.geforcenow.com'};
const script = fs.readFileSync(process.argv[2] ?? path.join(__dirname,'../Resources/trackpad-scroll.js'),'utf8');
const ctx = vm.createContext({document,location,innerWidth:W,innerHeight:H,getComputedStyle:el=>el.style});
vm.runInContext(script,ctx);

ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(65);
assert.deepEqual([root.scrollTop,catalog.scrollTop],[0,65], 'header gesture must not jump the root');
ctx.vxrScrollBy(40);
ctx.vxrScrollBy(-30);
assert.deepEqual([root.scrollTop,catalog.scrollTop],[0,75], 'same gesture keeps its scroller on reversing direction');
ctx.vxrScrollBy(-100);
assert.deepEqual([root.scrollTop,catalog.scrollTop],[0,0], 'extra delta at the boundary must not move another scroller');

// A short drag over the hero must move only the catalog and only by its own delta.
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(8);
assert.deepEqual([root.scrollTop,catalog.scrollTop],[0,8]);
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(-8);
assert.deepEqual([root.scrollTop,catalog.scrollTop],[0,0]);

ctx.vxrScrollStart(.9,.6,true);
ctx.vxrScrollBy(450);
assert.deepEqual([sidebar.scrollTop,catalog.scrollTop],[400,0], 'nested region owns its entire gesture');
ctx.vxrScrollStart(.5,.1,true);
modal = true;
ctx.vxrScrollBy(50);
assert.equal(catalog.scrollTop,0,'must not scroll the catalog through a dialog');
modal = false;

// A catalog rerender can leave a sticky, non-scrolling wrapper under
// the same pointer. A new swipe in either direction must still work.
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(100);
assert.equal(catalog.scrollTop,100);
const wrapper = node(box(0,0,W,150),root,24);
wrapper.scrollTo = () => {};
topHit = wrapper;
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(-40);
assert.equal(catalog.scrollTop,60,'subsequent upward swipe cannot get stuck on the sticky wrapper');
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(40);
assert.equal(catalog.scrollTop,100,'subsequent downward swipe cannot get stuck either');

// If the catalog node is replaced after accepting a delta, recover to the
// new node without scrolling the root or replaying what already moved.
topHit = header;
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(40);
const old = catalog;
old.isConnected = false;
catalog = node(box(0,150,W,H),root,1000);
catalog.scrollTop = old.scrollTop;
ctx.vxrScrollBy(35);
assert.deepEqual([old.scrollTop,catalog.scrollTop,root.scrollTop],[140,175,0]);

// A large container may still be the wrong one if it refuses all offsets
// despite advertising scroll range. Retry on the visible catalog once.
const inert = node(box(0,0,W,300),root,1000);
inert.scrollTo = () => {};
topHit = inert;
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(-75);
assert.equal(catalog.scrollTop,100);
assert.equal(root.scrollTop,0);
topHit = header;
catalog.scrollTop = 0;

location.origin='https://play.geforcenow.com.example';
ctx.vxrScrollStart(.5,.1,true);
ctx.vxrScrollBy(25);
assert.deepEqual([root.scrollTop,catalog.scrollTop],[25,0]);
console.log('GeForce NOW fixture: header target, repeat swipes, stale targets, edges, nested scroll, dialog and origin passed.');
