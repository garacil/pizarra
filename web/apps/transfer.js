// Chunked transfer client. It does not trust a download merely because HTTP
// succeeded: the final SHA-256 supplied by the hub must match the bytes rebuilt
// in this browser before a Blob is offered to the operator.
(function () {
  'use strict';

  var api = window.PizarraApi;
  if (!api) { return; }
  var GET_CHUNK = 256 * 1024;
  // 32 KiB raw becomes about 43 KiB after base64, leaving room for the JSON
  // envelope below pzweb's 64 KiB request-body ceiling.
  var PUT_CHUNK = 32 * 1024;
  var MAX_UPLOAD = 10 * 1024 * 1024;
  var state = {targetsLoaded: false, targetsLoading: false, download: null, upload: null};
  var ui = {
    view: document.querySelector('[data-app-view="transfers"]'), notice: document.getElementById('transfer-notice'),
    downloadPath: document.getElementById('download-path'), downloadStart: document.getElementById('download-start'),
    downloadCancel: document.getElementById('download-cancel'), downloadProgress: document.getElementById('download-progress'),
    downloadStatus: document.getElementById('download-status'), uploadTeam: document.getElementById('upload-team'),
    uploadFile: document.getElementById('upload-file'), uploadStart: document.getElementById('upload-start'),
    uploadCancel: document.getElementById('upload-cancel'), uploadProgress: document.getElementById('upload-progress'),
    uploadStatus: document.getElementById('upload-status')
  };

  function own(value, key) { return Object.prototype.hasOwnProperty.call(value, key); }
  function textOption(value, label) {
    var option = document.createElement('option');
    option.value = value;
    option.textContent = label;
    return option;
  }
  function notice(message, error) {
    ui.notice.textContent = message;
    ui.notice.className = 'records-notice' + (error ? ' records-notice--error' : '');
    ui.notice.hidden = false;
  }
  function clearNotice() { ui.notice.hidden = true; }
  function controller() {
    if (typeof AbortController === 'function') { return new AbortController(); }
    return {signal: undefined, abort: function () {}};
  }
  function base64(bytes) {
    var binary = '';
    var size = 0x8000;
    for (var start = 0; start < bytes.length; start += size) {
      binary += String.fromCharCode.apply(null, bytes.subarray(start, Math.min(start + size, bytes.length)));
    }
    return btoa(binary);
  }
  function fromBase64(value) {
    if (typeof value !== 'string') { throw new Error('The chunk does not contain base64 data.'); }
    var binary = atob(value);
    var out = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i += 1) { out[i] = binary.charCodeAt(i); }
    return out;
  }
  function hex(bytes) {
    var result = '';
    for (var i = 0; i < bytes.length; i += 1) { result += bytes[i].toString(16).padStart(2, '0'); }
    return result;
  }
  function rotr(value, amount) { return (value >>> amount) | (value << (32 - amount)); }
  function sha256Fallback(input) {
    var constants = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];
    var bitLength = input.length * 8;
    var paddedLength = input.length + 1;
    while ((paddedLength % 64) !== 56) { paddedLength += 1; }
    var data = new Uint8Array(paddedLength + 8);
    data.set(input);
    data[input.length] = 0x80;
    var highLength = Math.floor(bitLength / 0x100000000) >>> 0;
    var lowLength = bitLength >>> 0;
    data[data.length - 8] = highLength >>> 24;
    data[data.length - 7] = highLength >>> 16;
    data[data.length - 6] = highLength >>> 8;
    data[data.length - 5] = highLength & 255;
    data[data.length - 4] = lowLength >>> 24;
    data[data.length - 3] = lowLength >>> 16;
    data[data.length - 2] = lowLength >>> 8;
    data[data.length - 1] = lowLength & 255;
    var hash = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    var words = new Uint32Array(64);
    for (var offset = 0; offset < data.length; offset += 64) {
      var i;
      for (i = 0; i < 16; i += 1) {
        var j = offset + i * 4;
        words[i] = ((data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | data[j + 3]) >>> 0;
      }
      for (i = 16; i < 64; i += 1) {
        var a0 = rotr(words[i - 15], 7) ^ rotr(words[i - 15], 18) ^ (words[i - 15] >>> 3);
        var a1 = rotr(words[i - 2], 17) ^ rotr(words[i - 2], 19) ^ (words[i - 2] >>> 10);
        words[i] = (words[i - 16] + a0 + words[i - 7] + a1) >>> 0;
      }
      var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4], f = hash[5], g = hash[6], h = hash[7];
      for (i = 0; i < 64; i += 1) {
        var s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        var choose = (e & f) ^ ((~e) & g);
        var first = (h + s1 + choose + constants[i] + words[i]) >>> 0;
        var s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        var majority = (a & b) ^ (a & c) ^ (b & c);
        var second = (s0 + majority) >>> 0;
        h = g; g = f; f = e; e = (d + first) >>> 0; d = c; c = b; b = a; a = (first + second) >>> 0;
      }
      hash[0] = (hash[0] + a) >>> 0; hash[1] = (hash[1] + b) >>> 0;
      hash[2] = (hash[2] + c) >>> 0; hash[3] = (hash[3] + d) >>> 0;
      hash[4] = (hash[4] + e) >>> 0; hash[5] = (hash[5] + f) >>> 0;
      hash[6] = (hash[6] + g) >>> 0; hash[7] = (hash[7] + h) >>> 0;
    }
    var output = new Uint8Array(32);
    for (var n = 0; n < hash.length; n += 1) {
      output[n * 4] = hash[n] >>> 24; output[n * 4 + 1] = hash[n] >>> 16;
      output[n * 4 + 2] = hash[n] >>> 8; output[n * 4 + 3] = hash[n] & 255;
    }
    return output;
  }
  function sha256(bytes) {
    if (window.crypto && window.crypto.subtle) {
      return window.crypto.subtle.digest('SHA-256', bytes).then(function (buffer) { return hex(new Uint8Array(buffer)); });
    }
    return Promise.resolve(hex(sha256Fallback(bytes)));
  }
  function safeName(value) {
    var name = String(value || 'download').replace(/[\\/]/g, '_').replace(/[\u0000-\u001f]/g, '');
    return name || 'download';
  }
  function setDownloadBusy(busy) {
    ui.downloadStart.disabled = busy;
    ui.downloadCancel.hidden = !busy;
    ui.downloadProgress.hidden = !busy;
  }
  function validChunk(data, expectedOffset, expectedSize) {
    if (!api.object(data) || typeof data.name !== 'string' || data.name.length === 0 ||
        !Number.isSafeInteger(data.size) || data.size < 0 || !Number.isSafeInteger(data.offset) ||
        !Number.isSafeInteger(data.len) || data.offset !== expectedOffset || data.len < 0 ||
        typeof data.eof !== 'boolean' || typeof data.data !== 'string' ||
        (own(data, 'sha256') && (typeof data.sha256 !== 'string' || !/^[0-9a-f]{64}$/i.test(data.sha256)))) {
      throw new Error('A download chunk does not match the contract.');
    }
    if (expectedSize !== null && data.size !== expectedSize) { throw new Error('The file changed size during the download.'); }
    var bytes = fromBase64(data.data);
    if (bytes.length !== data.len || data.offset + data.len > data.size || data.eof !== (data.offset + data.len === data.size) ||
        (!data.eof && own(data, 'sha256')) || (data.eof && !own(data, 'sha256')) || (!data.eof && data.len === 0)) {
      throw new Error('The download chunk is internally inconsistent.');
    }
    return {meta: data, bytes: bytes};
  }
  function startDownload() {
    var path = ui.downloadPath.value.trim();
    if (!path) { notice('Enter a path provided by the file index.', true); return; }
    var current = controller();
    state.download = {controller: current, canceled: false};
    clearNotice();
    setDownloadBusy(true);
    ui.downloadProgress.value = 0;
    ui.downloadStatus.textContent = 'Requesting the first chunk…';
    var offset = 0, size = null, parts = [], finalMeta = null;
    function next() {
      if (state.download.canceled) { throw new Error('CANCELED'); }
      return api.request('/api/download?path=' + encodeURIComponent(path) + '&offset=' + offset + '&max=' + GET_CHUNK,
        {signal: current.signal}).then(function (data) {
        var chunk = validChunk(data, offset, size);
        if (size === null) { size = chunk.meta.size; }
        parts.push(chunk.bytes);
        offset += chunk.meta.len;
        ui.downloadProgress.value = size ? offset / size : 1;
        ui.downloadStatus.textContent = 'Received ' + offset + ' of ' + size + ' bytes…';
        if (!chunk.meta.eof) { return next(); }
        finalMeta = chunk.meta;
        var joined = new Uint8Array(size);
        var cursor = 0;
        parts.forEach(function (part) { joined.set(part, cursor); cursor += part.length; });
        return sha256(joined).then(function (actual) {
          if (actual.toLowerCase() !== finalMeta.sha256.toLowerCase()) {
            throw new Error('The final digest does not match: the file changed or the download was corrupted. Nothing was saved.');
          }
          var blob = new Blob([joined]);
          var url = URL.createObjectURL(blob);
          var anchor = document.createElement('a');
          anchor.href = url;
          anchor.download = safeName(finalMeta.name);
          anchor.hidden = true;
          document.body.appendChild(anchor);
          anchor.click();
          anchor.remove();
          window.setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
          ui.downloadStatus.textContent = 'Download verified with SHA-256: ' + actual + '.';
        });
      });
    }
    Promise.resolve().then(next).catch(function (error) {
      if (state.download && state.download.canceled || error.name === 'AbortError' || error.message === 'CANCELED') {
        ui.downloadStatus.textContent = 'Download canceled locally; no file was offered.';
      } else {
        notice(error.message, true);
        ui.downloadStatus.textContent = 'The download was not delivered.';
      }
    }).finally(function () {
      state.download = null;
      setDownloadBusy(false);
    });
  }
  function cancelDownload() {
    if (!state.download) { return; }
    state.download.canceled = true;
    state.download.controller.abort();
    ui.downloadStatus.textContent = 'Canceling download…';
  }
  function validTeams(data) {
    var seen = new Set();
    return api.object(data) && Array.isArray(data.teams) && data.teams.every(function (team) {
      return api.object(team) && typeof team.name === 'string' && team.name.length > 0 && !seen.has(team.name) && (seen.add(team.name), true);
    });
  }
  function loadTargets() {
    if (state.targetsLoading) { return; }
    state.targetsLoading = true;
    ui.uploadTeam.replaceChildren(textOption('', 'Loading teams…'));
    return api.request('/api/teams').then(function (data) {
      if (!validTeams(data)) { throw new Error('The team list does not match the contract.'); }
      ui.uploadTeam.replaceChildren(textOption('', 'Choose a team'));
      data.teams.slice().sort(function (a, b) { return a.name.localeCompare(b.name, 'en'); }).forEach(function (team) {
        ui.uploadTeam.appendChild(textOption(team.name, team.name));
      });
      state.targetsLoaded = true;
    }).catch(function (error) {
      ui.uploadTeam.replaceChildren(textOption('', 'Teams could not be loaded'));
      notice(error.message, true);
    }).finally(function () { state.targetsLoading = false; });
  }
  function setUploadBusy(busy) {
    ui.uploadStart.disabled = busy;
    ui.uploadCancel.hidden = !busy;
    ui.uploadProgress.hidden = !busy;
  }
  function uploadId() {
    if (window.crypto && typeof window.crypto.getRandomValues === 'function') {
      var words = new Uint32Array(3);
      window.crypto.getRandomValues(words);
      return 'web-' + Array.prototype.map.call(words, function (word) { return word.toString(16); }).join('');
    }
    return 'web-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
  }
  function readSlice(file, start, end) { return file.slice(start, end).arrayBuffer().then(function (buffer) { return new Uint8Array(buffer); }); }
  function startUpload() {
    var team = ui.uploadTeam.value;
    var file = ui.uploadFile.files && ui.uploadFile.files[0];
    if (!team || !file) { notice('Choose a team and a file before uploading.', true); return; }
    if (file.size > MAX_UPLOAD) { notice('The file exceeds the 10 MiB limit declared by the hub.', true); return; }
    var current = controller();
    state.upload = {controller: current, canceled: false, sent: false};
    setUploadBusy(true);
    clearNotice();
    ui.uploadProgress.value = 0;
    ui.uploadStatus.textContent = 'Calculating SHA-256 before publishing…';
    file.arrayBuffer().then(function (buffer) { return sha256(new Uint8Array(buffer)); }).then(function (digest) {
      var offset = 0;
      var id = uploadId();
      function next() {
        if (state.upload.canceled) { throw new Error('CANCELED'); }
        var end = Math.min(offset + PUT_CHUNK, file.size);
        var last = end === file.size;
        return readSlice(file, offset, end).then(function (part) {
          var body = {to: team, name: file.name, id: id, offset: offset, data: base64(part)};
          if (last) { body.last = true; body.sha256 = digest; }
          state.upload.sent = true;
          return api.post('/api/upload', body, current.signal).then(function (data) {
            if (!api.object(data)) { throw new Error('The upload response does not match the contract.'); }
            if (!last) {
              if (!Number.isSafeInteger(data.received) || data.received !== end) { throw new Error('The hub did not confirm the chunk offset.'); }
            } else if (typeof data.path !== 'string' || data.path.length === 0 || typeof data.sha256 !== 'string' ||
                       data.sha256.toLowerCase() !== digest.toLowerCase()) {
              throw new Error('The hub did not confirm publication with the expected digest.');
            }
            offset = end;
            ui.uploadProgress.value = file.size ? offset / file.size : 1;
            ui.uploadStatus.textContent = last ? 'Published and verified: ' + data.path + '.' : 'Sent ' + offset + ' of ' + file.size + ' bytes…';
            if (!last) { return next(); }
            return null;
          });
        });
      }
      return next();
    }).catch(function (error) {
      if (state.upload && state.upload.canceled || error.name === 'AbortError' || error.message === 'CANCELED') {
        ui.uploadStatus.textContent = 'Upload canceled locally. If a chunk reached the hub, its temporary data will expire; this identifier will not be reused.';
      } else {
        notice(error.message, true);
        ui.uploadStatus.textContent = 'The upload was not confirmed as published.';
      }
    }).finally(function () {
      state.upload = null;
      setUploadBusy(false);
    });
  }
  function cancelUpload() {
    if (!state.upload) { return; }
    state.upload.canceled = true;
    state.upload.controller.abort();
    ui.uploadStatus.textContent = 'Canceling upload…';
  }

  ui.downloadStart.addEventListener('click', startDownload);
  ui.downloadCancel.addEventListener('click', cancelDownload);
  ui.uploadStart.addEventListener('click', startUpload);
  ui.uploadCancel.addEventListener('click', cancelUpload);
  window.addEventListener('pizarra:download-path', function (event) {
    if (event.detail && typeof event.detail.path === 'string') { ui.downloadPath.value = event.detail.path; }
  });
  window.addEventListener('pizarra:view', function (event) {
    if (event.detail.name === 'transfers' && !state.targetsLoaded && !state.targetsLoading) { loadTargets(); }
  });
  if (!ui.view.hidden) { loadTargets(); }
})();
