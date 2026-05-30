(function () {
  if (window.__verdvanaPostImageLightboxLoaded) {
    return;
  }
  window.__verdvanaPostImageLightboxLoaded = true;

  var lightbox = null;
  var previewImage = null;
  var closeButton = null;

  function injectStyles() {
    if (document.getElementById('verdvana-post-image-lightbox-style')) {
      return;
    }

    var style = document.createElement('style');
    style.id = 'verdvana-post-image-lightbox-style';
    style.textContent = [
      '.post-image-lightbox{position:fixed;inset:0;z-index:2147483647;display:flex;align-items:center;justify-content:center;padding:clamp(18px,4vw,52px);background:rgba(0,0,0,.88);opacity:0;visibility:hidden;pointer-events:none;transition:opacity .18s ease,visibility .18s ease;}',
      '.post-image-lightbox.is-active{opacity:1;visibility:visible;pointer-events:auto;}',
      '.post-image-lightbox img{display:block;max-width:min(100%,1440px);max-height:calc(100vh - clamp(36px,8vw,104px));object-fit:contain;border-radius:14px;border:1px solid rgba(255,255,255,.16);box-shadow:0 28px 90px rgba(0,0,0,.72);cursor:zoom-out;}',
      '.post-image-lightbox-close{position:fixed;top:clamp(14px,3vw,28px);right:clamp(14px,3vw,28px);width:44px;height:44px;border:1px solid rgba(255,255,255,.24);border-radius:50%;background:rgba(255,255,255,.12);color:#fff;cursor:pointer;display:grid;place-items:center;font:24px/1 Arial,sans-serif;}',
      'body.post-image-lightbox-open{overflow:hidden;}',
      'article img,.post-content img,.content img,.markdown-body img{cursor:zoom-in;}'
    ].join('');

    (document.head || document.documentElement).appendChild(style);
  }

  function ensureLightbox() {
    if (lightbox && previewImage) {
      return true;
    }

    if (!document.body) {
      return false;
    }

    injectStyles();

    lightbox = document.createElement('div');
    lightbox.className = 'post-image-lightbox';
    lightbox.setAttribute('role', 'dialog');
    lightbox.setAttribute('aria-modal', 'true');
    lightbox.setAttribute('aria-label', 'Image preview');

    previewImage = document.createElement('img');
    previewImage.alt = '';

    closeButton = document.createElement('button');
    closeButton.className = 'post-image-lightbox-close';
    closeButton.type = 'button';
    closeButton.setAttribute('aria-label', 'Close image preview');
    closeButton.innerHTML = '&times;';

    lightbox.appendChild(previewImage);
    lightbox.appendChild(closeButton);
    document.body.appendChild(lightbox);

    lightbox.addEventListener('click', function (event) {
      if (event.target === lightbox || event.target === closeButton) {
        closeLightbox();
      }
    });

    previewImage.addEventListener('click', function (event) {
      event.stopPropagation();
    });

    return true;
  }

  function isPostContentImage(image) {
    if (!image || image.closest('.post-image-lightbox,a.no-lightbox')) {
      return false;
    }

    if (image.closest('nav,footer,.site-logo-area,.site-modal-content,.page-loader,#wechat-modal')) {
      return false;
    }

    return !!image.closest('article,.post-content,.js-toc-content,.markdown-body,.page-content,.content,main');
  }

  function openLightbox(sourceImage) {
    if (!ensureLightbox()) {
      return;
    }

    var src = sourceImage.currentSrc || sourceImage.getAttribute('src');
    if (!src) {
      return;
    }

    previewImage.alt = sourceImage.alt || '';
    previewImage.src = src;
    lightbox.classList.add('is-active');
    document.body.classList.remove('is-leaving');
    document.body.classList.add('post-image-lightbox-open');

    window.requestAnimationFrame(function () {
      try {
        closeButton.focus({ preventScroll: true });
      } catch (e) {}
    });
  }

  function closeLightbox() {
    if (!lightbox) {
      return;
    }

    lightbox.classList.remove('is-active');
    document.body.classList.remove('post-image-lightbox-open');
    window.setTimeout(function () {
      if (!lightbox.classList.contains('is-active') && previewImage) {
        previewImage.removeAttribute('src');
        previewImage.alt = '';
      }
    }, 180);
  }

  document.addEventListener('click', function (event) {
    var image = event.target.closest && event.target.closest('img');
    if (!isPostContentImage(image)) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    openLightbox(image);
  }, true);

  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && lightbox && lightbox.classList.contains('is-active')) {
      closeLightbox();
    }
  });
}());
