// Fallback for a physical controller paired to iOS. The enclosing profile
// supplies the current page's allowlist; this does not run on other sites.
(() => {
    const nativeGetGamepads = typeof navigator.getGamepads === 'function'
        ? navigator.getGamepads.bind(navigator) : () => [];
    const connectedPads = pads => Array.from(pads).filter(pad => pad && pad.connected);
    function matchesInput(pad, buttons, axes) {
        return buttons.every((value, index) =>
            value <= 0.12 || Math.abs((pad.buttons[index]?.value ?? 0) - value) <= 0.18) &&
            axes.every((value, index) =>
                Math.abs(value) <= 0.22 || Math.abs((pad.axes[index] ?? 0) - value) <= 0.18);
    }
    let fallback = null;
    let watchdog = 0;
    let lastUpdate = 0;
    const normal = (value, min, max) => Math.min(max, Math.max(min, Number.isFinite(value) ? value : 0));

    function dispatch(type, pad) {
        // GamepadEvent's native constructor requires a browser-owned Gamepad.
        const event = new Event(type);
        Object.defineProperty(event, 'gamepad', { value: pad });
        window.dispatchEvent(event);
    }

    function disconnect() {
        if (!fallback) {
            return;
        }
        window.clearInterval(watchdog);
        watchdog = 0;
        const pad = fallback;
        fallback = null;
        pad.connected = false;
        pad.axes.fill(0);
        pad.buttons.forEach(button => Object.assign(button, { value: 0, pressed: false, touched: false }));
        pad.timestamp = performance.now();
        dispatch('gamepaddisconnected', pad);
    }

    Object.defineProperty(navigator, 'getGamepads', {
        configurable: true, writable: true,
        value() {
            const native = nativeGetGamepads();
            if (!inScope() || !fallback || performance.now() - lastUpdate > 1250) {
                return native;
            }
            return [fallback, null, null, null];
        }
    });

    Object.defineProperty(window, '__vxrCloudControllerUpdate', {
        value(buttons, axes) {
            if (!inScope() || !Array.isArray(buttons) || buttons.length !== 17 ||
                !Array.isArray(axes) || axes.length !== 4) {
                disconnect();
                return 'released';
            }
            let native;
            try {
                native = connectedPads(nativeGetGamepads());
            }
            catch (_) {
                disconnect();
                return 'WebKit denied gamepad access';
            }

            const fresh = !fallback;
            const hasInput = buttons.some(value => value > 0.12) || axes.some(value => Math.abs(value) > 0.22);
            // A reported WebKit pad may not receive input in the external scene.
            // Keep native delivery when it reflects real input. Once the bridge
            // takes over, publish one pad consistently until it disconnects.
            if (fresh && native.some(pad => matchesInput(pad, buttons, axes))) {
                return 'WebKit';
            }
            // Expose the controller only after a real input gesture.
            if (fresh && !hasInput) {
                return 'press a controller button';
            }
            if (fresh) {
                fallback = {
                    id: 'Xbox Wireless Controller (VITURE Spatial)', index: 0, connected: true,
                    mapping: 'standard', timestamp: 0, axes: [0, 0, 0, 0],
                    buttons: Array.from({ length: 17 }, () => ({ value: 0, pressed: false, touched: false })),
                    vibrationActuator: null, hapticActuators: []
                };
            }
            lastUpdate = performance.now();
            axes.forEach((value, index) => {
                fallback.axes[index] = normal(value, -1, 1);
            });
            buttons.forEach((value, index) => {
                const pressure = normal(value, 0, 1);
                Object.assign(fallback.buttons[index], {
                    value: pressure, pressed: pressure >= 0.5, touched: pressure > 0
                });
            });
            fallback.timestamp = lastUpdate;
            if (fresh) {
                watchdog = window.setInterval(() => {
                    if (!inScope() || performance.now() - lastUpdate > 1250) {
                        disconnect();
                    }
                }, 350);
                dispatch('gamepadconnected', fallback);
            }
            return 'Spatial bridge';
        }
    });
    window.addEventListener('pagehide', disconnect);
})();
