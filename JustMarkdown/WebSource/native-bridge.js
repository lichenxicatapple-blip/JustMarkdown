    let nativeToken = '';
    let nativeDocumentName = ''; 
    let sourceTimer = 0;
    let nativeSymbols = {};
    function postNative(message) { window.webkit?.messageHandlers.reader.postMessage(message); }
    function prepareLocalResources(fragment, documentContent = false) {
      const images = [...fragment.querySelectorAll('img')];
      if (documentContent) {
        postNative({ type: 'localResources', token: nativeToken, paths: images.map(image => image.getAttribute('data-source-path') || image.getAttribute('src') || '') });
      }
      images.forEach(image => {
        const resourceToken = nativeToken;
        const path = image.getAttribute('data-source-path') || image.getAttribute('src') || '';
        if (!path || /^(https?:|data:|blob:)/i.test(path)) return;
        image.setAttribute('data-source-path', path);
        image.src = `jm-resource://${nativeToken}/image?path=${encodeURIComponent(path)}`;
        image.addEventListener('error', () => {
          if (resourceToken !== nativeToken) return;
          image.classList.add('jm-local-image-error');
        });
      });
    }
    function flushSource() {
      clearTimeout(sourceTimer);
      postNative({type:'source', text:sourceEditor.value, token:nativeToken});
      return sourceEditor.value;
    }
    sourceEditor.addEventListener('input', () => { clearTimeout(sourceTimer); sourceTimer = setTimeout(flushSource, 150); });
    sourceEditor.addEventListener('keyup', event => { if (event.key === 'Tab') flushSource(); });
    app.addEventListener('mdv-source-history', event => {
      postNative({ type: 'sourceHistory', ...event.detail, token: nativeToken });
    });
    function askNative(text) {
      readSelection();
      const selected = selectionAttachment || (text ? { text, markdown: text, mode: displayedMode } : null);
      const value = selected ? { ...selected, documentName: nativeDocumentName } : null;
      if (!value?.text.trim()) return;
      pinnedAnchor = captureReadingPosition();
      agentExperience.attach(value, value.rect || { left: 16, bottom: 80 });
    }
    app.addEventListener('click', event => {
      const link = event.target.closest(':is(.mdv-article,.mdv-rich-text) a[href]:not([href^="#"])');
      if (!link) return;
      event.preventDefault(); event.stopImmediatePropagation();
      postNative({type:'link', href:link.getAttribute('href')});
    }, true);
    let nativeSymbolSequence = 0;
    function updateSymbols() {
      if (!Object.keys(nativeSymbols).length) return;
      app.querySelectorAll('svg[data-lucide]:not([data-native-symbol])').forEach(svg => {
        const source = nativeSymbols[svg.dataset.lucide];
        if (!source) return;
        svg.dataset.nativeSymbol = 'true';
        const mask = 'native-symbol-' + (++nativeSymbolSequence);
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.innerHTML = '<defs><mask id="' + mask + '"><image href="' + source + '" x="1" y="1" width="22" height="22" preserveAspectRatio="xMidYMid meet"/></mask></defs><rect width="24" height="24" fill="currentColor" mask="url(#' + mask + ')"/>';
      });
    }
    new MutationObserver(updateSymbols).observe(app, {childList:true,subtree:true});
    window.JustMarkdown = {
      async openDocument(document) {
        pendingNativeAgentConsent?.resolve(false);
        pendingNativeAgentConsent = null;
        nativeRequests.clear();
        nativeUndoRequests.clear();
        postNative({ type: 'agentCancel', token: nativeToken });
        agentExperience.reset();
        nativeInputs.blur();
        nativeInputs.clear();
        nativeToken = document.token;
        nativeDocumentName = document.name || '';
        pendingNativeAgentEntry = null;
        clearTimeout(sourceTimer); renderedMarkdown = null; sourceHistory.reset(document.text);
        sourceEditor.setAttribute('aria-label',t('Markdown source'));
        ++modeRevision; modeAnimation?.cancel(); modeAnimation = null;
        readingLayout.style.removeProperty('opacity'); delete app.dataset.modeTransition;
        state.mode = 'preview'; displayedMode = 'preview'; state.agent = false;
        selection = ''; pinnedAnchor = null; lastPosition = null; transitionAnchor = null;
        stopOutlineFollow(); outlineFollowPaused = false; outlineBody.scrollTop = 0;
        updateDocument(); render(); await documentReady;
        window.scrollTo(0,0); sourceEditor.scrollTop = 0;
        window.lucide.createIcons(); updateSymbols();
        postNative({type:'documentReady',token:nativeToken});
        return this.diagnostics();
      },
      toggleMode() { switchMode(state.mode === 'preview' ? 'source' : 'preview'); },
      toggleOutline() {
        if (state.mode !== 'preview') return;
        state.outline = !state.outline; render();
      },
      suppressSelection() { readSelection(); },
      askSelection(text) {
        const selected = state.mode === 'source'
          ? sourceEditor.value.slice(sourceEditor.selectionStart,sourceEditor.selectionEnd)
          : window.getSelection()?.toString();
        askNative(text || selected || '');
      },
      toggleAgent() { agentExperience.toggleGlobal(); },
      resolveAgentEntry(payload) {
        const entry = pendingNativeAgentEntry;
        if (!entry || entry.id !== payload.id || entry.token !== nativeToken) return;
        pendingNativeAgentEntry = null;
        if (payload.allowed) entry.resume();
      },
      resolveAgentConsent(payload) {
        const pending = pendingNativeAgentConsent;
        if (!pending || pending.id !== payload.id || pending.token !== payload.token || pending.token !== nativeToken) return;
        pendingNativeAgentConsent = null;
        pending.resolve(payload.allowed === true);
      },
      closeAgent() { state.agent = false; render(); },
      updateAgentInput(payload) { nativeInputs.update(payload); },
      commitAgentInput(payload) { nativeInputs.commit(payload); },
      agentEvent(event) {
        if (event.token !== nativeToken) return;
        const request = nativeRequests.get(event.id);
        if (!request) return;
        if (event.type === 'change') request.change(event.change);
        else if (event.type === 'text') request.text(event.text);
        else {
          nativeRequests.delete(event.id);
          if (event.type === 'complete') request.complete(event);
          else if (event.type !== 'cancelled') request.fail(event.failure || { kind: 'service' });
        }
      },
      agentUndoResult(payload) {
        const resolve = nativeUndoRequests.get(payload.id);
        nativeUndoRequests.delete(payload.id);
        resolve?.(payload.result);
      },
      applyDocumentEdit(payload) {
        if (displayedMode !== 'source' || state.mode !== 'source' || sourceEditor.value !== payload.before) return false;
        if (!sourceHistory.apply(payload.before, payload.after, { id: payload.id })) return false;
        flushSource();
        if (!reducedMotion.matches) {
          sourceEditor.dataset.agentApplied = 'true';
          setTimeout(() => { delete sourceEditor.dataset.agentApplied; }, motion.editFeedback.duration);
        }
        return true;
      },
      historyAction(payload) {
        if (displayedMode !== 'source' || state.mode !== 'source') return false;
        const moved = payload.action === 'undo' ? sourceHistory.undo(payload.id) : payload.action === 'redo' && sourceHistory.redo();
        if (moved) flushSource();
        return moved;
      },
      agentDiagnostics() {
        return { open: state.agent, modal: agent.hasAttribute('data-modal-active'), draft: agent.querySelector('textarea').value,
          reference: agent.querySelector('.mdv-composer-reference').textContent, referenceHTML: agent.querySelector('.mdv-composer-reference').innerHTML,
          turns: Array.from(agent.querySelectorAll('.mdv-turn')).map(turn => ({ role: turn.dataset.role, state: turn.dataset.state, text: turn.textContent, html: turn.innerHTML })),
          markup: agent.innerHTML };
      },
      flushSource,
      reloadResources() {
        reader.querySelectorAll('img[src^="jm-resource:"]').forEach(image => { image.src = `jm-resource://${nativeToken}/image?path=${encodeURIComponent(image.dataset.sourcePath)}&revision=${Date.now()}`; });
      },
      theme(theme) {
        app.style.setProperty('--jm-font-scale', String(theme.fontScale));
        nativeSymbols = theme.symbols || {};
        Object.entries(theme.palette || {}).forEach(([name, value]) => app.style.setProperty('--mdv-' + name, value));
        updateSymbols();
      },
      async setSource(text) { sourceHistory.apply(sourceEditor.value, text); flushSource(); if (state.mode === 'preview') { updateDocument(); await documentReady; } },
      async ready() { await documentReady; return true; },
      diagnostics() {
        const unsafeTags = Array.from(reader.querySelectorAll('script,iframe,form,style')).filter(node => node.tagName.toLowerCase() !== 'style' || !node.closest('.mdv-mermaid svg')).length;
        return {mode:displayedMode, targetMode:state.mode, history:sourceHistory.state(), anchor:captureReadingPosition(), outline:state.outline, headings:headings.map(h=>h.textContent), math:reader.querySelectorAll('.katex').length, diagrams:reader.querySelectorAll('.mdv-mermaid svg').length, diagramErrors:reader.querySelectorAll('.mdv-diagram-error').length, localImages:Array.from(reader.querySelectorAll('img[src^="jm-resource:"]')).map(i=>({path:i.dataset.sourcePath,loaded:i.complete&&i.naturalWidth>0})), tables:reader.querySelectorAll('table').length, unsafeTags, source:sourceEditor.value, questionVisible:false, selectedText:window.getSelection()?.toString() || '', overflow:document.documentElement.scrollWidth>window.innerWidth};
      },
      async scrollToSourceLine(line) {
        await documentReady; pinnedAnchor = null; lastPosition = null;
        restoreReadingPosition({line,y:24}); return this.diagnostics();
      }
    };
