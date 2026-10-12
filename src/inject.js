/*
 * KerneLUA Steam-UI script — Linux port of the JS embedded in
 * kernelua_backend.exe (recovered from the binary's string table).
 *
 * Injected into every steamloopback.host page via
 * Page.addScriptToEvaluateOnNewDocument. RPC goes through the CDP
 * Runtime.addBinding channel instead of the Windows in-process hook:
 *
 *   JS  -> window.__kernelua_call(JSON.stringify({id, method, params}))
 *   CDP -> backend "Runtime.bindingCalled"
 *   backend -> Runtime.evaluate("window.__kernelua_dispatch(id, resultJson)")
 */

(function () {
  'use strict';
  if (window.__kernelua_loaded) return;
  window.__kernelua_loaded = true;

  var state = {
    run: { inProgress: false, appid: null, status: 'idle', error: null },
    cache: new Map(),
    logs: {},
    timer: null
  };

  // ------------------------------------------------------------- RPC

  var rpcSeq = 0;
  var rpcWaiters = new Map();

  window.__kernelua_dispatch = function (id, resultJson) {
    var w = rpcWaiters.get(id);
    if (!w) return;
    rpcWaiters.delete(id);
    try {
      w.resolve(typeof resultJson === 'string' ? JSON.parse(resultJson) : resultJson);
    } catch (e) {
      w.reject(e);
    }
  };

  function rpc(method, params) {
    return new Promise(function (resolve, reject) {
      if (typeof window.__kernelua_call !== 'function') {
        reject(new Error('rpc bridge not ready'));
        return;
      }
      var id = ++rpcSeq;
      rpcWaiters.set(id, { resolve: resolve, reject: reject });
      window.__kernelua_call(JSON.stringify({ id: id, method: method, params: params || {} }));
      setTimeout(function () {
        if (rpcWaiters.has(id)) {
          rpcWaiters.delete(id);
          reject(new Error('rpc timeout'));
        }
      }, 60000);
    });
  }

  // ------------------------------------------------------------- styles

  var CSS = [
    '.kernelua-overlay { position: fixed; inset: 0; background: rgba(0,0,0,.85);',
    '  backdrop-filter: blur(2px); z-index: 99999; display:flex; align-items:center;',
    '  justify-content:center; animation: kerneluaFadeIn .4s ease-out; }',
    '.kernelua-modal { background:#23262E; border:1px solid #3D4450; box-shadow:0 0 20px rgba(0,0,0,.8);',
    '  font-family:"Motiva Sans", Arial, sans-serif; width:min(90vw,500px); max-height:80vh;',
    '  position:relative; border-radius:8px; overflow:hidden; display:flex; flex-direction:column;',
    '  animation: kerneluaSlideIn .4s ease-out; }',
    '.kernelua-header { background: linear-gradient(135deg, #2D3139 0%, #1E2024 100%);',
    '  border-bottom:1px solid #3D4450; padding:12px 16px; display:flex; align-items:center;',
    '  justify-content:space-between; }',
    '.kernelua-title { color:#C6D4DF; font-size:14px; white-space:nowrap; overflow:hidden;',
    '  text-overflow:ellipsis; max-width:360px; }',
    '.kernelua-close { color:#8F98A0; cursor:pointer; font-size:16px; padding:4px; }',
    '.kernelua-close:hover { color:#fff; }',
    '.kernelua-content { padding:16px 20px 20px 20px; flex:1; overflow-y:auto; color:#C6D4DF; font-size:13px; }',
    '.kernelua-footer { padding:9px 20px; border-top:1px solid #3D4450; font-size:11px; color:#8F98A0;',
    '  text-align:center; background:rgba(0,0,0,.25); }',
    '.kernelua-footer a { color:#6bb5d6; text-decoration:none; }',
    '.kernelua-btn { border-radius:3px; cursor:pointer; font-size:12px; font-weight:500; padding:8px 16px;',
    '  margin:4px; min-width:80px; text-align:center; display:inline-block; border:1px solid transparent;',
    '  transition: all .2s; }',
    '.kernelua-btn-primary { background:#1976D2; border-color:#1976D2; color:#fff; }',
    '.kernelua-btn-primary:hover { background:#1E88E5; }',
    '.kernelua-btn-secondary { background:#1e2329; border-color:#3D4450; color:#8F98A0; }',
    '.kernelua-btn-secondary:hover { background:#2a2d31; }',
    '.kernelua-progress { background:#3D4450; height:16px; border-radius:4px; overflow:hidden; margin-bottom:12px;',
    '  display:none; }',
    '.kernelua-progress-bar { height:100%; width:0%; background:#1976D2; transition: width .3s; }',
    '.kernelua-status { font-size:13px; line-height:1.4; margin-bottom:12px; color:#C6D4DF; min-height:18px; }',
    '.kernelua-token-input { width:100%; padding:8px 10px; border-radius:6px; border:1px solid #3D4450;',
    '  background:rgba(255,255,255,.05); color:#C6D4DF; font-size:13px; box-sizing:border-box;',
    '  margin:8px 0 4px 0; outline:none; }',
    '.kernelua-token-input:focus { border-color:#495a6b; }',
    '.kernelua-token-error { color:#f44336; font-size:12px; margin-top:6px; display:none; }',
    '.kernelua-token-link { color:#6bb5d6; font-size:12px; text-decoration:none; }',
    '.kernelua-compat-badge { display:inline-flex; align-items:center; gap:8px; font-size:13px;',
    '  padding:4px 10px; border-radius:12px; background:rgba(0,0,0,.3); border:1px solid rgba(255,255,255,.12); }',
    '.kernelua-compat-dot { width:9px; height:9px; border-radius:50%; background:#888; }',
    '.kernelua-button-container { margin:6px 0; }',
    '#kernelua-in-library-banner { margin:8px 0; }',
    '@keyframes kerneluaFadeIn { from { opacity: 0; } to { opacity: 1; } }',
    '@keyframes kerneluaSlideIn { from { transform: translateY(12px); opacity: 0; } to { transform: none; opacity: 1; } }'
  ].join('\n');

  function ensureStyles() {
    if (document.getElementById('kernelua-styles')) return;
    var style = document.createElement('style');
    style.id = 'kernelua-styles';
    style.textContent = CSS;
    document.head.appendChild(style);
  }

  // ------------------------------------------------------------- modal

  function createModal(title) {
    ensureStyles();
    var overlay = document.createElement('div');
    overlay.className = 'kernelua-overlay';
    var modal = document.createElement('div');
    modal.className = 'kernelua-modal';

    var header = document.createElement('div');
    header.className = 'kernelua-header';
    var titleEl = document.createElement('div');
    titleEl.className = 'kernelua-title';
    titleEl.textContent = title;
    var close = document.createElement('div');
    close.className = 'kernelua-close';
    close.textContent = '\u2715';
    close.addEventListener('click', function () { overlay.remove(); });
    header.appendChild(titleEl);
    header.appendChild(close);

    var content = document.createElement('div');
    content.className = 'kernelua-content';

    var footer = document.createElement('div');
    footer.className = 'kernelua-footer';
    footer.innerHTML = 'KerneLua is free. If you paid for it, you were scammed. ' +
      '<a href="https://kernelos.org/games" target="_blank" rel="noopener">kernelos.org/games</a>';

    modal.appendChild(header);
    modal.appendChild(content);
    modal.appendChild(footer);
    overlay.appendChild(modal);
    document.body.appendChild(overlay);
    return { overlay: overlay, content: content, title: titleEl };
  }

  function createButton(label, className, onClick) {
    var btn = document.createElement('div');
    btn.className = 'kernelua-btn ' + className;
    btn.textContent = label;
    if (onClick) btn.addEventListener('click', onClick);
    return btn;
  }

  // ------------------------------------------------------------- appid

  function getCurrentAppId() {
    try {
      if (typeof SteamClient !== 'undefined' &&
          typeof SteamClient.Apps?.GetForegroundApp === 'function') {
        var id = SteamClient.Apps.GetForegroundApp();
        if (id > 0) return id;
      }
    } catch (e) { /* fall through */ }
    var d = document.querySelector('[data-appid]');
    if (d) {
      var v = parseInt(d.getAttribute('data-appid'), 10);
      if (v > 0) return v;
    }
    return null;
  }

  // ------------------------------------------------------------- compat

  function kerneluaAnalyzeCompat() {
    var tags = [], specs = [], notices = [], reasons = [];
    try {
      document.querySelectorAll('.glance_tags .app_tag, [data-bbcodetag]').forEach(function (el) {
        var t = (el.textContent || '').trim();
        if (t) tags.push(t);
      });
      document.querySelectorAll('.game_page_autocollapse sys_req, .game_page_details .block_content')
        .forEach(function (el) {
          var t = (el.textContent || '').trim();
          if (t) specs.push(t.slice(0, 200));
        });
      var notice = document.querySelector('.game_area_details_specs, .DRM_notice');
      if (notice) notices.push(notice.textContent.trim());
    } catch (e) { /* DOM shape varies across client builds */ }

    if (/third[- ]party account|third party account/i.test(notices.join(' ') + ' ' + specs.join(' '))) {
      reasons.push('Requires a third-party account (license verification may fail; bypass may be required).');
    }
    var ok = reasons.length === 0;
    return {
      ok: ok,
      dot: ok ? '#4caf50' : '#ff9800',
      title: ok ? 'Compatible' : reasons.join(' '),
      reasons: reasons
    };
  }

  function kerneluaMakeBadge(info) {
    if (document.querySelector('.kernelua-compat-wrap')) return;
    var container = document.querySelector('.game_area_description') ||
                    document.querySelector('#game_area_description') ||
                    document.body;
    if (!container) return;

    var wrap = document.createElement('div');
    wrap.className = 'kernelua-compat-wrap';
    var badge = document.createElement('div');
    badge.className = 'kernelua-compat-badge';
    if (info.title) badge.title = info.title;
    var dot = document.createElement('div');
    dot.className = 'kernelua-compat-dot';
    dot.style.background = info.dot;
    var label = document.createElement('span');
    label.textContent = 'KerneLua';
    badge.appendChild(dot);
    badge.appendChild(label);
    wrap.appendChild(badge);
    container.appendChild(wrap);
  }

  // ------------------------------------------------------------- progress

  function startProgressMonitoring(appId) {
    if (state.timer) clearInterval(state.timer);
    state.timer = setInterval(function () {
      rpc('GetStatus', { appid: appId }).then(function (st) {
        var overlay = document.querySelector('.kernelua-overlay');
        var bar = overlay && overlay.querySelector('.kernelua-progress-bar');
        var status = overlay && overlay.querySelector('.kernelua-status');
        if (!st || !st.status) return;
        if (status) status.textContent = st.status === 'extracting' ? 'Extracting LUA' :
                                        st.status === 'downloading' ? 'Downloading' :
                                        st.status === 'applying' ? 'Applying' :
                                        st.status === 'done' ? 'Done' :
                                        (st.error || 'Working');
        if (bar) {
          var pct = st.status === 'done' ? 100 :
                    st.status === 'downloading' ? 30 :
                    st.status === 'extracting' ? 60 :
                    st.status === 'applying' ? 85 : 10;
          bar.style.width = pct + '%';
        }
        if (st.status === 'failed' || st.status === 'done') {
          clearInterval(state.timer);
          state.timer = null;
          state.run.inProgress = false;
          state.cache.delete('appExists_' + appId);
          if (st.status === 'done') {
            setTimeout(function () { overlay && overlay.remove(); addKerneluaButton(); }, 800);
          }
        }
      }).catch(function () { /* transient */ });
    }, 1000);
  }

  // ------------------------------------------------------------- token modal

  function showActivateModal(onDone) {
    var m = createModal('KerneLua - Activate Plugin');
    var desc = document.createElement('div');
    desc.style.cssText = 'font-size:13px;color:#8F98A0;margin:0 0 2px 0;line-height:1.5;';
    desc.innerHTML = 'Get your free token at: <a class="kernelua-token-link" ' +
      'href="https://kernelos.org/games/auth" target="_blank" rel="noopener">kernelos.org/games/auth</a>';
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'kernelua-token-input';
    input.placeholder = 'Paste your token';
    var errMsg = document.createElement('div');
    errMsg.className = 'kernelua-token-error';
    var activateBtn = createButton('Activate', 'kernelua-btn-primary', function () {
      rpc('saveToken', { token: input.value }).then(function (r) {
        if (r && r.success) {
          m.overlay.remove();
          if (onDone) onDone();
        } else {
          errMsg.textContent = (r && r.error) || 'Invalid token.';
          errMsg.style.display = 'block';
        }
      }).catch(function () {
        errMsg.textContent = 'Error saving token. Try again.';
        errMsg.style.display = 'block';
      });
    });
    var cancelBtn = createButton('Cancel', 'kernelua-btn-secondary', function () { m.overlay.remove(); });
    m.content.appendChild(desc);
    m.content.appendChild(input);
    m.content.appendChild(errMsg);
    m.content.appendChild(activateBtn);
    m.content.appendChild(cancelBtn);
  }

  // ------------------------------------------------------------- buttons

  function createAndInjectButton(appId) {
    if (document.querySelector('.kernelua-button-container')) return;
    var container = document.querySelector('.game_area_purchase_game') ||
                    document.querySelector('.game_area_purchase') ||
                    document.querySelector('#game_area_purchase');
    if (!container) return;

    var btnContainer = document.createElement('div');
    btnContainer.className = 'btn_addtocart btn_packageinfo kernelua-button-container';
    btnContainer.dataset.kerneluaKind = 'add';
    var button = document.createElement('div');
    button.className = 'btn_blue_steamui btn_medium';
    button.textContent = 'Add via KerneLua';
    button.style.marginLeft = '2px';
    button.addEventListener('click', function () {
      ensureTokenThen(function () {
        var m = createModal('KerneLua - Working');
        var progress = document.createElement('div');
        progress.className = 'kernelua-progress';
        progress.style.display = 'block';
        var bar = document.createElement('div');
        bar.className = 'kernelua-progress-bar';
        progress.appendChild(bar);
        var status = document.createElement('div');
        status.className = 'kernelua-status';
        status.textContent = 'Working';
        var cancelBtn = createButton('Close', 'kernelua-btn-secondary', function () { m.overlay.remove(); });
        m.content.appendChild(status);
        m.content.appendChild(progress);
        m.content.appendChild(cancelBtn);

        rpc('addViaKernelua', { appid: appId }).then(function (r) {
          if (r && r.success) {
            status.textContent = 'Done';
            bar.style.width = '100%';
            state.cache.set('appExists_' + appId, true);
            setTimeout(function () { m.overlay.remove(); addKerneluaButton(); }, 800);
          } else {
            var errText = (r && r.error) || 'Unknown error';
            status.textContent = 'Error: ' + errText;
            if (/401|403|token|unauthorized|forbidden/i.test(errText)) {
              showActivateModal(function () { addKerneluaButton(); });
            }
          }
          startProgressMonitoring(appId);
        }).catch(function (e) {
          status.textContent = 'Error: ' + (e && e.message ? e.message : e);
        });
      });
    });
    btnContainer.appendChild(button);
    container.appendChild(btnContainer);
  }

  function createRemoveButton(appId) {
    if (document.querySelector('.kernelua-button-container')) return;
    var container = document.querySelector('.game_area_purchase_game') ||
                    document.querySelector('.game_area_purchase') ||
                    document.querySelector('#game_area_purchase');
    if (!container) return;

    var btnContainer = document.createElement('div');
    btnContainer.className = 'btn_addtocart btn_packageinfo kernelua-button-container';
    btnContainer.dataset.kerneluaKind = 'remove';
    var button = document.createElement('div');
    button.className = 'btn_blue_steamui btn_medium';
    button.textContent = 'Remove via KerneLua';
    button.style.marginLeft = '2px';
    button.addEventListener('click', function () {
      rpc('RemoveViaKernelua', { appid: appId }).then(function (r) {
        if (r && r.success) {
          state.cache.delete('appExists_' + appId);
        }
        addKerneluaButton();
      }).catch(function () { addKerneluaButton(); });
    });
    btnContainer.appendChild(button);
    container.appendChild(btnContainer);
  }

  function showLibraryBanners() {
    if (document.querySelector('#kernelua-in-library-banner')) return;
    var container = document.querySelector('.game_area_purchase_game') ||
                    document.querySelector('.game_area_purchase') ||
                    document.body;
    var name = (document.querySelector('.apphub_AppName') || {}).textContent || 'This game';
    var msg = document.createElement('div');
    msg.id = 'kernelua-in-library-banner';
    msg.className = 'already_in_library';
    msg.textContent = name.trim() + ' is already in your Steam library';
    container.appendChild(msg);
  }

  function ensureTokenThen(fn) {
    rpc('getToken').then(function (r) {
      if (r && r.hasToken) fn();
      else showActivateModal(fn);
    }).catch(function () { showActivateModal(fn); });
  }

  function addKerneluaButton() {
    var appId = getCurrentAppId();
    if (!appId) {
      if (!state.logs.missingOnce) {
        state.logs.missingOnce = true;
        console.log('[kernelua] no appid on this page');
      }
      return;
    }
    var key = 'appExists_' + appId;
    var cached = state.cache.get(key);

    function render(exists) {
      state.cache.set(key, exists);
      document.querySelector('.kernelua-button-container')?.remove();
      if (exists === true) {
        createRemoveButton(appId);
        showLibraryBanners();
      } else {
        createAndInjectButton(appId);
      }
    }

    if (cached !== undefined) {
      render(cached);
      return;
    }
    rpc('hasLuaForApp', { appid: appId }).then(function (r) {
      render(!!(r && r.exists));
    }).catch(function () { render(false); });
  }

  function initKernelua() {
    ensureStyles();
    try {
      var info = kerneluaAnalyzeCompat();
      kerneluaMakeBadge(info);
    } catch (e) { /* non-fatal */ }
    setTimeout(addKerneluaButton, 100);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initKernelua);
  } else {
    initKernelua();
  }
})();
