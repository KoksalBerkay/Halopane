(() => {
    const channel = window.webkit.messageHandlers.vxrMedia;
    const ids = new WeakMap();
    const frameID = globalThis.crypto?.randomUUID?.() ?? String(Math.random());
    const send = data => channel.postMessage({...data,frameID});
    const frameTag = 'vxr-media-geometry-v1';
    const unit = [0,0,1,1];
    function inside(box) {
        return Array.isArray(box) && box.length === 4
            && box.every(value => Number.isFinite(value) && Math.abs(value) < 50)
            && box[2] > 0 && box[3] > 0;
    }
    // Forward only geometry. A parent identifies the iframe by its WindowProxy, including cross-origin frames.
    window.addEventListener('message',e=>{
        const data = e.data;
        if (!data || data.tag !== frameTag || typeof data.id !== 'string' ||
            !/^[a-zA-Z0-9.-]{1,64}$/.test(data.id) || !inside(data.box)) {
            return;
        }
        const iframe = [...document.querySelectorAll('iframe,frame')].find(el=>el.contentWindow === e.source);
        if (!iframe || !innerWidth || !innerHeight) {
            return;
        }
        const bounds = iframe.getBoundingClientRect();
        if (!(bounds.width>1 && bounds.height>1 && iframe.offsetWidth && iframe.offsetHeight)) {
            return;
        }
        const sx = bounds.width/iframe.offsetWidth, sy = bounds.height/iframe.offsetHeight;
        const x = (bounds.x + iframe.clientLeft*sx)/innerWidth, y = (bounds.y + iframe.clientTop*sy)/innerHeight;
        const w = iframe.clientWidth*sx/innerWidth, h = iframe.clientHeight*sy/innerHeight;
        const childBox = data.box;
        const box = [x+childBox[0]*w,y+childBox[1]*h,childBox[2]*w,childBox[3]*h];
        if (!inside(box)) {
            return;
        }
        if (window === window.top) {
            send({kind:'frameGeometry',child:data.id,box});
        } else {
            window.parent.postMessage({tag:frameTag,id:data.id,box},'*');
        }
    });
    function announceFrame() {
        if (window !== window.top) {
            window.parent.postMessage({tag:frameTag,id:frameID,box:unit},'*');
        }
    }
    const pauseIntent = new WeakMap();
    let next = 0, selected, before = '', last = 0;
    const rect = video => {
        const bounds = video.getBoundingClientRect();
        return [
            bounds.x / innerWidth, bounds.y / innerHeight, bounds.width / innerWidth, bounds.height / innerHeight
        ];
    };
    function report() {
        selected = [...document.querySelectorAll('video')].filter(video => {
            const [x,y,w,h] = rect(video);
            return w > .03 && h > .03 && x < 1 && y < 1 && x+w > 0 && y+h > 0;
        }).sort((a,b) => {
            const ar = a.getBoundingClientRect(), br = b.getBoundingClientRect();
            return Number(!b.paused)-Number(!a.paused) || br.width*br.height-ar.width*ar.height;
        })[0];
        if (!selected) {
            if (before) {
                send({kind:'empty'});
            }
            before = '';
            return;
        }
        const video = selected;
        announceFrame();
        if (!ids.has(video)) {
            ids.set(video,++next);
        }
        const ranges = video.seekable;
        const hasDuration = Number.isFinite(video.duration);
        const info = {
            kind: 'video',
            id: ids.get(video),
            box: rect(video),
            time: video.currentTime || 0,
            duration: hasDuration ? video.duration : 0,
            paused: video.paused,
            muted: video.muted,
            ready: video.readyState,
            seekable: ranges.length && hasDuration ? [ranges.start(0), ranges.end(ranges.length - 1)] : [],
            aspect: video.videoHeight ? video.videoWidth / video.videoHeight : 0,
            visible: document.visibilityState
        };
        const key = JSON.stringify(info);
        if (key !== before || performance.now()-last > 1000) {
            send(info);
            last=performance.now();
        }
        before = key;
    }
    globalThis.vxrMediaCommand = async (id,op,value) => {
        const video = selected;
        if (!video?.isConnected || ids.get(video) !== id) {
            return false;
        }
        if (op === 'toggle') {
            if (video.paused) {
                await video.play();
            } else {
                pauseIntent.set(video,performance.now());
                video.pause();
            }
        } else if (op === 'mute') {
            video.muted = !video.muted;
        } else if (op === 'unmute') {
            video.muted = false;
        } else if (op === 'muteAndPlay') {
            video.muted = true;
            if (video.paused) {
                await video.play();
            }
        } else if (op === 'seek') {
            if (!Number.isFinite(video.duration) || !video.seekable.length || !Number.isFinite(value)) {
                return false;
            }
            let destination, distance = Infinity;
            for(let i=0;i<video.seekable.length;i++) {
                const time = Math.max(video.seekable.start(i),Math.min(video.seekable.end(i),value));
                if(Math.abs(value-time)<distance) {
                    destination=time;
                    distance=Math.abs(value-time);
                }
            }
            video.currentTime = destination;
            await new Promise(resolve => {
                const done = () => {
                    clearTimeout(timer);
                    video.removeEventListener('seeked',done);
                    resolve();
                };
                const timer = setTimeout(done,900);
                video.addEventListener('seeked',done,{once:true});
            });
            if(video.error || Math.abs(video.currentTime-destination)>2) {
                return false;
            }
        } else {
            return false;
        }
        report();
        return true;
    };
    // A small copy of the current frame for 2D-to-3D depth. Protected video and
    // cross-origin video without CORS cannot be read; the app falls back or explains.
    let frameCanvas;
    globalThis.vxrMediaFrame = (id,width) => {
        const video = selected;
        if (!video?.isConnected || ids.get(video) !== id) {
            return {error: 'gone'};
        }
        if (video.mediaKeys || video.webkitKeys) {
            return {error: 'protected'};
        }
        if (video.readyState < 2 || !video.videoWidth || !video.videoHeight) {
            return {error: 'notReady'};
        }
        const height = Math.max(1, Math.round(width * video.videoHeight / video.videoWidth));
        frameCanvas = frameCanvas || document.createElement('canvas');
        frameCanvas.width = width;
        frameCanvas.height = height;
        try {
            frameCanvas.getContext('2d').drawImage(video,0,0,width,height);
            return {image: frameCanvas.toDataURL('image/jpeg',0.85)};
        } catch (error) {
            return {error: error?.name === 'SecurityError' ? 'crossOrigin' : 'failed'};
        }
    };
    document.addEventListener('vxr-cinema-request',()=>{
        report();
        if (selected) {
            send({kind:'cinemaRequest',id:ids.get(selected)});
        }
    });
    document.addEventListener('vxr-cinema-exit',()=>send({kind:'cinemaExit'}));
    globalThis.vxrPanelMute = () => {
        for (const video of document.querySelectorAll('video')) {
            video.muted = true;
        }
        report();
        return true;
    };
    for (const event of ['play','playing','pause','waiting','volumechange','visibilitychange']) {
        document.addEventListener(event,e => {
            const video = event === 'visibilitychange' ? selected : e.target;
            if (!(video instanceof HTMLVideoElement)) {
                return;
            }
            report();
            if (!ids.has(video)) {
                ids.set(video,++next);
            }
            send({kind:'playback',id:ids.get(video),event,selected:video === selected,
                  at:Date.now(),paused:video.paused,muted:video.muted || video.volume === 0,ready:video.readyState,
                  visible:document.visibilityState,
                  requested:performance.now()-(pauseIntent.get(video) ?? -Infinity)<1000});
        },true);
    }
    const presentationEvents = [
        'webkitbeginfullscreen', 'webkitendfullscreen', 'fullscreenchange', 'webkitpresentationmodechanged'
    ];
    for (const event of presentationEvents) {
        document.addEventListener(event,e=>send({kind:'presentation',event,
            element:!!document.fullscreenElement, native:!!e.target?.webkitDisplayingFullscreen,
            mode:e.target?.webkitPresentationMode||''}),true);
    }
    // DRM and error events for the playback timeline. Only names and codes, never key data.
    const keyEvents = ['encrypted', 'waitingforkey', 'webkitneedkey', 'webkitkeyerror', 'error', 'stalled', 'emptied'];
    for (const event of keyEvents) {
        document.addEventListener(event,e => {
            if (!(e.target instanceof HTMLMediaElement)) {
                return;
            }
            send({kind:'drm',event,at:Date.now(),ready:e.target.readyState,
                  initDataType:String(e.initDataType || '').slice(0,20),
                  error:e.target.error?.code ?? 0,keys:!!e.target.mediaKeys || !!e.target.webkitKeys});
        },true);
    }
    setInterval(report,350);
})();
