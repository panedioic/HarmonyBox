(function () {
    const term = new Terminal({
        cursorBlink: true,
        fontFamily: 'monospace',
        fontSize: 13,
        theme: {
            background: '#0E0E0E',
            foreground: '#E0E0E0',
            cursor: '#5DD46E'
        },
        scrollback: 5000,
        convertEol: true
    });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    term.open(document.getElementById('terminal'));
    fit.fit();
    window.addEventListener('resize', () => fit.fit());

    // 暴露给 ArkTS 写入用
    window.termWrite = (s) => term.write(s);
    window.termWriteln = (s) => term.writeln(s);
    window.termClear = () => term.clear();

    // 用户输入 -> 暂存, 等 bridge 接通后转发
    let pending = '';
    term.onData((data) => {
        if (window.hbridge && window.hbridge.input) {
            window.hbridge.input(data);
        } else {
            pending += data;
        }
    });
    window.flushPendingInput = () => {
        if (pending && window.hbridge && window.hbridge.input) {
            window.hbridge.input(pending);
            pending = '';
        }
    };

    // 初始 banner (临时, 后面交给 C++ 出)
    // term.writeln('\x1b[1;32mxterm loaded\x1b[0m');
    // term.write('hbsh$ ');
})();