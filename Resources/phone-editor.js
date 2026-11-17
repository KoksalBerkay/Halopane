(() => {
    const textTypes = new Set(['text','search','url','tel','email','number','password','textarea','contenteditable']);
    const editable = element => {
        if (!element || element.nodeType !== 1) {
            return null;
        }
        let node = element;
        const label = node.closest('label');
        if (!node.matches('input,textarea') && label?.control) {
            node = label.control;
        }
        if (!node.matches('input,textarea') && !node.isContentEditable) {
            const wrapper = node.closest('[role="textbox"]');
            node = wrapper?.querySelector('input,textarea,[contenteditable]:not([contenteditable="false"])') ?? node;
        }
        if (node.isContentEditable) {
            node = node.closest('[contenteditable]:not([contenteditable="false"])') ?? node;
        }
        const kind = node.tagName === 'INPUT' ? node.type : node.tagName === 'TEXTAREA' ? 'textarea' :
            node.isContentEditable ? 'contenteditable' : '';
        if (!textTypes.has(kind) || !node.isConnected || node.disabled || node.readOnly ||
            node.matches(':disabled,[aria-disabled="true"]') || /(?:^|\s)cc-/i.test(node.autocomplete || '')) {
            return null;
        }
        return node;
    };
    function hit(doc, x, y, depth = 0) {
        if (!doc || depth > 5) {
            return null;
        }
        let node = doc.elementFromPoint(x,y);
        for (let i=0;i<5 && node?.shadowRoot;i++) {
            const inner = node.shadowRoot.elementFromPoint?.(x,y);
            if (!inner || inner === node) {
                break;
            }
            node = inner;
        }
        if (node?.matches('iframe,frame')) {
            try {
                const box = node.getBoundingClientRect();
                const sx = box.width/Math.max(1,node.offsetWidth);
                const sy = box.height/Math.max(1,node.offsetHeight);
                if (sx > 0 && sy > 0) {
                    const innerX = (x - box.left) / sx - node.clientLeft;
                    const innerY = (y - box.top) / sy - node.clientTop;
                    return hit(node.contentDocument, innerX, innerY, depth + 1);
                }
            } catch {}
            return null;
        }
        for (let i=0;node && i<6;i++,node=node.parentElement) {
            const field = editable(node);
            if (field) {
                return field;
            }
        }
        return null;
    }
    function focused(doc, depth = 0) {
        if (!doc || depth > 5) {
            return null;
        }
        let node = doc.activeElement;
        while (node?.shadowRoot?.activeElement) {
            node = node.shadowRoot.activeElement;
        }
        if (node?.matches('iframe,frame')) {
            try {
                return focused(node.contentDocument,depth+1);
            } catch {
                return null;
            }
        }
        return editable(node);
    }

    let recent, selected, selectedID, originalType;
    // Trusted taps in a cross-origin frame identify that exact frame. The
    // message never includes a name, selector, or value.
    const remember = event => {
        if (!event.isTrusted) {
            return;
        }
        const field = event.composedPath().map(editable).find(Boolean);
        if (!field) {
            return;
        }
        recent = {field,at:performance.now()};
        if (window !== window.top) {
            window.webkit?.messageHandlers?.vxrEditorTap?.postMessage(true);
        }
    };
    document.addEventListener('pointerup',remember,true);
    document.addEventListener('touchend',remember,true);
    document.addEventListener('click',remember,true);

    globalThis.vxrOfferEditor = (id,currentID,point,fromTap) => {
        const fresh = recent && performance.now()-recent.at < 700 ? editable(recent.field) : null;
        let field = fromTap ? fresh : point ? hit(document,point.x*innerWidth,point.y*innerHeight) : focused(document);
        if (!field && point && fresh) {
            const box = fresh.getBoundingClientRect(), x = point.x*innerWidth, y = point.y*innerHeight;
            if (x >= box.left-8 && x <= box.right+8 && y >= box.top-8 && y <= box.bottom+8) {
                field = fresh;
            }
        }
        if (!field) {
            return null;
        }
        const type = field.isContentEditable ? 'contenteditable' : field.tagName === 'INPUT' ? field.type : 'textarea';
        const code = /(?:^|\s)one-time-code(?:\s|$)/i.test(field.autocomplete || '');
        const text = type === 'password' || code ? '' : type === 'contenteditable' ? field.innerText : field.value;
        if (typeof text !== 'string' || text.length > 8192) {
            return null;
        }
        try {
            if (field.ownerDocument.activeElement !== field) {
                field.focus({preventScroll:true});
            }
        } catch {}
        if (field === selected && selectedID === currentID) {
            return {same:true};
        }
        selected = field;
        selectedID = id;
        originalType = type;
        return {text,type:code ? 'one-time-code' : type,mode:field.inputMode || ''};
    };

    globalThis.vxrWriteEditor = (id,text) => {
        const field = selected;
        if (id !== selectedID || editable(field) !== field ||
            (field.tagName === 'INPUT' && field.type !== originalType)) {
            return false;
        }
        const doc = field.ownerDocument, win = doc.defaultView;
        if (field.isContentEditable) {
            const range = doc.createRange();
            range.selectNodeContents(field);
            const selection = win.getSelection();
            if (!selection) {
                return false;
            }
            selection.removeAllRanges();
            selection.addRange(range);
            if (doc.execCommand(text.length?'insertText':'delete',false,text)) {
                return true;
            }
            if (field.children.length) {
                return false;
            }
            field.textContent = text;
        } else {
            const prototype = field.tagName === 'TEXTAREA'
                ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype,'value').set.call(field,text);
        }
        field.dispatchEvent(new win.InputEvent('input',{bubbles:true,composed:true,inputType:'insertText'}));
        return true;
    };

    globalThis.vxrSubmitEditor = id => {
        const field = selected;
        if (id !== selectedID || editable(field) !== field || field.isContentEditable || field.tagName === 'TEXTAREA') {
            return false;
        }
        const win = field.ownerDocument.defaultView;
        let allowed = true;
        for (const type of ['keydown','keypress','keyup']) {
            if (type === 'keypress' && !allowed) {
                continue;
            }
            const accepted = field.dispatchEvent(new win.KeyboardEvent(type,{
                key:'Enter',code:'Enter',bubbles:true,cancelable:true,composed:true
            }));
            allowed = accepted && allowed;
        }
        if (allowed && field.form?.isConnected) {
            const submit = [...field.form.elements].find(item=>item.type==='submit'&&!item.disabled);
            if (submit) {
                field.form.requestSubmit(submit);
            } else {
                field.form.requestSubmit();
            }
        }
        return true;
    };
    globalThis.vxrCloseEditor = id => {
        if (id === selectedID) {
            selected = null;
            selectedID = null;
            originalType = null;
        }
    };
})();
