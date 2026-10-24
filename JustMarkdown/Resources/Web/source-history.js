/* Shared source editing history. Native menus/keys and the browser use this buffer. */
(() => {
  function create({ editor, onState }) {
    let value = editor.value, previousSelection = selection(), pending = null;
    let undo = [], redo = [], group = null, sequence = 0, internal = false, composing = false;
    function selection() {
      return { start: editor.selectionStart, end: editor.selectionEnd, direction: editor.selectionDirection, top: editor.scrollTop };
    }
    function difference(before, after) {
      let start = 0, suffix = 0;
      while (start < before.length && start < after.length && before[start] === after[start]) ++start;
      while (suffix < before.length - start && suffix < after.length - start && before.at(-1 - suffix) === after.at(-1 - suffix)) ++suffix;
      return { start, before: before.slice(start, before.length - suffix), after: after.slice(start, after.length - suffix) };
    }
    function notify(entry, status) {
      onState({ canUndo: !!undo.length, canRedo: !!redo.length, transactionID: entry?.id || null, status: status || null });
    }
    function record(next, options = {}) {
      if (next === value) { previousSelection = selection(); return; }
      const patch = difference(value, next), kind = options.kind || '';
      const last = undo.at(-1);
      let merged = false;
      if (group && group === last && group.kind === kind) {
        if (kind === 'insertText' && !patch.before && !last.before && patch.start === last.start + last.after.length) {
          last.after += patch.after; merged = true;
        } else if (kind === 'deleteContentBackward' && !patch.after && !last.after && patch.start + patch.before.length === last.start) {
          last.start = patch.start; last.before = patch.before + last.before; merged = true;
        } else if (kind === 'deleteContentForward' && !patch.after && !last.after && patch.start === last.start) {
          last.before += patch.before; merged = true;
        } else if (kind === 'composition' && patch.start >= last.start && patch.start + patch.before.length <= last.start + last.after.length) {
          const offset = patch.start - last.start;
          last.after = last.after.slice(0, offset) + patch.after + last.after.slice(offset + patch.before.length); merged = true;
        }
      }
      const entry = merged ? last : { ...patch, id: options.id || 'source-' + (++sequence), kind, beforeSelection: pending || previousSelection };
      entry.afterSelection = selection();
      if (!merged) undo.push(entry);
      redo = [];
      value = next;
      previousSelection = entry.afterSelection;
      pending = null;
      group = ['insertText', 'deleteContentBackward', 'deleteContentForward', 'composition'].includes(kind) ? entry : null;
      if (kind === 'insertText' && /[\s。！？；，,.!?;:]$/u.test(patch.after)) group = null;
      notify(entry, 'applied');
    }
    function setText(text, targetSelection) {
      internal = true;
      editor.value = text;
      const position = targetSelection || previousSelection;
      editor.setSelectionRange(Math.min(position.start, text.length), Math.min(position.end, text.length), position.direction || 'none');
      editor.scrollTop = position.top;
      editor.dispatchEvent(new Event('input', { bubbles: true }));
      internal = false;
    }
    function move(forward, id) {
      const from = forward ? redo : undo, to = forward ? undo : redo;
      const entry = from.at(-1);
      if (!entry || (id && entry.id !== id) || editor.value !== value) return false;
      const expected = forward ? entry.before : entry.after, replacement = forward ? entry.after : entry.before;
      if (value.slice(entry.start, entry.start + expected.length) !== expected) return false;
      value = value.slice(0, entry.start) + replacement + value.slice(entry.start + expected.length);
      setText(value, forward ? entry.afterSelection : entry.beforeSelection);
      from.pop(); to.push(entry); group = null; pending = null; previousSelection = selection();
      notify(entry, forward ? 'applied' : 'undone');
      return true;
    }
    editor.addEventListener('beforeinput', event => {
      if (internal) return;
      if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
        if (event.cancelable) { event.preventDefault(); move(event.inputType === 'historyRedo'); }
        return;
      }
      pending = selection();
    });
    editor.addEventListener('input', event => {
      if (internal) return;
      if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
        setText(value); move(event.inputType === 'historyRedo'); return;
      }
      record(editor.value, { kind: composing || event.isComposing ? 'composition' : event.inputType });
    });
    editor.addEventListener('keydown', event => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z' && !event.altKey && !event.isComposing) {
        event.preventDefault(); if (!event.repeat) move(event.shiftKey); return;
      }
      if (/^(Arrow|Home|End|Page)/.test(event.key)) group = null;
    });
    editor.addEventListener('pointerdown', () => { group = null; });
    editor.addEventListener('blur', () => { group = null; });
    editor.addEventListener('compositionstart', () => { group = null; composing = true; });
    editor.addEventListener('compositionend', () => { composing = false; group = null; });
    document.addEventListener('selectionchange', () => {
      const current = selection();
      if (!composing && (current.start !== previousSelection.start || current.end !== previousSelection.end)) group = null;
      previousSelection = current;
    });
    return {
      reset(text) {
        internal = true; editor.value = text; internal = false;
        value = text; undo = []; redo = []; group = null; pending = null; previousSelection = selection(); notify();
      },
      apply(before, after, options = {}) {
        if (editor.value !== before || value !== before) return false;
        const previous = selection(), patch = difference(before, after);
        const delta = patch.after.length - patch.before.length, end = patch.start + patch.before.length;
        const position = offset => offset <= patch.start ? offset : offset >= end ? offset + delta : patch.start + Math.min(offset - patch.start, patch.after.length);
        pending = previous;
        setText(after, { ...previous, start: position(previous.start), end: position(previous.end) });
        record(after, { ...options, kind: 'transaction' });
        return true;
      },
      undo: id => move(false, id), redo: () => move(true),
      state: () => ({ canUndo: !!undo.length, canRedo: !!redo.length })
    };
  }
  window.JustMarkdownSourceHistory = { create };
})();
