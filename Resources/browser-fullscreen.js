(() => {
    // This message may request cinema but never chooses a URL or supplies a crop rectangle.
    const request = (exit = false) => {
        document.dispatchEvent(new Event(exit ? 'vxr-cinema-exit' : 'vxr-cinema-request'));
        if (!exit) {
            window.webkit.messageHandlers.vxrCinema.postMessage(null);
        }
    };
    const patch = (object,key,wrapper) => {
        if (typeof object[key] !== 'function') {
            return;
        }
        try {
            Object.defineProperty(object,key,{configurable:true,writable:true,value:wrapper(object[key])});
        } catch {}
    };
    patch(Element.prototype,'requestFullscreen',() => function() {
        request();
        return Promise.resolve();
    });
    for (const key of ['webkitRequestFullscreen','webkitRequestFullScreen']) {
        patch(Element.prototype,key,() => function() {
            request();
        });
    }
    for (const key of ['webkitEnterFullscreen','webkitEnterFullScreen']) {
        patch(HTMLVideoElement.prototype,key,() => function() {
            request();
        });
    }
    patch(HTMLVideoElement.prototype,'webkitSetPresentationMode',original => function(mode) {
        if (mode === 'fullscreen') {
            request();
            return;
        }
        if (mode !== 'picture-in-picture') {
            return original.call(this,mode);
        }
    });
    for (const key of ['exitFullscreen','webkitExitFullscreen','webkitCancelFullScreen']) {
        patch(Document.prototype,key,original => function() {
            if (this.fullscreenElement || this.webkitFullscreenElement) {
                return original.call(this);
            }
            request(true);
            return Promise.resolve();
        });
    }
    for (const key of ['webkitExitFullscreen','webkitExitFullScreen']) {
        patch(HTMLVideoElement.prototype,key,original => function() {
            if (this.webkitDisplayingFullscreen) {
                return original.call(this);
            }
            request(true);
        });
    }
    document.addEventListener('loadedmetadata',e=>{
        if(e.target instanceof HTMLVideoElement) {
            e.target.playsInline = true;
        }
    },true);
})();
