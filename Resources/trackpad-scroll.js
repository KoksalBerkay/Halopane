(() => {
    let target = null, catalog = null;
    function at(doc, x, y) {
        let element = doc.elementFromPoint(x, y);
        while (element?.shadowRoot) {
            const inside = element.shadowRoot.elementFromPoint(x, y);
            if (!inside || inside === element) {
                break;
            }
            element = inside;
        }
        return element;
    }
    function parent(element) {
        return element.parentElement ?? element.getRootNode().host ?? null;
    }
    const shortsRoute = () => ['www.youtube.com','m.youtube.com','youtube.com'].includes(location.hostname) &&
        /^\/shorts(?:\/|$)/.test(location.pathname);
    const shortsPlayers = 'ytd-reel-video-renderer, ytm-reel-video-renderer, #shorts-player, ytm-shorts-player';
    function scrollable(el) {
        return /^(auto|scroll|overlay)$/.test(getComputedStyle(el).overflowY) &&
            el.scrollHeight > el.clientHeight + 1;
    }
    function shortsFeed() {
        const feeds = '#shorts-container, #reel-video-container, ytd-shorts, ytm-shorts, ytm-reel-watch-sequence-renderer';
        return [...document.querySelectorAll(feeds)]
            .find(el => el.getClientRects().length && el.querySelector(shortsPlayers));
    }
    function visible(el) {
        if (!el.getClientRects().length) {
            return false;
        }
        const rect = el.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0 || rect.right <= 0 || rect.bottom <= 0 ||
            rect.left >= innerWidth || rect.top >= innerHeight) {
            return false;
        }
        for (let node = el; node; node = parent(node)) {
            const style = getComputedStyle(node);
            if (node.hidden || node.getAttribute('aria-hidden') === 'true' ||
                style.display === 'none' || style.visibility === 'hidden' ||
                style.visibility === 'collapse' || style.opacity === '0') {
                return false;
            }
        }
        return true;
    }
    const modalOpen = () => [...document.querySelectorAll('[role="dialog"][aria-modal="true"]')].some(visible);
    globalThis.vxrShortsRoute = (x,y) => {
        if (!shortsRoute()) {
            return 'not-shorts';
        }
        if (modalOpen()) {
            return 'visible-modal';
        }
        const feed = shortsFeed();
        let el = at(document,x*innerWidth,y*innerHeight);
        while(el && el !== feed && el !== document.scrollingElement) {
            if (el.matches('[role="dialog"], ytd-engagement-panel-section-list-renderer, ytm-engagement-panel')) {
                return 'comments-or-dialog';
            }
            if (scrollable(el) && !el.querySelector(shortsPlayers) && !el.matches(shortsPlayers)) {
                return 'inner-scroller';
            }
            el = parent(el);
        }
        return 'reel';
    };

    // Keep identifiers inside the isolated world. Native diagnostics receive only
    // whether a comparable active item changed, never video IDs or page content.
    function currentShort() {
        const feed = shortsFeed();
        const active = feed?.querySelector(
            'ytd-reel-video-renderer[is-active],ytm-reel-video-renderer[is-active],' +
            'ytd-reel-video-renderer[aria-current="true"],ytm-reel-video-renderer[aria-current="true"]');
        const video = active?.querySelector('video') ?? [...(feed ?? document).querySelectorAll('video')]
            .find(video => !video.paused && video.getClientRects().length);
        return {path:location.pathname, id:active?.getAttribute('video-id') || '', source:video?.currentSrc || ''};
    }
    let baseline;
    globalThis.vxrMarkShort = () => {
        baseline = currentShort();
    };
    globalThis.vxrShortChanged = () => {
        if (!baseline || !shortsRoute()) {
            return 'unavailable';
        }
        const now = currentShort();
        if (baseline.path !== now.path || (baseline.id && now.id && baseline.id !== now.id)) {
            return 'changed';
        }
        if (baseline.id && now.id) {
            return 'unchanged';
        }
        if (baseline.source && now.source) {
            return baseline.source === now.source ? 'unchanged' : 'video-source-changed';
        }
        return 'unavailable';
    };
    globalThis.vxrStepShort = direction => {
        if (!shortsRoute() || ![1,-1].includes(direction)) {
            return 'not-shorts';
        }
        if (modalOpen()) {
            return 'visible-modal';
        }
        const selector = direction > 0 ? '#navigation-button-down' : '#navigation-button-up';
        const region = document.querySelector(selector);
        const buttonSelector = 'button,[role="button"]';
        const button = region?.matches(buttonSelector) ? region : region?.querySelector(buttonSelector);
        if (button && visible(button) && !button.disabled && button.getAttribute('aria-disabled') !== 'true') {
            button.click();
            return 'arrow';
        }
        const feed = shortsFeed();
        if (!feed) {
            return 'no-control';
        }
        const items = [...feed.querySelectorAll('ytd-reel-video-renderer,ytm-reel-video-renderer')];
        const active = items.find(item =>
            item.hasAttribute('is-active') || item.getAttribute('aria-current') === 'true');
        const adjacent = active && items[items.indexOf(active) + direction];
        if (!adjacent) {
            return 'no-control';
        }
        // Scope scrolling to the feed's own container; do not scroll the whole document.
        let scroller = adjacent.parentElement;
        while (scroller && scroller !== document.scrollingElement && !scrollable(scroller)) {
            scroller = scroller.parentElement;
        }
        if (!scroller || scroller === document.scrollingElement || !scroller.contains(active)) {
            return 'no-control';
        }
        const shift = adjacent.getBoundingClientRect().top - active.getBoundingClientRect().top;
        if (!Number.isFinite(shift) || Math.abs(shift) < 10) {
            return 'no-control';
        }
        scroller.scrollBy({top:shift,behavior:'smooth'});
        return 'adjacent-item';
    };
    function visibleCatalogScroller(excluded) {
        const candidates = new Set();
        // A fixed header/hero can sit outside the actual catalog scroller.
        // Sample the visible web page below that overlay, not the whole DOM.
        for (const y of [0.42,0.60,0.78,0.94]) {
            for (const x of [0.20,0.50,0.80]) {
                for (let el = at(document,x*innerWidth,y*innerHeight); el; el = parent(el)) {
                    if (el !== document.scrollingElement && scrollable(el)) {
                        candidates.add(el);
                    }
                }
            }
        }
        for (const main of document.querySelectorAll('main,[role="main"]')) {
            if (main !== document.scrollingElement && scrollable(main)) {
                candidates.add(main);
            }
        }
        const ranked = [...candidates].flatMap(el => {
            const rect = el.getBoundingClientRect();
            const width = Math.max(0,Math.min(innerWidth,rect.right)-Math.max(0,rect.left));
            const height = Math.max(0,Math.min(innerHeight,rect.bottom)-Math.max(0,rect.top));
            if (el === excluded || width < innerWidth*0.5 || height < innerHeight*0.3 || !visible(el)) {
                return [];
            }
            return [{el,area:width*height}];
        });
        return ranked.sort((a,b)=>b.area-a.area)[0]?.el ?? null;
    }

    const dialogSelector = '[role="dialog"],dialog[open]';
    function pickCatalogScroller(gesture) {
        const root = document.scrollingElement;
        const hit = at(document,gesture.x*innerWidth,gesture.y*innerHeight);
        if (gesture.dialog && hit?.closest(dialogSelector) !== gesture.dialog) {
            return null;
        }
        for (let el = hit; el && el !== root; el = parent(el)) {
            // The sticky header can advertise a small amount of vertical
            // overflow after collapsing, even when it is really a horizontal rail.
            const thinHeader = !gesture.dialog && gesture.y < 0.3 &&
                el.getBoundingClientRect().height < innerHeight*0.3;
            if (!thinHeader && scrollable(el)) {
                return el;
            }
            if (el === gesture.dialog) {
                return null;
            }
        }
        return gesture.dialog ? null : visibleCatalogScroller() ?? root;
    }

    // GeForce NOW's catalogue scroller uses `scroll-snap-type: y mandatory`,
    // which pulls the page back after each trackpad swipe. Turn snapping off
    // on the scrollers under the cursor so the page stays where the swipe ends.
    globalThis.vxrUnsnapCatalog = (fractionX, fractionY) => {
        if (location.origin !== 'https://play.geforcenow.com') {
            return 0;
        }
        let changed = 0;
        for (let el = at(document, fractionX * innerWidth, fractionY * innerHeight); el; el = parent(el)) {
            if (!(el instanceof Element)) {
                continue;
            }
            const snap = getComputedStyle(el).scrollSnapType;
            if (snap && snap !== 'none') {
                el.style.setProperty('scroll-snap-type', 'none', 'important');
                changed++;
            }
        }
        return changed;
    };

    globalThis.vxrScrollStart = (fractionX, fractionY, useCatalog = false) => {
        target = at(document, fractionX * innerWidth, fractionY * innerHeight) ?? document.scrollingElement;
        catalog = useCatalog && location.origin === 'https://play.geforcenow.com'
            ? {x:fractionX,y:fractionY,dialog:target?.closest(dialogSelector),scroller:null,
               moved:false,retried:false,state:'ready'}
            : null;
    };
    globalThis.vxrCatalogScrollState = () => catalog?.state ?? 'unavailable';
    function move(el,delta) {
        const before = el.scrollTop;
        el.scrollTo({top: before + delta, behavior: 'instant'});
        return el.scrollTop - before;
    }
    function scrollCatalog(gesture,delta) {
        if (gesture.dialog ? !visible(gesture.dialog) : modalOpen()) {
            gesture.state = 'dialog';
            return false;
        }
        // Reacquire only if the old node disappeared. A valid scroller at
        // its boundary still owns the swipe, even when direction reverses.
        let el = gesture.scroller;
        if (!el?.isConnected) {
            el = gesture.scroller = pickCatalogScroller(gesture);
            gesture.moved = false;
            gesture.retried = false;
        }
        if (!el?.isConnected) {
            gesture.state = 'no target';
            return false;
        }
        const before = el.scrollTop;
        if (move(el,delta)) {
            gesture.state = 'moved';
            gesture.moved = true;
            return true;
        }
        const range = el.scrollHeight - el.clientHeight;
        const atEdge = range > 1 && (delta < 0 ? before <= 0.5 : before >= range - 0.5);
        const headerOnly = atEdge && gesture.y < 0.3 && el.getBoundingClientRect().bottom < innerHeight*0.55;
        if (!gesture.dialog && !gesture.retried &&
            (range <= 1 || (!gesture.moved && (!atEdge || headerOnly) && Math.abs(delta) >= 1))) {
            gesture.retried = true;
            const fallback = visibleCatalogScroller(el);
            if (fallback && move(fallback,delta)) {
                gesture.scroller = fallback;
                gesture.moved = true;
                gesture.state = 'retargeted';
                return true;
            }
        }
        gesture.state = atEdge ? 'edge' : 'no movement';
        return false;
    }
    globalThis.vxrScrollBy = delta => {
        if (catalog) {
            return scrollCatalog(catalog,delta);
        }
        if (!target?.isConnected) {
            target = document.scrollingElement;
        }
        let consumed = false;
        for (let el = target; el; el = parent(el)) {
            const style = getComputedStyle(el);
            const root = el === document.scrollingElement;
            if (root || scrollable(el)) {
                const moved = move(el,delta);
                consumed ||= moved !== 0;
                if (Math.abs(moved) >= Math.abs(delta) - 0.5 ||
                    (!root && /^(contain|none)$/.test(style.overscrollBehaviorY))) {
                    return consumed;
                }
                delta -= moved;
                if (root) {
                    break;
                }
            }
        }
        return consumed;
    };
})();
