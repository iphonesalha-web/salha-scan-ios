/* صالحة سكان — ربط صفحة الويب بأدوات آبل الأصلية.
   يُحقن بعد تحميل الصفحة ويستبدل: الماسح، محرك النصوص، المشاركة.
   إن لم تتوفر أداة أصلية يبقى السلوك القديم كما هو. */
(function () {
  'use strict';
  var H = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native;
  if (!H) return;
  function native(msg) { return H.postMessage(msg); }

  var info = native({ cmd: 'info' }).catch(function () { return {}; });
  window.SalhaNative = { available: true, call: native, info: info };

  // يكفي قراءة واحدة بمحرك آبل بدل قراءتين بـ Tesseract
  window.__ocrPsm = ['3'];

  function loadImage(src) {
    return new Promise(function (res, rej) {
      var img = new Image();
      img.onload = function () { res(img); };
      img.onerror = rej;
      img.src = src;
    });
  }

  function toCanvas(src) {
    if (src instanceof HTMLCanvasElement) return Promise.resolve(src);
    if (typeof src === 'string') return loadImage(src).then(toCanvas);
    if (src instanceof Blob) return loadImage(URL.createObjectURL(src)).then(toCanvas);
    var w = src.naturalWidth || src.videoWidth || src.width, h = src.naturalHeight || src.videoHeight || src.height;
    var c = document.createElement('canvas');
    c.width = w; c.height = h;
    c.getContext('2d').drawImage(src, 0, 0);
    return Promise.resolve(c);
  }

  function blobToBase64(blob) {
    return new Promise(function (res, rej) {
      var r = new FileReader();
      r.onload = function () { var s = String(r.result); res(s.slice(s.indexOf(',') + 1)); };
      r.onerror = rej;
      r.readAsDataURL(blob);
    });
  }

  // ------------------------------------------------------------------
  // 1) الماسح: ماسح المستندات من آبل (اكتشاف الحواف والقص تلقائياً)
  // ------------------------------------------------------------------
  var webScanner = window.openCameraScanner;
  if (typeof webScanner === 'function') {
    window.openCameraScanner = async function (merge) {
      var inf = await info;
      if (!inf.scanner) return webScanner(merge);
      var r;
      try { r = await native({ cmd: 'scan' }); } catch (e) { return webScanner(merge); }
      if (!r || r.unsupported) return webScanner(merge);
      var list = r.pages || [];
      if (!list.length) return;
      if (typeof showLoader === 'function') showLoader('جاري تجهيز الصفحات...');
      try {
        var filter = typeof scDefaultFilter === 'function' ? scDefaultFilter() : 'original';
        var pages = [];
        for (var i = 0; i < list.length; i++) {
          var img = await loadImage('data:image/jpeg;base64,' + list[i]);
          var c = await toCanvas(img);
          if (typeof enhanceScan === 'function') { try { c = enhanceScan(c); } catch (e) { } }
          pages.push(createPageObj(c, filter));
        }
        if (typeof hideLoader === 'function') hideLoader();
        await scAddPages(pages, merge === true);
      } catch (e) {
        console.error(e);
        if (typeof hideLoader === 'function') hideLoader();
        if (typeof showToast === 'function') showToast('تعذر تجهيز الصفحات الممسوحة');
      }
    };
  }

  // ------------------------------------------------------------------
  // 2) استخراج النص: محرك آبل (Vision) بدل Tesseract
  //    يعيد نفس شكل نتيجة Tesseract حتى يعمل باقي الكود كما هو
  // ------------------------------------------------------------------
  var webOcr = window.getOcrWorker;
  var LANG = { deu: 'de', ara: 'ar', eng: 'en' };

  function nativeSupports(inf, langs) {
    var have = (inf.ocrLangs || []).map(function (l) { return String(l).toLowerCase().slice(0, 2); });
    var want = String(langs).split('+').map(function (l) { return LANG[l]; }).filter(Boolean);
    if (!want.length) return false;
    // إذا طُلب العربي ومحرك آبل لا يدعمه على هذا الجهاز → نبقى على Tesseract
    if (want.indexOf('ar') >= 0 && have.indexOf('ar') < 0) return false;
    return want.some(function (l) { return have.indexOf(l) >= 0; });
  }

  function makeNativeWorker(langs) {
    return {
      setParameters: function () { return Promise.resolve(); },
      terminate: function () { return Promise.resolve(); },
      recognize: async function (src) {
        var c = await toCanvas(src);
        var scale = 1, send = c;
        var long = Math.max(c.width, c.height);
        if (long > 4000) {
          scale = 4000 / long;
          send = document.createElement('canvas');
          send.width = Math.round(c.width * scale); send.height = Math.round(c.height * scale);
          send.getContext('2d').drawImage(c, 0, 0, send.width, send.height);
        }
        var b64 = send.toDataURL('image/jpeg', 0.92);
        b64 = b64.slice(b64.indexOf(',') + 1);
        if (send !== c) send.width = send.height = 0;
        var r = await native({ cmd: 'ocr', image: b64, langs: langs });
        if (!r || r.unsupported || r.error) throw new Error((r && r.error) || 'native ocr unavailable');
        var k = 1 / scale;
        function bb(o) { return { x0: Math.floor(o.x0 * k), y0: Math.floor(o.y0 * k), x1: Math.ceil(o.x1 * k), y1: Math.ceil(o.y1 * k) }; }
        var lines = (r.lines || []).map(function (l) {
          return {
            text: l.text, confidence: l.conf, bbox: bb(l),
            words: (l.words || []).map(function (w) { return { text: w.text, confidence: w.conf, bbox: bb(w) }; })
          };
        });
        return { data: { text: r.text || '', lines: lines, blocks: [{ paragraphs: [{ lines: lines }] }] } };
      }
    };
  }

  if (typeof webOcr === 'function') {
    window.getOcrWorker = async function (langs) {
      langs = langs || 'deu+ara+eng';
      var inf = await info;
      if (!nativeSupports(inf, langs)) return webOcr(langs);
      var worker = makeNativeWorker(langs);
      // إن فشل محرك آبل لأي سبب نرجع إلى Tesseract تلقائياً
      var nativeRecognize = worker.recognize;
      worker.recognize = async function (src, a, b) {
        try { return await nativeRecognize(src); }
        catch (e) {
          console.warn('native OCR failed, using Tesseract', e);
          var w = await webOcr(langs);
          return w.recognize(src, a, b);
        }
      };
      return worker;
    };
  }

  // ------------------------------------------------------------------
  // 2.5) النسخ الاحتياطي على الـ NAS (FTP) بدل Google Drive
  //      نعيد استخدام قائمة الانتظار والرفع التلقائي الموجودة في التطبيق
  // ------------------------------------------------------------------
  if (typeof window.gdSync === 'function' && typeof window.gdPutPdf === 'function') {
    var nas = { configured: false, folder: '' };
    function nasFiles() { try { return JSON.parse(scLs('nas_files') || '{}') || {}; } catch (e) { return {}; } }

    window.gdClientId = function () { return nas.configured ? 'nas' : ''; };
    window.gdToken = function () { return nas.configured ? 'nas' : ''; };
    window.gdFolder = async function () { return nas.folder || ''; };
    window.gdCopyRedirect = function () { };

    window.gdSignIn = async function () {
      try { nas = (await native({ cmd: 'nasSettings' })) || nas; } catch (e) { }
      nasRelabel();
      gdShowStatus();
      if (nas.configured) setTimeout(gdSync, 500);
    };

    window.gdPutPdf = async function (doc, blob) {
      var map = nasFiles();
      var base = safeFileName(doc.title) || 'مستند';
      var name = base + '.pdf';
      // مستندان بنفس الاسم؟ نضيف جزءاً من رقم المستند حتى لا يستبدل أحدهما الآخر
      var taken = Object.keys(map).some(function (k) { return k !== String(doc.id) && map[k] === name; });
      if (taken) name = base + ' (' + String(doc.id).slice(-4) + ').pdf';
      var b64 = await blobToBase64(blob);
      var r = await native({ cmd: 'nasUpload', name: name, b64: b64, oldName: map[doc.id] || '' });
      if (!r || !r.ok) throw new Error('رفع «' + doc.title + '» إلى الـ NAS فشل: ' + ((r && r.error) || ''));
      map = nasFiles(); map[doc.id] = name; scLs('nas_files', JSON.stringify(map));
    };

    window.gdSaveSettings = function () {
      var a = document.getElementById('gdAuto');
      if (a) scLs('gd_auto', a.checked ? '1' : '0');
      gdShowStatus();
      showToast('تم الحفظ');
    };

    window.gdShowStatus = function () {
      var el = document.getElementById('gdInfo');
      if (!el) return;
      var n = gdPending().size;
      var busy = (typeof gdBusy !== 'undefined') && gdBusy;
      el.textContent = busy ? 'جاري الرفع إلى الـ NAS…'
        : !nas.configured ? 'غير مُعد — اضغط «إعدادات NAS»'
          : (n ? n + ' بانتظار الرفع' : '✅ كل المستندات على الـ NAS') + (nas.folder ? ' · /' + nas.folder : '');
      el.style.color = nas.configured && !n ? '#16a085' : (n ? '#d97706' : '#6b7280');
    };

    window.gdShowSettings = function () {
      var a = document.getElementById('gdAuto');
      if (a) a.checked = gdAuto();
      nasRelabel();
      gdShowStatus();
    };

    // نصوص الواجهة: Google Drive → الـ NAS
    function nasRelabel() {
      var box = document.getElementById('gdClientId');
      var card = box && box.closest('.rounded-3xl');
      if (card) {
        var lbl = box.closest('label'); if (lbl) lbl.style.display = 'none';
        var h = card.querySelector('h3'); if (h) h.textContent = 'النسخ الاحتياطي على الـ NAS';
        var ic = card.querySelector('i.fa-google-drive'); if (ic) { ic.className = 'fa-solid fa-hard-drive'; }
        card.querySelectorAll('button').forEach(function (b) {
          if (b.textContent.trim() === 'ربط') b.textContent = 'إعدادات NAS';
        });
        var red = document.getElementById('gdRedirect');
        var p = red && red.closest('p');
        if (p) p.textContent = 'تُرفع المستندات كملفات PDF إلى مجلدك على قرص الـ FRITZ!Box عبر FTP، داخل شبكة البيت. المستندات المقفولة بكلمة سر لا تُرفع.';
      }
    }

    // كل نص «Google Drive» في التطبيق (قائمة المشاركة، الرسائل) يصير «الـ NAS»
    var webToast = window.showToast;
    if (typeof webToast === 'function') {
      window.showToast = function (m) {
        return webToast.call(this, String(m).replace(/Google Drive/g, 'الـ NAS').replace('☁️', '💾'));
      };
    }
    new MutationObserver(function (list) {
      list.forEach(function (m) {
        m.addedNodes.forEach(function (n) {
          if (n.nodeType !== 1) return;
          var w = document.createTreeWalker(n, NodeFilter.SHOW_TEXT);
          var t; while ((t = w.nextNode())) {
            if (t.nodeValue.indexOf('Google Drive') >= 0) t.nodeValue = t.nodeValue.replace(/Google Drive/g, 'الـ NAS');
          }
        });
      });
    }).observe(document.body, { childList: true, subtree: true });

    native({ cmd: 'nasInfo' }).then(function (r) {
      nas = r || nas;
      gdShowSettings();
      if (nas.configured && gdPending().size) setTimeout(gdSync, 3000);
    }).catch(function () { gdShowSettings(); });
  }

  // ------------------------------------------------------------------
  // 3) المشاركة والحفظ: قائمة المشاركة الأصلية (فيها «حفظ في الملفات»)
  // ------------------------------------------------------------------
  async function nativeShare(data) {
    data = data || {};
    var files = [];
    var list = data.files || [];
    for (var i = 0; i < list.length; i++) {
      files.push({ name: list[i].name || ('file-' + (i + 1)), b64: await blobToBase64(list[i]) });
    }
    var text = [data.text, data.url].filter(Boolean).join('\n');
    var r = await native({ cmd: 'share', files: files, text: text });
    if (!r || !r.completed) {
      var err = new Error('Share canceled');
      err.name = 'AbortError';
      throw err;
    }
  }
  try {
    Object.defineProperty(navigator, 'share', { value: nativeShare, configurable: true, writable: true });
    Object.defineProperty(navigator, 'canShare', { value: function () { return true; }, configurable: true, writable: true });
  } catch (e) { console.warn('share override', e); }

  // تنزيل الملفات (رابط download) يفتح قائمة المشاركة بدل لا شيء
  document.addEventListener('click', function (e) {
    var a = e.target && e.target.closest ? e.target.closest('a[download]') : null;
    if (!a || !a.href) return;
    if (!/^(blob|data):/.test(a.href)) return;
    e.preventDefault();
    var name = a.getAttribute('download') || 'file';
    fetch(a.href).then(function (r) { return r.blob(); }).then(function (b) {
      return nativeShare({ files: [new File([b], name, { type: b.type })] });
    }).catch(function () { });
  }, true);
})();
