/*
 * Printer UI
 * NUI contract (unchanged from the original UI):
 *   messages in : { action: 'start' }            -> open the printer form
 *                 { action: 'open', url }        -> show a printed document
 *                 { action: 'close' }            -> hide everything
 *   callbacks   : PrintDocument { url, name, amount, width, height }
 *                 CloseDocument
 *   Name and URL are validated inline, so Invalid / EmptyName are no longer sent.
 */

var UI = {};

(function () {
  var MAX_COPIES = 50;
  var FALLBACK_SIZE = { width: 1920, height: 1080 };

  var $ = function (id) { return document.getElementById(id); };
  var printer = $('el-printer');
  var viewer = $('el-viewer');
  var form = $('el-form');
  var nameInput = $('filename');
  var urlInput = $('fileurl');
  var copiesInput = $('amountpapers');
  var preview = $('el-preview');
  var previewImg = $('el-preview-img');
  var previewSize = $('el-preview-size');

  var resourceName = typeof GetParentResourceName === 'function' ? GetParentResourceName() : null;
  var previewToken = 0;
  var previewTimer = null;

  function post(name, data) {
    if (!resourceName) return; // opened in a regular browser
    fetch('https://' + resourceName + '/' + name, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    }).catch(function () {});
  }

  function show(el) { el.classList.add('el-visible'); }
  function hide(el) { el.classList.remove('el-visible'); }
  function isOpen(el) { return el.classList.contains('el-visible'); }

  function isValidHttpUrl(value) {
    try {
      var url = new URL(value);
      return url.protocol === 'http:' || url.protocol === 'https:';
    } catch (_) {
      return false;
    }
  }

  function loadImage(url) {
    return new Promise(function (resolve, reject) {
      var img = new Image();
      img.onload = function () { resolve(img); };
      img.onerror = reject;
      img.src = url;
    });
  }

  function imageSize(url) {
    return loadImage(url)
      .then(function (img) { return { width: img.naturalWidth, height: img.naturalHeight }; })
      .catch(function () { return FALLBACK_SIZE; });
  }

  // ---------------------------------------------------------------- form state

  function setInvalid(fieldId, invalid) {
    $(fieldId).classList.toggle('el-invalid', invalid);
  }

  function updateNameCount() {
    $('el-name-count').textContent = nameInput.value.length + '/' + nameInput.maxLength;
  }

  function clampCopies(value) {
    var n = parseInt(value, 10);
    if (isNaN(n) || n < 1) n = 1;
    return Math.min(n, MAX_COPIES);
  }

  function setCopies(value) {
    var n = clampCopies(value);
    copiesInput.value = n;
    $('el-copies-minus').disabled = n <= 1;
    $('el-copies-plus').disabled = n >= MAX_COPIES;
  }

  function setPreview(state) { preview.dataset.state = state; }

  function refreshPreview() {
    var url = urlInput.value.trim();
    var token = ++previewToken;
    if (!url) { setPreview('empty'); return; }
    if (!isValidHttpUrl(url)) { setPreview('error'); return; }
    setPreview('loading');
    loadImage(url).then(function (img) {
      if (token !== previewToken) return;
      previewImg.src = url;
      previewSize.textContent = img.naturalWidth + ' × ' + img.naturalHeight;
      setPreview('ready');
    }).catch(function () {
      if (token === previewToken) setPreview('error');
    });
  }

  function resetForm() {
    urlInput.value = '';
    previewToken++;
    previewImg.removeAttribute('src');
    setPreview('empty');
    setInvalid('el-field-name', false);
    setInvalid('el-field-url', false);
    setCopies(copiesInput.value);
    updateNameCount();
  }

  // ---------------------------------------------------------------- public API

  UI.Start = function () {
    hide(viewer);
    resetForm();
    show(printer);
    setTimeout(function () { (nameInput.value ? urlInput : nameInput).focus(); }, 50);
  };

  UI.Open = function (data) {
    if (!data || !data.url) {
      console.log('No document has been linked');
      return;
    }
    $('el-viewer-img').src = data.url;
    show(viewer);
  };

  UI.Close = function () {
    hide(viewer);
    hide(printer);
    post('CloseDocument');
  };

  UI.Print = function () {
    var name = nameInput.value.trim();
    var url = urlInput.value.trim();
    var badName = !name;
    var badUrl = !isValidHttpUrl(url);

    setInvalid('el-field-name', badName);
    setInvalid('el-field-url', badUrl);
    if (badName) { nameInput.focus(); return; }
    if (badUrl) { urlInput.focus(); return; }

    var amount = String(clampCopies(copiesInput.value));
    hide(printer);
    imageSize(url).then(function (size) {
      post('PrintDocument', {
        url: url,
        name: name,
        amount: amount,
        width: size.width,
        height: size.height
      });
    });
  };

  // ---------------------------------------------------------------- events

  form.addEventListener('submit', function (e) { e.preventDefault(); UI.Print(); });
  $('el-printer-close').addEventListener('click', UI.Close);
  $('el-cancel').addEventListener('click', UI.Close);
  $('el-viewer-close').addEventListener('click', UI.Close);

  nameInput.addEventListener('input', function () {
    updateNameCount();
    if (nameInput.value.trim()) setInvalid('el-field-name', false);
  });

  urlInput.addEventListener('input', function () {
    if (isValidHttpUrl(urlInput.value.trim())) setInvalid('el-field-url', false);
    clearTimeout(previewTimer);
    previewTimer = setTimeout(refreshPreview, 350);
  });

  $('el-copies-minus').addEventListener('click', function () { setCopies(clampCopies(copiesInput.value) - 1); });
  $('el-copies-plus').addEventListener('click', function () { setCopies(clampCopies(copiesInput.value) + 1); });
  copiesInput.addEventListener('change', function () { setCopies(copiesInput.value); });

  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && (isOpen(printer) || isOpen(viewer))) UI.Close();
  });

  window.addEventListener('message', function (event) {
    var data = event.data || {};
    switch (data.action) {
      case 'open': UI.Open(data); break;
      case 'start': UI.Start(data); break;
      case 'close': UI.Close(data); break;
    }
  });

  setCopies(1);
  updateNameCount();

  // Browser preview: index.html?demo opens the form, index.html?demo=<image url> opens the viewer.
  if (!resourceName) {
    var demo = new URLSearchParams(location.search).get('demo');
    if (demo) UI.Open({ url: demo });
    else if (demo !== null) UI.Start();
  }
})();
