// Evaluated on demand in the trackpad's isolated world. DOM listeners still see
// the events, but they cannot grant user activation or invoke a native menu.
let view = window;
let x = fractionX * view.innerWidth;
let y = fractionY * view.innerHeight;
let target;
while (true) {
    target = view.document.elementFromPoint(x, y);
    if (!target) {
        return 'no element';
    }
    if (!target.matches('iframe,frame')) {
        break;
    }

    const child = target.contentWindow;
    if (!child || !target.contentDocument) {
        return 'cross-origin frame';
    }
    const rect = target.getBoundingClientRect();
    const scaleX = rect.width / target.offsetWidth || 1;
    const scaleY = rect.height / target.offsetHeight || 1;
    x = (x - rect.left) / scaleX - target.clientLeft;
    y = (y - rect.top) / scaleY - target.clientTop;
    view = child;
}
const init = {
    bubbles: true, cancelable: true, composed: true, view,
    button: 2, buttons: 2, clientX: x, clientY: y
};
const pointer = { ...init, pointerId: 1, pointerType: 'mouse', isPrimary: true };
target.dispatchEvent(new view.PointerEvent('pointerdown', pointer));
target.dispatchEvent(new view.MouseEvent('mousedown', init));
const handled = !target.dispatchEvent(new view.MouseEvent('contextmenu', init));
target.dispatchEvent(new view.PointerEvent('pointerup', { ...pointer, buttons: 0 }));
target.dispatchEvent(new view.MouseEvent('mouseup', { ...init, buttons: 0 }));
return handled ? 'page handled context menu' : 'events sent (untrusted)';
