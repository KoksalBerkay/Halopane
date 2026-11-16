// iOS shows <select> options in a native UIKit menu that pointer taps from
// the phone cannot reach. Draw the options inside the page instead.
(() => {
    let host = null, current = null, opened = 0, start = null;

    const usable = select => select && !select.disabled && !select.matches(':disabled');

    // The select a touch landed on, including a tap on its label.
    function selectFrom(event) {
        for (const node of event.composedPath()) {
            if (node.nodeType !== 1) {
                continue;
            }
            if (node.tagName === 'SELECT') {
                return usable(node) ? node : null;
            }
            if (node.tagName === 'LABEL' && node.control?.tagName === 'SELECT') {
                return usable(node.control) ? node.control : null;
            }
            if (node === host) {
                return null;
            }
        }
        return null;
    }

    function close() {
        host?.remove();
        host = null;
        current = null;
    }

    function notify(select) {
        const win = select.ownerDocument.defaultView;
        select.dispatchEvent(new win.Event('input', {bubbles: true, composed: true}));
        select.dispatchEvent(new win.Event('change', {bubbles: true}));
    }

    function choose(select, option) {
        if (option.disabled || option.parentElement?.disabled) {
            return;
        }
        if (select.multiple) {
            option.selected = !option.selected;
            notify(select);
            render(select);
            return;
        }
        const changed = !option.selected;
        option.selected = true;
        if (changed) {
            notify(select);
        }
        close();
    }

    const css = `
        :host { all: initial; }
        .backdrop { position: fixed; inset: 0; z-index: 2147483647; }
        .list {
            position: fixed; box-sizing: border-box; overflow-y: auto; overscroll-behavior: contain;
            min-width: 160px; padding: 6px 0; border-radius: 10px;
            background: #fff; color: #111; border: 1px solid rgba(0,0,0,.18);
            box-shadow: 0 8px 28px rgba(0,0,0,.35);
            font: 16px -apple-system, system-ui, sans-serif;
        }
        .group { padding: 8px 14px 4px; font-size: 13px; font-weight: 600; opacity: .6; }
        .item { display: flex; gap: 8px; align-items: center; padding: 9px 14px; cursor: pointer; }
        .item.grouped { padding-left: 24px; }
        .item.on { font-weight: 600; }
        .item.off { opacity: .4; cursor: default; }
        .item:not(.off):active, .item:not(.off):hover { background: rgba(0,122,255,.14); }
        .mark { width: 14px; flex: none; color: #007aff; }
        @media (prefers-color-scheme: dark) {
            .list { background: #2c2c2e; color: #f2f2f7; border-color: rgba(255,255,255,.16); }
            .mark { color: #0a84ff; }
        }
    `;

    function item(select, option, grouped) {
        const row = document.createElement('div');
        const off = option.disabled || option.parentElement?.disabled;
        row.className = 'item' + (grouped ? ' grouped' : '') + (option.selected ? ' on' : '') + (off ? ' off' : '');
        const mark = document.createElement('span');
        mark.className = 'mark';
        mark.textContent = option.selected ? '✓' : '';
        const text = document.createElement('span');
        text.textContent = option.label || option.text;
        row.append(mark, text);
        row.addEventListener('click', event => {
            event.stopPropagation();
            choose(select, option);
        });
        return row;
    }

    function render(select) {
        const list = host?.shadowRoot.querySelector('.list');
        if (!list) {
            return;
        }
        const scroll = list.scrollTop;
        list.replaceChildren();
        for (const child of select.children) {
            if (child.tagName === 'OPTGROUP') {
                const header = document.createElement('div');
                header.className = 'group';
                header.textContent = child.label;
                list.append(header);
                for (const option of child.children) {
                    if (option.tagName === 'OPTION' && !option.hidden) {
                        list.append(item(select, option, true));
                    }
                }
            } else if (child.tagName === 'OPTION' && !child.hidden) {
                list.append(item(select, child, false));
            }
        }
        list.scrollTop = scroll;
    }

    // Opens below the select, or above it when there is more room there.
    function open(select) {
        close();
        current = select;
        opened = performance.now();
        host = document.createElement('div');
        const root = host.attachShadow({mode: 'open'});
        const style = document.createElement('style');
        style.textContent = css;
        const backdrop = document.createElement('div');
        backdrop.className = 'backdrop';
        const list = document.createElement('div');
        list.className = 'list';
        list.addEventListener('click', event => {
            event.stopPropagation();
        });
        backdrop.append(list);
        backdrop.addEventListener('click', close);
        root.append(style, backdrop);
        document.documentElement.append(host);
        render(select);

        const box = select.getBoundingClientRect();
        const below = innerHeight - box.bottom - 8, above = box.top - 8;
        const room = Math.max(below, above);
        list.style.maxHeight = Math.max(120, Math.min(room, innerHeight * 0.7)) + 'px';
        list.style.minWidth = Math.max(160, box.width) + 'px';
        list.style.left = Math.max(8, Math.min(box.left, innerWidth - list.offsetWidth - 8)) + 'px';
        if (below >= list.offsetHeight || below >= above) {
            list.style.top = Math.max(8, box.bottom + 4) + 'px';
        } else {
            list.style.top = Math.max(8, box.top - 4 - list.offsetHeight) + 'px';
        }
        list.querySelector('.item.on')?.scrollIntoView({block: 'nearest'});
    }

    // Cancelling the touch stops WebKit from focusing the select, so the
    // native menu never opens. A drag that starts on the select still scrolls.
    document.addEventListener('touchstart', event => {
        const touch = event.changedTouches[0];
        const select = event.isTrusted && event.touches.length === 1 ? selectFrom(event) : null;
        if (!select || !touch) {
            start = null;
            return;
        }
        start = {select, x: touch.clientX, y: touch.clientY};
    }, {capture: true, passive: true});

    document.addEventListener('touchend', event => {
        const touch = event.changedTouches[0];
        const tap = start;
        start = null;
        if (!tap || !touch || !event.isTrusted || selectFrom(event) !== tap.select) {
            return;
        }
        if (Math.hypot(touch.clientX - tap.x, touch.clientY - tap.y) > 10) {
            return;
        }
        event.preventDefault();
        open(tap.select);
    }, {capture: true, passive: false});

    document.addEventListener('touchcancel', () => {
        start = null;
    }, true);

    // If WebKit still focuses the select right after our picker opened, blur it
    // so the native menu closes again.
    document.addEventListener('focusin', event => {
        if (current && event.target === current && performance.now() - opened < 1000) {
            current.blur();
        }
    }, true);

    document.addEventListener('keydown', event => {
        if (host && event.key === 'Escape') {
            close();
        }
    }, true);

    // Close when the page moves under the list, but not when the list itself scrolls.
    document.addEventListener('scroll', event => {
        if (host && event.target !== host) {
            close();
        }
    }, true);
    window.addEventListener('resize', close);
    window.addEventListener('pagehide', close);
})();
