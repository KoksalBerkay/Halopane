// Records input and media events for the input diagnostics report:
// which events reached the page and whether WebKit marked them as trusted.
(() => {
    if (window.__vxrObserved) {
        return;
    }
    window.__vxrObserved = true;
    const evidence = {counts: {}, recent: []};
    window.__vxrInputEvidence = evidence;
    const emit = (kind, e, extra = {}) => {
        let target = e?.target;
        let record = {
            kind,
            trusted: e?.isTrusted,
            active: navigator.userActivation?.isActive,
            tag: target?.tagName,
            inputType: e?.inputType,
            editable: !!(target?.matches?.('input,textarea,[contenteditable=true]')),
            ...extra
        };
        for (const key of Object.keys(record)) {
            if (record[key] === undefined) {
                delete record[key];
            }
        }
        evidence.counts[kind] = (evidence.counts[kind] || 0) + 1;
        evidence.recent.push(record);
        evidence.recent = evidence.recent.slice(-60);
        try {
            window.webkit.messageHandlers.vxrInputProbe.postMessage(record);
        } catch (_) {}
    };
    window.__vxrRecordActivation = (event, extra) => emit('activation', event, extra);
    const inputTypes = [
        'click', 'pointerdown', 'pointerup', 'touchstart', 'touchend', 'keydown', 'keyup',
        'beforeinput', 'input', 'focusin', 'focusout'
    ];
    for (let type of inputTypes) {
        document.addEventListener(type, e => emit(type, e), true);
    }
    // Record one in five touch moves to keep the log short.
    let moves = 0;
    document.addEventListener('touchmove', e => {
        if (++moves % 5 === 1) {
            emit('touchmove', e);
        }
    }, true);
    const mediaTypes = [
        'encrypted', 'webkitneedkey', 'waitingforkey', 'webkitkeyadded', 'webkitkeyerror',
        'webkitbeginfullscreen', 'webkitendfullscreen', 'fullscreenchange'
    ];
    for (let type of mediaTypes) {
        document.addEventListener(type, e => emit(type, e, {encryptedType: e.initDataType || ''}), true);
    }
})();
