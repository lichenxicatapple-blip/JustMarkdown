/* Shared conversation UI. Model transport is provided by the host. */
(() => {
  const createNode = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  function icon(name) {
    const node = createNode('i');
    node.dataset.lucide = name;
    node.setAttribute('aria-hidden', 'true');
    return node;
  }
  function button(label, action, iconName) {
    const node = createNode('button', 'cursor-interaction');
    node.type = 'button';
    node.setAttribute('aria-label', label);
    if (action) node.dataset.agentAction = action;
    if (iconName) node.append(icon(iconName));
    else node.textContent = label;
    return node;
  }
  const { t, formatSeconds } = window.JustMarkdownLocalization;
  const refreshIcons = () => window.lucide?.createIcons({ attrs: { width: 18, height: 18 } });
  function create(dependencies) {
    const { app, panel, renderMarkdown, enhance, motion, reducedMotion, onToggle, documentAttachment, provider, nativeInputs, onPresentationChange, ensureConfigured } = dependencies;
    const compact = matchMedia('(max-width: 899px)');
    const scroll = panel.querySelector('.mdv-agent-scroll');
    const thread = panel.querySelector('.mdv-conversation');
    const composer = panel.querySelector('.mdv-composer');
    const input = composer.querySelector('textarea');
    const reference = composer.querySelector('.mdv-composer-reference');
    const sendButton = composer.querySelector('.mdv-agent-send');
    const useDocument = button(t("Reference current document"), 'use-document', 'file-text');
    useDocument.append(createNode('span', '', t("Reference document")));
    useDocument.classList.add('mdv-use-document');
    useDocument.hidden = true;
    sendButton.before(useDocument);
    const announcement = panel.querySelector('[role="status"]');
    const scrim = createNode('div', 'mdv-agent-scrim');
    scrim.hidden = true;
    scrim.setAttribute('aria-hidden', 'true');
    panel.id = app.dataset.layout + '-conversation';
    app.append(scrim, panel);
    nativeInputs?.register(input, "question");
    const messages = [];
    const documentChanges = new Map();
    let attachment = null;
    let messageSequence = 0;
    let isOpen = false;
    let presented = false;
    let panelAnimation = null;
    let scrimAnimation = null;
    let panelRevision = 0;
    let activeStream = null;
    let pendingAuthorization = null;
    let conversationRevision = 0;
    let latestRequest = null;
    let referenceScrollTimer = 0;
    const referenceViewportObserver = new ResizeObserver(entries => {
      const body = entries[0].target;
      reference.style.setProperty('--mdv-reference-gutter', Math.max(0, body.offsetWidth - body.clientWidth) + 'px');
    });
    let followBottom = true;
    let drag = null;
    const disclosureAnimations = new WeakMap();
    const seconds = spec => reducedMotion.matches ? 0 : spec.duration;
    function announce(text) { announcement.textContent = text; }
    function animateContent(element, spec = motion.message) {
      if (reducedMotion.matches) return;
      element.animate([{ opacity: 0, transform: 'translateY(4px)' }, { opacity: 1, transform: 'none' }], spec);
    }
    function disclosure(element, shown, finished) {
      const previous = disclosureAnimations.get(element);
      const start = element.hidden ? 0 : element.getBoundingClientRect().height;
      previous?.cancel();
      element.hidden = false;
      element.inert = !shown;
      element.setAttribute('aria-hidden', String(!shown));
      const finish = () => {
        element.hidden = !shown;
        element.style.removeProperty('height');
        element.style.removeProperty('overflow');
        disclosureAnimations.delete(element);
        finished?.();
      };
      if (reducedMotion.matches) { finish(); return; }
      element.style.overflow = 'hidden';
      const animation = element.animate([{ height: start + 'px', opacity: start ? 1 : 0 }, { height: shown ? element.scrollHeight + 'px' : '0px', opacity: shown ? 1 : 0 }], { ...motion.reference, fill: 'both' });
      disclosureAnimations.set(element, animation);
      animation.onfinish = () => {
        if (disclosureAnimations.get(element) !== animation) return;
        animation.cancel();
        finish();
      };
    }
    function rich(markdown, prefix) {
      const surface = createNode('div', 'mdv-rich-text');
      surface.dataset.component = 'RichText';
      surface.append(renderMarkdown(markdown, prefix));
      return surface;
    }
    function referenceLabel(value) {
      return value.scope === 'document'
        ? value.documentName || t('Current document')
        : value.text.trim();
    }
    function appendReference(parent, value) {
      const details = createNode('details', 'mdv-message-reference');
      const summary = createNode('summary', 'cursor-interaction');
      summary.setAttribute('aria-label', t("Expand reference"));
      summary.setAttribute('aria-expanded', 'false');
      summary.append(icon('chevron-right'), createNode('span', '', referenceLabel(value)));
      const body = createNode('div', 'mdv-rich-text');
      const prefix = 'reference-' + (++messageSequence);
      body.hidden = true;
      details.append(summary, body);
      parent.append(details);
      summary.addEventListener('click', event => {
        event.preventDefault();
        followBottom = false;
        const shown = summary.getAttribute('aria-expanded') !== 'true';
        details.open = true;
        summary.setAttribute('aria-expanded', String(shown));
        summary.setAttribute('aria-label', shown ? t("Collapse reference") : t("Expand reference"));
        if (shown) {
          if (!body.childNodes.length) body.append(renderMarkdown(value.markdown, prefix));
          enhance(body);
        }
        disclosure(body, shown, () => { if (!shown) details.open = false; });
      });
      return details;
    }
    function renderAttachment(value, origin) {
      clearTimeout(referenceScrollTimer);
      referenceViewportObserver.disconnect();
      reference.style.removeProperty('--mdv-reference-gutter');
      reference.replaceChildren();
      reference.hidden = !value;
      useDocument.hidden = !!value;
      if (!value) return;
      const row = createNode('div', 'mdv-reference-row');
      const isDocument = value.scope === 'document';
      row.dataset.scope = isDocument ? 'document' : 'selection';
      const remove = button(t("Remove reference"), 'remove-reference', 'x');
      remove.classList.add('mdv-reference-remove');
      const body = createNode('div', 'mdv-reference-body');
      body.addEventListener('scroll', () => {
        body.dataset.scrolling = 'true';
        clearTimeout(referenceScrollTimer);
        referenceScrollTimer = setTimeout(() => { delete body.dataset.scrolling; }, 800);
      }, { passive: true });
      body.hidden = isDocument;
      const content = createNode('div', 'mdv-rich-text');
      content.dataset.component = 'RichText';
      const prefix = 'composer-reference-' + (++messageSequence);
      body.append(content);
      if (isDocument) {
        const toggle = button(t("Expand reference"), 'toggle-reference', 'file-text');
        toggle.classList.add('mdv-reference-toggle');
        toggle.setAttribute('aria-expanded', 'false');
        toggle.append(createNode('span', 'mdv-reference-label', referenceLabel(value)), icon('chevron-down'));
        row.append(toggle, remove);
        reference.append(row, body);
        toggle.addEventListener('click', event => {
          event.stopPropagation();
          const shown = toggle.getAttribute('aria-expanded') !== 'true';
          toggle.setAttribute('aria-expanded', String(shown));
          toggle.setAttribute('aria-label', shown ? t("Collapse reference") : t("Expand reference"));
          if (shown) {
            if (!content.childNodes.length) content.append(renderMarkdown(value.markdown, prefix));
            enhance(content);
          }
          disclosure(body, shown);
        });
      } else {
        body.setAttribute('role', 'region');
        body.setAttribute('aria-label', t("Referenced content"));
        body.tabIndex = 0;
        content.append(renderMarkdown(value.markdown, prefix));
        const marker = createNode('span', 'mdv-reference-icon');
        marker.setAttribute('aria-hidden', 'true');
        marker.append(icon(value.mode === 'source' ? 'code' : 'quote'));
        content.prepend(marker, remove);
        row.append(body);
        reference.append(row);
        referenceViewportObserver.observe(body);
        enhance(content);
      }
      remove.addEventListener('click', event => { event.stopPropagation(); attachment = null; renderAttachment(null); });
      if (origin && !reducedMotion.matches) {
        const destination = reference.getBoundingClientRect();
        const dx = Math.max(-32, Math.min(32, origin.left - destination.left));
        reference.animate([{ opacity: 0, transform: 'translate(' + dx + 'px, 8px)' }, { opacity: 1, transform: 'none' }], motion.reference);
      }
      refreshIcons();
    }
    function updateSendState() {
      const generating = !!activeStream;
      sendButton.disabled = !!pendingAuthorization || (!generating && !input.value.trim());
      sendButton.setAttribute('aria-label', generating ? t("Stop generating") : t("Send message"));
      sendButton.type = generating ? 'button' : 'submit';
      const desired = generating ? 'square' : 'arrow-up';
      if (sendButton.dataset.icon !== desired) {
        sendButton.replaceChildren(icon(desired));
        sendButton.dataset.icon = desired;
        refreshIcons();
      }
      input.style.height = 'auto';
      input.style.height = Math.min(160, Math.max(52, input.scrollHeight)) + 'px';
    }
    function keepAtBottom() {
      if (followBottom && isOpen) scroll.scrollTop = scroll.scrollHeight;
    }
    const contentObserver = new ResizeObserver(keepAtBottom);
    contentObserver.observe(thread);
    const nearBottom = () => scroll.scrollHeight - scroll.clientHeight - scroll.scrollTop < 56;
    // Programmatic scroll events can arrive after a user's wheel gesture.
    // Only explicit downward navigation may resume following a running reply.
    scroll.addEventListener('scroll', () => { if (!nearBottom()) followBottom = false; }, { passive: true });
    scroll.addEventListener('wheel', event => {
      if (event.deltaY < 0) followBottom = false;
      else if (event.deltaY > 0) requestAnimationFrame(() => { if (nearBottom()) followBottom = true; });
    }, { passive: true });
    scroll.addEventListener('pointerdown', () => { followBottom = false; }, { passive: true });
    let touchY = null;
    let touchDirection = 0;
    scroll.addEventListener('touchstart', event => { touchY = event.touches[0]?.clientY ?? null; touchDirection = 0; }, { passive: true });
    scroll.addEventListener('touchmove', event => {
      const y = event.touches[0]?.clientY;
      if (touchY === null || y === undefined) return;
      touchDirection = touchY - y;
      touchY = y;
      followBottom = false;
    }, { passive: true });
    scroll.addEventListener('touchend', () => {
      if (touchDirection > 0) requestAnimationFrame(() => { if (nearBottom()) followBottom = true; });
      touchY = null;
    }, { passive: true });
    scroll.addEventListener('keydown', event => {
      if (['ArrowUp','PageUp','Home'].includes(event.key)) followBottom = false;
      if (event.key === 'End') followBottom = true;
    });
    function updateModality(shown) {
      const modal = shown && compact.matches;
      panel.toggleAttribute('data-modal-active', modal);
      onPresentationChange?.({ open: isOpen, modal });
      panel.setAttribute('role', modal ? 'dialog' : 'complementary');
      if (modal) panel.setAttribute('aria-modal', 'true');
      else panel.removeAttribute('aria-modal');
      const collapse = panel.querySelector('[data-agent-action="collapse"]');
      collapse.replaceChildren(icon(compact.matches ? 'chevron-down' : 'chevron-right'));
      refreshIcons();
      if (modal && !panel.contains(document.activeElement)) collapse.focus({ preventScroll: true });
      [app.querySelector('.mdv-reader'), app.querySelector('.mdv-outline')].filter(Boolean).forEach(node => { node.inert = modal; });
    }
    function present(shown) {
      if (shown === presented) return;
      presented = shown;
      isOpen = shown;
      const revision = ++panelRevision;
      const hidden = panel.hidden;
      const style = hidden ? null : getComputedStyle(panel);
      const start = { opacity: hidden ? 0 : style.opacity, transform: hidden ? (compact.matches ? 'translateY(100%)' : 'translateX(24px)') : style.transform };
      panelAnimation?.cancel();
      scrimAnimation?.cancel();
      panel.hidden = false;
      panel.inert = !shown;
      nativeInputs?.trackLayout();
      app.classList.toggle('mdv-agent-open', shown);
      if (shown) updateModality(true);
      else { nativeInputs?.blur(); onPresentationChange?.({ open: false, modal: panel.hasAttribute("data-modal-active") }); }
      const useScrim = compact.matches && (shown || !scrim.hidden);
      if (useScrim) scrim.hidden = false;
      const finish = () => {
        if (revision !== panelRevision) return;
        panel.hidden = !shown;
        panelAnimation?.cancel();
        scrimAnimation?.cancel();
        panelAnimation = null;
        scrimAnimation = null;
        scrim.hidden = !shown || !compact.matches;
        if (!shown) {
          updateModality(false);
        }
        keepAtBottom();
      };
      if (!seconds(motion.agentPanel)) { finish(); return; }
      panelAnimation = panel.animate([start, { opacity: shown ? 1 : 0, transform: shown ? 'none' : compact.matches ? 'translateY(100%)' : 'translateX(24px)' }], { ...motion.agentPanel, fill: 'both' });
      if (useScrim) scrimAnimation = scrim.animate([{ opacity: shown ? 0 : 1 }, { opacity: shown ? 1 : 0 }], { ...motion.agentPanel, fill: 'both' });
      panelAnimation.onfinish = finish;
    }
    function attach(value, rect, authorized = false) {
      if (!value?.text.trim()) return;
      if (!value.documentMarkdown) {
        const background = documentAttachment();
        value = { ...value, documentMarkdown: background.markdown, documentName: background.documentName };
      }
      if (!authorized && ensureConfigured) { const snapshot = { ...value }; ensureConfigured(() => attach(snapshot, rect, true)); return; }
      attachment = { ...value };
      followBottom = true;
      onToggle(true);
      renderAttachment(attachment, rect);
      input.focus({ preventScroll: true });
    }
    function addMessage(role, markdown, value) {
      const message = { id: ++messageSequence, role, markdown, attachment: value ? { ...value } : null };
      messages.push(message);
      const turn = createNode('article', 'mdv-turn mdv-' + role + '-turn');
      turn.dataset.component = 'ConversationTurn';
      turn.dataset.role = role;
      turn.setAttribute('aria-label', role === 'user' ? t("Your message") : t("AI response"));
      message.element = turn;
      if (value) appendReference(turn, value);
      const surface = rich(markdown, 'message-' + message.id);
      message.surface = surface;
      turn.append(surface);
      thread.append(turn);
      animateContent(turn);
      enhance(surface);
      keepAtBottom();
      refreshIcons();
      return message;
    }
    function finishStream(record, stopped = false) {
      if (activeStream !== record) return;
      clearTimeout(record.renderTimer);
      if (record.liveMarkdown) renderLive(record);
      record.pending.remove();
      record.message.element.dataset.state = stopped ? 'stopped' : 'complete';
      record.message.element.removeAttribute('aria-busy');
      if (!stopped) record.message.markdown = record.request.markdown;
      if (stopped) record.cancel?.();
      if (stopped) record.message.element.append(createNode('p', 'mdv-turn-status', t("Generation stopped")));
      activeStream = null;
      updateSendState();
      announce(stopped ? t("Generation stopped. The received content has been kept.") : t("Response complete. You can ask a follow-up question."));
      keepAtBottom();
    }
    const failureMessages = {
      permission: t("Allow sending to this AI service before trying again."),
      network: t("Unable to connect to the service"),
      timeout: t("Request timed out"),
      authentication: t("Authentication failed. Check your API key"),
      configuration: t("Check the service URL, API type, and model"),
      rateLimit: t("Too many requests"),
      service: t("Service temporarily unavailable"),
      response: t("Unable to read the response"),
      incomplete: t("Response incomplete"),
      contextLimit: t("Content exceeds the model’s context limit"),
      requestTooLarge: t("Request too large"),
      stale: t("The document has changed. No edits were made")
    };
    function clearRetry(request) {
      clearInterval(request?.cooldownTimer);
      request?.retryButton?.remove();
    }
    function failStream(record) {
      if (activeStream !== record) return;
      clearTimeout(record.renderTimer);
      if (record.liveMarkdown) renderLive(record);
      record.pending.remove();
      activeStream = null;
      const { request, message, failure } = record;
      message.element.dataset.state = 'failed';
      message.element.removeAttribute('aria-busy');
      const partial = message.surface.hasChildNodes();
      const reason = partial ? t("Response interrupted") : failureMessages[failure.kind] || t("Request failed");
      const status = createNode('div', 'mdv-request-status');
      status.dataset.component = 'RequestStatus';
      status.setAttribute('role', 'group');
      status.setAttribute('aria-label', t("Request failed"));
      const retryLabel = partial ? t("Regenerate") : t("Retry");
      const retry = button(retryLabel, 'retry');
      status.append(createNode('p', '', reason), retry);
      message.element.append(status);
      request.status = status;
      request.retryButton = retry;
      request.retryAt = Date.now() + Math.max(0, failure.retryAfterSeconds || 0) * 1000;
      function updateRetry() {
        const remaining = Math.max(0, Math.ceil((request.retryAt - Date.now()) / 1000));
        retry.disabled = remaining > 0;
        retry.textContent = remaining ? t('Retry in {duration}', { duration: formatSeconds(remaining) }) : retryLabel;
        if (!remaining) clearInterval(request.cooldownTimer);
      }
      updateRetry();
      if (retry.disabled) request.cooldownTimer = setInterval(updateRetry, 250);
      retry.addEventListener('click', () => {
        if (activeStream || latestRequest !== request || Date.now() < request.retryAt) return;
        authorizeSend(() => {
          if (latestRequest !== request) return;
          followBottom = true;
          // Keep keyboard focus in the response without opening the software keyboard.
          message.element.tabIndex = -1;
          message.element.focus({ preventScroll: true });
          streamReply(request);
        });
      });
      updateSendState();
      animateContent(status, motion.content);
      announce(retry.disabled ? t('{reason}. You can retry shortly.', { reason }) : t('{reason}. {action}.', { reason, action: retryLabel }));
      if (document.activeElement === message.element && !retry.disabled) retry.focus({ preventScroll: true });
      keepAtBottom();
    }
    function streamReply(request) {
      if (activeStream) return;
      const retrying = request.attempt++ > 0;
      clearRetry(request);
      request.status?.remove();
      const message = request.message || addMessage('assistant', '', null);
      request.message = message;
      const pending = createNode('div', 'mdv-request-status');
      pending.dataset.component = 'RequestStatus';
      const progress = createNode('div', 'mdv-agent-pending', retrying ? t("Retrying…") : t("Generating…"));
      pending.append(progress);
      message.element.append(pending);
      message.element.dataset.state = retrying ? 'retrying' : 'pending';
      message.element.setAttribute('aria-busy', 'true');
      const record = { request, message, pending, replaceOnFirstBlock: message.surface.hasChildNodes(), liveMarkdown: '' };
      activeStream = record;
      updateSendState();
      announce(retrying ? t("Retrying with the original question and reference.") : t("Generating a response."));
      record.cancel = provider.stream(request.snapshot, request.intent, {
        text(delta) {
          if (activeStream !== record) return;
          record.liveMarkdown += delta;
          if (!record.renderTimer) record.renderTimer = setTimeout(() => { record.renderTimer = null; renderLive(record); }, 100);
        },
        complete() {
          if (activeStream !== record) return;
          clearTimeout(record.renderTimer);
          request.markdown = record.liveMarkdown;
          if (record.liveMarkdown) renderLive(record);
          finishStream(record);
        },
        change(value) { appendDocumentChange(message, value); },
        fail(failure) { if (activeStream === record) { record.failure = failure; failStream(record); } }
      });
    }
    function renderLive(record) {
      if (activeStream !== record || !record.liveMarkdown.trim()) return;
      const prepared = renderMarkdown(record.liveMarkdown, 'message-' + record.message.id);
      const nodes = Array.from(prepared.childNodes).filter(node => node.nodeType !== Node.TEXT_NODE || node.textContent.trim());
      if (!nodes.length) return;
      if (record.replaceOnFirstBlock) { record.message.surface.replaceChildren(); record.replaceOnFirstBlock = false; }
      const surface = record.message.surface;
      nodes.forEach((node, index) => {
        const markup = node.outerHTML || node.textContent;
        let block = surface.children[index];
        if (block?.dataset.markup === markup) return;
        const next = createNode('div', 'mdv-response-block');
        next.dataset.markup = markup;
        next.append(node);
        if (block) block.replaceWith(next); else surface.append(next);
        // Leave an unfinished Mermaid fence as readable source until closed.
        const fences = record.liveMarkdown.split('\n').filter(line => /^\s*(`{3,}|~{3,})/.test(line));
        if (!(index === nodes.length - 1 && fences.length % 2 && next.querySelector('.mdv-mermaid'))) enhance(next).then(keepAtBottom);
        if (!block) animateContent(next);
      });
      while (surface.children.length > nodes.length) surface.lastElementChild.remove();
      record.request.markdown = record.liveMarkdown;
      record.message.markdown = record.liveMarkdown;
      record.message.element.dataset.state = 'streaming';
      keepAtBottom();
    }
    function beginRequest(user) {
      clearRetry(latestRequest);
      user.intent = 'question';
      user.document = Object.freeze({ ...documentAttachment() });
      const history = Object.freeze(messages.filter(message => message.role === 'user' || message.markdown.trim() || message.changes?.length).map(message => Object.freeze({
        role: message.role,
        intent: message.intent || null,
        document: message.document || null,
        markdown: message.markdown,
        attachment: message.attachment ? Object.freeze({ ...message.attachment }) : null,
        status: message.element.dataset.state || null,
        changes: message.changes?.map(change => Object.freeze({ before: change.edits.map(edit => edit.before).join('\n\n'), after: change.edits.map(edit => edit.after).join('\n\n'), status: change.status })) || null
      })));
      const snapshot = Object.freeze({ id: crypto.randomUUID(), question: user.markdown, attachment: user.attachment ? Object.freeze({ ...user.attachment }) : null, document: user.document, history });
      latestRequest = { snapshot, intent: 'question', markdown: '', attempt: 0 };
      streamReply(latestRequest);
    }
    function send() {
      if (nativeInputs && !nativeInputs.committing) { nativeInputs.requestSubmit('question'); return; }
      if (activeStream || !input.value.trim()) return;
      authorizeSend(() => {
        if (!input.value.trim()) return;
        const text = input.value.trim();
        const value = attachment?.scope === 'document' ? documentAttachment() : attachment ? { ...attachment } : null;
        followBottom = true;
        const user = addMessage('user', text, value);
        input.value = '';
        attachment = null;
        renderAttachment(null);
        beginRequest(user);
        input.focus({ preventScroll: true });
      });
    }
    async function authorizeSend(action) {
      if (activeStream || pendingAuthorization) return;
      const pending = { revision: conversationRevision };
      pendingAuthorization = pending;
      updateSendState();
      try {
        const allowed = await provider.authorize();
        if (allowed && pendingAuthorization === pending && pending.revision === conversationRevision) action();
      } finally {
        if (pendingAuthorization === pending) pendingAuthorization = null;
        updateSendState();
      }
    }
    function diffLines(before, after) {
      const oldLines = before.split('\n');
      const newLines = after.split('\n');
      let commonStart = 0;
      while (commonStart < oldLines.length && commonStart < newLines.length && oldLines[commonStart] === newLines[commonStart]) commonStart++;
      let commonEnd = 0;
      while (commonEnd < oldLines.length - commonStart && commonEnd < newLines.length - commonStart && oldLines.at(-1 - commonEnd) === newLines.at(-1 - commonEnd)) commonEnd++;
      return [
        ...oldLines.slice(0, commonStart).map(text => ({ change: 'same', text })),
        ...oldLines.slice(commonStart, oldLines.length - commonEnd).map(text => ({ change: 'remove', text })),
        ...newLines.slice(commonStart, newLines.length - commonEnd).map(text => ({ change: 'insert', text })),
        ...oldLines.slice(oldLines.length - commonEnd).map(text => ({ change: 'same', text }))
      ];
    }
    function appendDocumentChange(message, value) {
      message.changes ||= [];
      const existing = message.changes.find(change => change.id === value.id);
      if (existing) {
        existing.saved = value.saved;
        existing.note.textContent = value.saved === false ? t("Changes have not been saved.") : '';
        existing.note.hidden = value.saved !== false;
        return;
      }
      const change = { ...value, status: 'applied' };
      message.changes.push(change);
      const card = createNode('section', 'mdv-proposal');
      card.dataset.component = 'DocumentChange';
      card.setAttribute('aria-label', t("Document changes"));
      const header = createNode('div', 'mdv-proposal-header');
      const title = createNode('span', '', t("Edited"));
      header.append(title);
      const diff = createNode('pre', 'mdv-diff');
      diff.setAttribute('aria-label', t("Changes: minus indicates removed text; plus indicates added text"));
      change.edits.forEach((edit, index) => {
        if (index) diff.append(createNode('span', 'mdv-diff-line', ''));
        diffLines(edit.before, edit.after).forEach(line => {
          const row = createNode('span', 'mdv-diff-line', (line.change === 'remove' ? '− ' : line.change === 'insert' ? '+ ' : '  ') + line.text);
          row.dataset.change = line.change;
          diff.append(row);
        });
      });
      const actions = createNode('div', 'mdv-proposal-actions');
      const undo = button(t("Undo this edit"), 'undo');
      undo.textContent = t("Undo");
      actions.append(undo);
      const note = createNode('p', 'mdv-proposal-note', value.saved === false ? t("Changes have not been saved.") : '');
      note.hidden = value.saved !== false;
      note.setAttribute('role', 'alert');
      change.note = note;
      change.showStatus = status => {
        const changed = change.status !== status;
        change.status = status;
        title.textContent = status === 'undone' ? t("Undone") : t("Edited");
        undo.hidden = status === 'undone';
        actions.hidden = status === 'undone';
        undo.disabled = false;
        note.hidden = true;
        if (changed) animateContent(title, motion.editFeedback);
      };
      documentChanges.set(change.id, change);
      card.append(header, diff, actions, note);
      message.element.append(card);
      undo.addEventListener('click', async () => {
        if (undo.disabled || change.status !== 'applied') return;
        undo.disabled = true;
        try {
          const result = await provider.undo(change.id);
          if (result.status === 'undone') {
            // History events already applied the undo. A later redo can precede
            // this save acknowledgement, so it must remain the source of truth.
            if (change.status !== 'undone') return;
            note.textContent = result.saved === 'false' ? t("The undo has not been saved.") : '';
            note.hidden = result.saved !== 'false';
            animateContent(title, motion.editFeedback);
            announce(t("This edit has been undone."));
          } else {
            note.textContent = result.message || t("Unable to undo this edit.");
            note.hidden = false;
            undo.disabled = result.error === 'stale';
          }
        } catch {
          note.textContent = t("Unable to undo. Try again."); note.hidden = false; undo.disabled = false;
        }
      });
      animateContent(card, motion.proposal);
      keepAtBottom();
      announce(t("Document edited. Undo is available."));
    }
    app.addEventListener('mdv-source-history', event => {
      const { transactionID, status } = event.detail;
      const change = documentChanges.get(transactionID);
      if (change && status) {
        change.showStatus(status);
        announce(status === 'undone' ? t("This edit has been undone.") : t("This edit has been redone."));
      }
    });
    composer.addEventListener('submit', event => { event.preventDefault(); send(); });
    sendButton.addEventListener('click', event => {
      if (!activeStream) return;
      event.preventDefault();
      finishStream(activeStream, true);
    });
    input.addEventListener('input', updateSendState);
    panel.querySelector('[data-agent-action="collapse"]').addEventListener('click', () => onToggle(false));
    function toggleGlobal(authorized = false) {
      if (!isOpen && !authorized && ensureConfigured) { ensureConfigured(() => toggleGlobal(true)); return; }
      if (isOpen) { onToggle(false); return; }
      // Entry intent determines the next request's context. Reopening globally
      // must never resurrect an abandoned selection; sent turns keep theirs.
      attachment = documentAttachment();
      onToggle(true);
      renderAttachment(attachment);
      input.focus({ preventScroll: true });
    }
    useDocument.addEventListener('click', () => {
      attachment = documentAttachment();
      renderAttachment(attachment);
      input.focus({ preventScroll: true });
    });
    scrim.addEventListener('click', () => onToggle(false));
    app.addEventListener('click', event => {
      const link = event.target.closest('.mdv-rich-text a[href^="#"]');
      if (!link) return;
      const target = document.getElementById(link.getAttribute('href').slice(1));
      if (target && panel.contains(target)) {
        event.preventDefault();
        target.scrollIntoView({ block: 'nearest', behavior: reducedMotion.matches ? 'instant' : 'smooth' });
      }
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape') {
        if (isOpen) { event.preventDefault(); onToggle(false); }
      }
      if (event.key === 'Tab' && compact.matches && isOpen) {
        const controls = Array.from(panel.querySelectorAll('button:not([disabled]),textarea,a[href],summary')).filter(node => node.getClientRects().length && !node.closest('[inert]'));
        const first = controls[0];
        const last = controls.at(-1);
        if (event.shiftKey && (document.activeElement === first || !panel.contains(document.activeElement))) { event.preventDefault(); last?.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
      }
    });
    const grabber = panel.querySelector('.mdv-agent-grabber');
    grabber.addEventListener('pointerdown', event => {
      if (!compact.matches || event.button !== 0) return;
      panelAnimation?.cancel();
      panelAnimation = null;
      drag = { y: event.clientY, offset: 0 };
      grabber.setPointerCapture(event.pointerId);
    });
    grabber.addEventListener('pointermove', event => {
      if (!drag) return;
      drag.offset = Math.max(0, event.clientY - drag.y);
      panel.style.transform = reducedMotion.matches ? 'none' : 'translateY(' + drag.offset + 'px)';
    });
    function endDrag(cancelled) {
      if (!drag) return;
      const offset = drag.offset;
      drag = null;
      if (!cancelled && offset > 72) { onToggle(false); panel.style.removeProperty('transform'); }
      else {
        if (!reducedMotion.matches) panel.animate([{ transform: 'translateY(' + offset + 'px)' }, { transform: 'none' }], motion.agentPanel);
        panel.style.removeProperty('transform');
      }
    }
    grabber.addEventListener('pointerup', () => endDrag(false));
    grabber.addEventListener('pointercancel', () => endDrag(true));
    compact.addEventListener('change', () => {
      panelAnimation?.cancel();
      scrimAnimation?.cancel();
      panelAnimation = null;
      scrimAnimation = null;
      panel.hidden = !isOpen;
      scrim.hidden = !isOpen || !compact.matches;
      updateModality(isOpen);
      keepAtBottom();
    });
    reducedMotion.addEventListener('change', event => {
      if (event.matches) {
        panelAnimation?.finish();
        app.getAnimations({ subtree: true }).forEach(animation => {
          if (animation.effect?.getTiming().iterations !== Infinity) animation.finish();
        });
      }
    });
    function viewportChanged() {
      const viewport = window.visualViewport;
      if (compact.matches && viewport) {
        panel.style.maxHeight = Math.max(160, viewport.height - 16) + 'px';
        panel.style.bottom = Math.max(0, innerHeight - viewport.height - viewport.offsetTop) + 'px';
      } else {
        panel.style.removeProperty('max-height');
        panel.style.removeProperty('bottom');
      }
    }
    window.visualViewport?.addEventListener('resize', viewportChanged);
    window.visualViewport?.addEventListener('scroll', viewportChanged);
    compact.addEventListener('change', viewportChanged);
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      panel.querySelectorAll('.mdv-rich-text').forEach(surface => enhance(surface).then(keepAtBottom));
    });
    updateSendState();
    viewportChanged();
    function reset() {
      ++conversationRevision;
      pendingAuthorization = null;
      if (activeStream) { activeStream.cancel?.(); clearTimeout(activeStream.timer); clearTimeout(activeStream.renderTimer); }
      activeStream = null;
      clearRetry(latestRequest);
      latestRequest = null;
      messages.splice(0);
      documentChanges.clear();
      thread.replaceChildren();
      attachment = null;
      input.value = '';
      renderAttachment(null);
      updateSendState();
      onToggle(false);
    }
    return { attach, present, send, toggleGlobal, reset };

  }
  window.JustMarkdownAgent = { create };
})();
