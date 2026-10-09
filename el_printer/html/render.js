/*
 * el_printer - document renderer.
 * Renders the server-built document model into the final printed layout.
 * The same renderer is used for the dashboard preview, saved documents and printed items,
 * so the preview always matches the printed result.
 * All values are inserted with textContent (never innerHTML).
 */
(function () {
  'use strict';

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function icon(name, extra) {
    const node = document.createElement('i');
    node.className = 'fa-solid ' + (name || 'fa-file') + (extra ? ' ' + extra : '');
    node.setAttribute('aria-hidden', 'true');
    return node;
  }

  function emblem(org, fallbackIcon) {
    const wrap = el('div', 'el-doc-emblem');
    if (org && org.logo && /^(https:\/\/|nui:\/\/)/.test(org.logo)) {
      const img = document.createElement('img');
      img.src = org.logo;
      img.alt = '';
      img.onerror = function () { img.remove(); wrap.appendChild(icon(org.icon || fallbackIcon)); };
      wrap.appendChild(img);
    } else {
      wrap.appendChild(icon((org && org.icon) || fallbackIcon || 'fa-building'));
    }
    return wrap;
  }

  function paragraphs(text) {
    const frag = document.createDocumentFragment();
    String(text || '').split(/\n{2,}/).forEach(function (block) {
      const p = el('p', 'el-doc-paragraph');
      block.split('\n').forEach(function (line, i) {
        if (i > 0) p.appendChild(document.createElement('br'));
        p.appendChild(document.createTextNode(line));
      });
      frag.appendChild(p);
    });
    return frag;
  }

  function metaGrid(entries, columns) {
    const grid = el('dl', 'el-doc-meta' + (columns === 1 ? ' el-doc-meta-single' : ''));
    entries.forEach(function (entry) {
      const item = el('div', 'el-doc-meta-item');
      item.appendChild(el('dt', null, entry.label));
      item.appendChild(el('dd', null, entry.value));
      grid.appendChild(item);
    });
    return grid;
  }

  function bodySections(entries, withHeadings) {
    const frag = document.createDocumentFragment();
    entries.forEach(function (entry) {
      const section = el('section', 'el-doc-section');
      if (withHeadings) section.appendChild(el('h4', 'el-doc-section-title', entry.label));
      section.appendChild(paragraphs(entry.value));
      frag.appendChild(section);
    });
    return frag;
  }

  function reference(model) {
    return model.pending ? 'Assigned on save' : model.id;
  }

  function signature(issuer, caption) {
    const block = el('div', 'el-doc-signature');
    if (!issuer) return block;
    block.appendChild(el('div', 'el-doc-signature-script', issuer.name));
    block.appendChild(el('div', 'el-doc-signature-line'));
    block.appendChild(el('div', 'el-doc-signature-name', issuer.name));
    if (issuer.position) block.appendChild(el('div', 'el-doc-signature-role', issuer.position));
    if (caption) block.appendChild(el('div', 'el-doc-signature-role', caption));
    return block;
  }

  function seal(model) {
    const org = model.organization;
    const node = el('div', 'el-doc-seal');
    node.appendChild(icon((org && org.icon) || model.icon || 'fa-stamp'));
    node.appendChild(el('span', null, (org && org.short) || 'OFFICIAL'));
    return node;
  }

  function stamp(model) {
    if (model.status !== 'revoked' && model.status !== 'expired') return null;
    return el('div', 'el-doc-stamp', model.status === 'revoked' ? 'Revoked' : 'Expired');
  }

  function footer(model) {
    const foot = el('footer', 'el-doc-footer');
    foot.appendChild(el('span', null, 'Ref ' + reference(model)));
    foot.appendChild(el('span', null, model.typeLabel));
    foot.appendChild(el('span', null, 'Printed on Empire Line'));
    return foot;
  }

  function letterhead(model, fallbackIcon) {
    const head = el('header', 'el-doc-letterhead');
    head.appendChild(emblem(model.organization, fallbackIcon || model.icon));
    const text = el('div', 'el-doc-letterhead-text');
    text.appendChild(el('div', 'el-doc-org', model.organization ? model.organization.label : model.typeLabel));
    if (model.organization && model.organization.short) {
      text.appendChild(el('div', 'el-doc-org-short', model.organization.short));
    }
    head.appendChild(text);
    const refBox = el('div', 'el-doc-refbox');
    refBox.appendChild(el('div', 'el-doc-ref-label', 'Reference'));
    refBox.appendChild(el('div', 'el-doc-ref-value', reference(model)));
    refBox.appendChild(el('div', 'el-doc-ref-label', 'Issued'));
    refBox.appendChild(el('div', 'el-doc-ref-value', model.issuedAt || '-'));
    head.appendChild(refBox);
    return head;
  }

  function recipientEntries(model) {
    const r = model.recipient;
    if (!r) return [];
    return [{ label: 'Recipient', value: r.name + (r.citizenid ? ' (' + r.citizenid + ')' : '') }];
  }

  /* ---------------------------------------------------------------- layouts */

  const layouts = {
    letter: function (model, doc) {
      doc.classList.add('el-doc-paper');
      if (model.organization) {
        doc.appendChild(letterhead(model));
      } else {
        const head = el('header', 'el-doc-plainhead');
        head.appendChild(el('span', null, 'Ref ' + reference(model)));
        head.appendChild(el('span', null, model.issuedAt || ''));
        doc.appendChild(head);
      }
      doc.appendChild(el('h2', 'el-doc-title', model.title));
      const meta = recipientEntries(model).concat(model.meta || []);
      if (meta.length) doc.appendChild(metaGrid(meta));
      doc.appendChild(bodySections(model.body || [], (model.body || []).length > 1));
      doc.appendChild(signature(model.issuer));
      doc.appendChild(footer(model));
    },

    official: function (model, doc) {
      doc.classList.add('el-doc-paper', 'el-doc-official');
      doc.appendChild(letterhead(model, 'fa-landmark'));
      doc.appendChild(el('div', 'el-doc-rule'));
      doc.appendChild(el('h2', 'el-doc-title', model.title));
      const meta = recipientEntries(model).concat(model.meta || []);
      if (meta.length) doc.appendChild(metaGrid(meta));
      doc.appendChild(bodySections(model.body || [], (model.body || []).length > 1));
      const sign = el('div', 'el-doc-signrow');
      sign.appendChild(signature(model.issuer, 'Authorized Signatory'));
      sign.appendChild(seal(model));
      doc.appendChild(sign);
      doc.appendChild(footer(model));
    },

    report: function (model, doc) {
      doc.classList.add('el-doc-paper', 'el-doc-report');
      const band = el('header', 'el-doc-band');
      band.appendChild(emblem(model.organization, model.icon));
      const text = el('div', 'el-doc-band-text');
      text.appendChild(el('div', 'el-doc-org', model.organization ? model.organization.label : model.typeLabel));
      text.appendChild(el('div', 'el-doc-band-title', model.title));
      band.appendChild(text);
      const caseBox = el('div', 'el-doc-refbox');
      caseBox.appendChild(el('div', 'el-doc-ref-label', 'Case No.'));
      caseBox.appendChild(el('div', 'el-doc-ref-value', reference(model)));
      band.appendChild(caseBox);
      doc.appendChild(band);

      const meta = [{ label: 'Filed', value: model.issuedAt || '-' }]
        .concat(recipientEntries(model))
        .concat(model.meta || []);
      if (model.issuer) meta.push({ label: 'Reporting Officer', value: model.issuer.name });
      doc.appendChild(metaGrid(meta));
      doc.appendChild(bodySections(model.body || [], true));
      doc.appendChild(signature(model.issuer, 'Certified true and correct'));
      doc.appendChild(footer(model));
    },

    invoice: function (model, doc) {
      doc.classList.add('el-doc-paper', 'el-doc-invoice');
      const inv = model.invoice || {};
      const head = el('header', 'el-doc-invoice-head');
      const from = el('div', 'el-doc-invoice-from');
      from.appendChild(emblem(model.organization, 'fa-building'));
      const fromText = el('div');
      fromText.appendChild(el('div', 'el-doc-org', model.organization ? model.organization.label : (model.issuer ? model.issuer.name : 'Invoice')));
      if (model.issuer) fromText.appendChild(el('div', 'el-doc-org-short', 'Issued by ' + model.issuer.name));
      from.appendChild(fromText);
      head.appendChild(from);
      const titleBox = el('div', 'el-doc-invoice-titlebox');
      titleBox.appendChild(el('div', 'el-doc-invoice-word', 'Invoice'));
      titleBox.appendChild(el('div', 'el-doc-ref-value', reference(model)));
      head.appendChild(titleBox);
      doc.appendChild(head);

      const parties = el('div', 'el-doc-invoice-parties');
      const billTo = el('div');
      billTo.appendChild(el('div', 'el-doc-ref-label', 'Bill To'));
      billTo.appendChild(el('div', 'el-doc-invoice-strong', inv.billTo || '-'));
      parties.appendChild(billTo);
      const dates = el('div', 'el-doc-invoice-dates');
      dates.appendChild(el('div', 'el-doc-ref-label', 'Issue Date'));
      dates.appendChild(el('div', 'el-doc-invoice-strong', model.issuedAt || '-'));
      if (inv.dueDate) {
        dates.appendChild(el('div', 'el-doc-ref-label', 'Due Date'));
        dates.appendChild(el('div', 'el-doc-invoice-strong', inv.dueDate));
      }
      parties.appendChild(dates);
      doc.appendChild(parties);

      const table = el('table', 'el-doc-table');
      const thead = el('thead');
      const hr = el('tr');
      ['Description', 'Qty', 'Unit Price', 'Amount'].forEach(function (h) { hr.appendChild(el('th', null, h)); });
      thead.appendChild(hr);
      table.appendChild(thead);
      const tbody = el('tbody');
      const row = el('tr');
      row.appendChild(el('td', null, inv.description || '-'));
      row.appendChild(el('td', null, inv.quantity));
      row.appendChild(el('td', null, inv.unitPrice));
      row.appendChild(el('td', null, inv.subtotal));
      tbody.appendChild(row);
      table.appendChild(tbody);
      doc.appendChild(table);

      const totals = el('div', 'el-doc-totals');
      function totalRow(label, value, strong) {
        const r = el('div', 'el-doc-total-row' + (strong ? ' el-doc-total-strong' : ''));
        r.appendChild(el('span', null, label));
        r.appendChild(el('span', null, value));
        totals.appendChild(r);
      }
      totalRow('Subtotal', inv.subtotal);
      if (inv.taxPercent) totalRow('Tax (' + inv.taxPercent + '%)', inv.tax);
      totalRow('Total Due', inv.total, true);
      doc.appendChild(totals);

      if ((model.meta || []).length) doc.appendChild(metaGrid(model.meta));
      doc.appendChild(bodySections(model.body || [], true));
      doc.appendChild(footer(model));
    },

    contract: function (model, doc) {
      doc.classList.add('el-doc-paper', 'el-doc-contract');
      if (model.organization) doc.appendChild(letterhead(model, 'fa-file-signature'));
      doc.appendChild(el('h2', 'el-doc-title el-doc-title-center', model.title));
      const partyA = model.issuer ? model.issuer.name : 'First Party';
      const partyB = model.recipient ? model.recipient.name : 'Second Party';
      const intro = el('p', 'el-doc-paragraph el-doc-intro');
      intro.textContent = 'This agreement is entered into on ' + (model.issuedAt || 'the date of issue') +
        ' between ' + partyA + ' ("First Party") and ' + partyB + ' ("Second Party").';
      doc.appendChild(intro);
      if ((model.meta || []).length) doc.appendChild(metaGrid(model.meta));
      doc.appendChild(bodySections(model.body || [], true));
      const signs = el('div', 'el-doc-signrow el-doc-signrow-split');
      signs.appendChild(signature(model.issuer, 'First Party'));
      const second = el('div', 'el-doc-signature');
      second.appendChild(el('div', 'el-doc-signature-script el-doc-signature-blank', ''));
      second.appendChild(el('div', 'el-doc-signature-line'));
      second.appendChild(el('div', 'el-doc-signature-name', partyB));
      second.appendChild(el('div', 'el-doc-signature-role', 'Second Party'));
      signs.appendChild(second);
      doc.appendChild(signs);
      doc.appendChild(footer(model));
    },

    license: function (model, doc) {
      doc.classList.add('el-doc-card');
      const r = model.recipient || {};
      const head = el('header', 'el-card-head');
      head.appendChild(emblem(model.organization, model.icon));
      const headText = el('div', 'el-card-head-text');
      headText.appendChild(el('div', 'el-card-org', model.organization ? model.organization.label : 'State of San Andreas'));
      headText.appendChild(el('div', 'el-card-title', model.title));
      head.appendChild(headText);
      doc.appendChild(head);

      const body = el('div', 'el-card-body');
      const photo = el('div', 'el-card-photo');
      photo.appendChild(icon('fa-user'));
      body.appendChild(photo);

      const fields = el('div', 'el-card-fields');
      function cardField(label, value, wide) {
        if (value === undefined || value === null || value === '') return;
        const f = el('div', 'el-card-field' + (wide ? ' el-card-field-wide' : ''));
        f.appendChild(el('span', 'el-card-label', label));
        f.appendChild(el('span', 'el-card-value', value));
        fields.appendChild(f);
      }
      cardField('Name', r.name, true);
      cardField('ID No.', r.citizenid);
      cardField('Date of Birth', r.birthdate);
      cardField('Sex', r.gender);
      cardField('Nationality', r.nationality);
      (model.meta || []).forEach(function (m) { cardField(m.label, m.value, String(m.value).length > 18); });
      cardField('Issued', model.issuedAt);
      cardField('Expires', model.expiresAt || 'No expiry');
      body.appendChild(fields);
      doc.appendChild(body);

      const foot = el('footer', 'el-card-foot');
      foot.appendChild(el('span', 'el-card-ref', reference(model)));
      if (model.issuer) {
        const sig = el('span', 'el-card-sign');
        sig.appendChild(el('span', 'el-card-label', 'Issued by'));
        sig.appendChild(el('span', 'el-card-value', model.issuer.name));
        foot.appendChild(sig);
      }
      doc.appendChild(foot);
      if ((model.body || []).length) {
        const notes = el('div', 'el-card-notes');
        notes.appendChild(bodySections(model.body, true));
        doc.appendChild(notes);
      }
    },
  };

  function renderDocument(model) {
    const doc = el('article', 'el-doc el-doc-layout-' + (model.layout || 'letter'));
    const layout = layouts[model.layout] || layouts.letter;
    layout(model, doc);
    const mark = stamp(model);
    if (mark) doc.appendChild(mark);
    if (model.pending) doc.appendChild(el('div', 'el-doc-preview-mark', 'Preview'));
    return doc;
  }

  /* Scales a fixed-width document to fit its frame without reflowing it. */
  function fitDocument(frame) {
    const doc = frame.querySelector('.el-doc');
    if (!doc) return;
    const natural = doc.offsetWidth;
    if (!natural) return;
    const available = frame.clientWidth - 24;
    const scale = Math.min(1, available / natural);
    doc.style.transform = 'scale(' + scale + ')';
    frame.style.setProperty('--el-doc-height', Math.ceil(doc.offsetHeight * scale) + 'px');
  }

  function mount(frame, model) {
    frame.textContent = '';
    if (!model) return;
    const holder = el('div', 'el-doc-holder');
    holder.appendChild(renderDocument(model));
    frame.appendChild(holder);
    requestAnimationFrame(function () { fitDocument(frame); });
    if (!frame.__elObserver && window.ResizeObserver) {
      frame.__elObserver = new ResizeObserver(function () { fitDocument(frame); });
      frame.__elObserver.observe(frame);
    }
  }

  window.ElRender = { renderDocument: renderDocument, mount: mount, fit: fitDocument };
})();
