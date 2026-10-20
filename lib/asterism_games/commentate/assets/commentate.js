// The commentary page (asterism-games commentate mahjong; README
// "Commentary"). It listens to /events (Server-Sent Events): "status" (the
// tables, whether the hands are hidden for everybody), "state" (a table's
// spectate view) and "line" (a line of commentary). It draws the table in
// the canvas with the tile sheets of Family mruby's mahjong app, shows the
// lines as captions and reads them with the browser's speech synthesis.
// Keys: Space pause, M voice, H hide the hands. URL parameters: table=<id>,
// hands=0 (hidden), voice=0, obs=1 (no bar, a transparent background).
"use strict";

(function () {
  const params = new URLSearchParams(location.search);
  const $ = (id) => document.getElementById(id);
  const canvas = $("table");
  const ctx = canvas.getContext("2d");

  // ------------------------------------------------------------ state

  const st = {
    table: params.get("table") || null,
    view: null,
    lines: [],            // every line kept (the last MAX_LINES)
    status: { tables: [], public: false },
    hide: params.get("hands") === "0",
    voiceOn: params.get("voice") !== "0",
    unlocked: false,      // the page was clicked: the browser lets it speak
    paused: false,
    held: { view: null, lines: [] },
    connected: false,
    sheets: null,
  };
  const MAX_LINES = 300;
  if (params.get("obs") === "1") document.body.classList.add("obs");

  // ------------------------------------------------------------ tiles

  // Tile numbers as everywhere in the game: 0..8 1m..9m, 9 the red 5m,
  // 10..19 the circles, 20..29 the bamboos, 30..36 the honours, 37 the back.
  function tileIndex(name) {
    const m = /^([0-9])([mpsz])$/.exec(name || "");
    if (!m) return 37;
    const d = +m[1];
    if (m[2] === "z") return d >= 1 && d <= 7 ? 29 + d : 37;
    const base = { m: 0, p: 10, s: 20 }[m[2]];
    return d === 0 ? base + 9 : base + d - 1;
  }

  // A sheet as the browser decodes the BMP, with its transparent colour
  // (RGB332 0xE3, magenta) made transparent on a canvas of its own. The
  // file itself is the hand-drawn one as it is.
  function loadSheet(url, cw, ch) {
    return new Promise((resolve, reject) => {
      const img = new Image();
      img.onload = () => {
        const c = document.createElement("canvas");
        c.width = img.width;
        c.height = img.height;
        const g = c.getContext("2d");
        g.drawImage(img, 0, 0);
        const d = g.getImageData(0, 0, c.width, c.height);
        const p = d.data;
        for (let i = 0; i < p.length; i += 4) {
          if (p[i] === 255 && p[i + 1] === 0 && p[i + 2] === 255) p[i + 3] = 0;
        }
        g.putImageData(d, 0, 0);
        resolve({ canvas: c, cw: cw, ch: ch });
      };
      img.onerror = reject;
      img.src = url;
    });
  }

  // Draws tile n of a sheet at (x, y) w x h; rot: quarter turns clockwise.
  function tile(sheet, n, x, y, w, h, rot, alpha) {
    if (!st.sheets) return;
    const sx = (n % 10) * sheet.cw;
    const sy = Math.floor(n / 10) * sheet.ch;
    ctx.save();
    if (alpha !== undefined) ctx.globalAlpha = alpha;
    if (rot) {
      // The box (x, y, w, h) is the turned tile's: draw upright around its centre.
      ctx.translate(x + w / 2, y + h / 2);
      ctx.rotate((rot * Math.PI) / 2);
      ctx.drawImage(sheet.canvas, sx, sy, sheet.cw, sheet.ch, -h / 2, -w / 2, h, w);
    } else {
      ctx.drawImage(sheet.canvas, sx, sy, sheet.cw, sheet.ch, x, y, w, h);
    }
    ctx.restore();
  }

  // ------------------------------------------------------------ layout

  // Logical sizes (the canvas is scaled to the window).
  const L = {
    PW: 720, PH: 176, GAP: 10, BAND: 74,
    HW: 34, HH: 45,          // a hand tile (the hand sheet at 0.8)
    RW: 24, RH: 32,          // a river tile (the river sheet as it is)
    RIVER_X: 10, HAND_X: 214,
  };
  const WIND = { east: "東", south: "南", west: "西", north: "北" };
  const KIND = { cpu: "CPU", ai: "AI", human: "", empty: "空席" };

  function layout() {
    const avail = Math.max(280, $("stage").clientWidth - 2);
    const cols = avail >= 1150 ? 2 : 1;
    const w = cols * L.PW + (cols + 1) * L.GAP;
    const rows = 4 / cols;
    const h = L.BAND + rows * L.PH + (rows + 1) * L.GAP;
    const scale = Math.min(1.25, avail / w);
    const dpr = window.devicePixelRatio || 1;
    canvas.style.width = Math.floor(w * scale) + "px";
    canvas.style.height = Math.floor(h * scale) + "px";
    canvas.width = Math.floor(w * scale * dpr);
    canvas.height = Math.floor(h * scale * dpr);
    ctx.setTransform(scale * dpr, 0, 0, scale * dpr, 0, 0);
    ctx.imageSmoothingEnabled = true;
    return { cols: cols, w: w, h: h };
  }

  // ------------------------------------------------------------ drawing

  function draw() {
    const lay = layout();
    ctx.fillStyle = "#1d4a33";
    ctx.fillRect(0, 0, lay.w, lay.h);
    const v = st.view;
    drawBand(v, lay.w);
    for (let s = 0; s < 4; s++) {
      const c = s % lay.cols;
      const r = Math.floor(s / lay.cols);
      const x = L.GAP + c * (L.PW + L.GAP);
      const y = L.BAND + L.GAP + r * (L.PH + L.GAP);
      drawSeat(v, s, x, y);
    }
    if (!st.sheets) text("牌の画像を読み込んでいます", 20, L.BAND + 40, 16, "#fff");
  }

  function text(s, x, y, size, color, bold) {
    ctx.font = (bold ? "bold " : "") + size + 'px "Hiragino Sans", "Yu Gothic UI", "Meiryo", "Noto Sans CJK JP", sans-serif';
    ctx.fillStyle = color;
    ctx.textBaseline = "alphabetic";
    ctx.fillText(s, x, y);
    return ctx.measureText(s).width;
  }

  function roundName(r) {
    return (WIND[r.wind] || r.wind) + r.number + "局";
  }

  // The band on top: the round, the honba, the riichi sticks, the wall,
  // the dora indicators; and what the table is doing (a result's line).
  function drawBand(v, w) {
    ctx.fillStyle = "#0f2a1d";
    ctx.fillRect(0, 0, w, L.BAND);
    if (!v) {
      text("卓の様子を待っています", 16, 32, 20, "#e8efe9", true);
      return;
    }
    let x = 16;
    const r = v.round;
    if (r && v.status !== "wait") {
      x += text(roundName(r), x, 32, 26, "#ffd166", true) + 14;
      x += text(r.honba + "本場", x, 32, 18, "#e8efe9") + 14;
      x += text("供託 " + r.riichi_sticks, x, 32, 18, "#e8efe9") + 14;
      x += text("残り " + r.wall_left, x, 32, 18, r.wall_left <= 10 ? "#ff7b6b" : "#e8efe9") + 18;
      x += text("ドラ表示牌", x, 32, 15, "#9fb5a6") + 8;
      (v.dora_indicators || []).forEach((d) => {
        tile(st.sheets && st.sheets.river, tileIndex(d), x, 8, L.RW, L.RH);
        x += L.RW + 2;
      });
    } else {
      text(v.status === "wait" ? "対局の始まりを待っています" : "", 16, 32, 20, "#e8efe9", true);
    }
    text(statusLine(v), 16, 62, 16, "#e8efe9");
  }

  function seatName(v, i) {
    const s = v && v.seats && v.seats[i];
    return (s && s.name) || (i + 1) + "番の席";
  }

  function statusLine(v) {
    const res = v.result;
    if ((v.status === "result" || v.status === "over") && res) {
      if (res.wins && res.wins.length) {
        return res.wins.map((w) => {
          const by = res.kind === "ron_agari" ? "ロン" : "ツモ";
          return by + " " + seatName(v, w.seat) + "  " + (w.yaku || []).join("・") + "  " + (w.points || "");
        }).join("   ");
      }
      if (res.kind === "ryuukyoku") {
        const t = (res.tenpai || []).map((i) => seatName(v, i));
        return "流局  " + (t.length ? "テンパイ: " + t.join("、") : "全員ノーテン");
      }
      return "途中流局";
    }
    if (v.status === "over" && v.final) {
      return "終局  " + v.final.slice().sort((a, b) => a[1] - b[1]).map((f) => f[1] + "位 " + seatName(v, f[0]) + " " + f[2]).join("  ");
    }
    if (v.status === "play" && v.round) {
      const t = v.round.turn;
      return "手番: " + seatName(v, t);
    }
    return "";
  }

  // A seat's panel: the line of its name, the river on the left, the hand
  // and the drawn tile, the melds under the hand.
  function drawSeat(v, s, x, y) {
    const seat = v && v.seats ? v.seats[s] : null;
    const play = v && (v.status === "play" || v.status === "result" || v.status === "over") && v.round;
    const turn = play && v.status === "play" && v.round.turn === s;
    ctx.fillStyle = "#16382a";
    ctx.fillRect(x, y, L.PW, L.PH);
    ctx.lineWidth = turn ? 3 : 1;
    ctx.strokeStyle = turn ? "#ffd166" : "#2c5a40";
    ctx.strokeRect(x + 0.5, y + 0.5, L.PW - 1, L.PH - 1);
    if (!seat) return;
    // The name line.
    let nx = x + 10;
    if (seat.wind) {
      const dealer = play && v.round.dealer === s;
      nx += text(WIND[seat.wind] || "", nx, y + 22, 18, dealer ? "#ff7b6b" : "#ffd166", true) + 4;
      if (dealer) nx += text("親", nx, y + 22, 13, "#ff7b6b") + 6;
    }
    nx += text(seat.name || "", nx, y + 22, 17, "#e8efe9", true) + 8;
    if (KIND[seat.kind]) nx += text(KIND[seat.kind], nx, y + 22, 12, "#9fb5a6") + 8;
    if (seat.score !== undefined) nx += text(seat.score + "点", nx, y + 22, 17, "#e8efe9") + 10;
    if (seat.riichi) {
      ctx.fillStyle = "#ff7b6b";
      ctx.fillRect(nx, y + 9, 52, 18);
      text("リーチ", nx + 6, y + 23, 13, "#fff", true);
      nx += 60;
    }
    if (!play || !st.sheets) return;
    drawRiver(v, s, seat, x + L.RIVER_X, y + 34);
    drawHand(seat, x + L.HAND_X, y + 34);
    drawMelds(seat, x + L.HAND_X, y + 34 + L.HH + 12);
  }

  function drawRiver(v, s, seat, x, y) {
    const river = seat.river || [];
    const per = river.length > 28 ? 8 : river.length > 24 ? 7 : 6;
    const called = seat.called_indexes || [];
    const last = v.last_discard && v.last_discard.seat === s ? river.length - 1 : -1;
    let cx = x;
    let cy = y;
    river.forEach((t, i) => {
      if (i > 0 && i % per === 0) {
        cx = x;
        cy += L.RH + 2;
      }
      const sideways = seat.riichi_index === i;
      const w = sideways ? L.RH : L.RW;
      const alpha = called.indexOf(i) >= 0 ? 0.35 : undefined;
      if (sideways) tile(st.sheets.river, tileIndex(t), cx, cy + (L.RH - L.RW), w, L.RW, 1, alpha);
      else tile(st.sheets.river, tileIndex(t), cx, cy, w, L.RH, 0, alpha);
      if (i === last && v.status === "play") {
        ctx.lineWidth = 2;
        ctx.strokeStyle = "#ff7b6b";
        ctx.strokeRect(cx, sideways ? cy + (L.RH - L.RW) : cy, w, sideways ? L.RW : L.RH);
      }
      cx += w;
    });
  }

  function drawHand(seat, x, y) {
    const shown = !st.hide && !st.status.public && Array.isArray(seat.hand);
    let hand;
    let drawn;
    if (shown) {
      hand = seat.hand;
      drawn = seat.drawn;
    } else {
      const n = seat.hand_count || 0;
      const hasDrawn = Array.isArray(seat.hand) ? !!seat.drawn : (n % 3 === 2);
      hand = new Array(Math.max(0, n - (hasDrawn ? 1 : 0))).fill(null);
      drawn = hasDrawn ? null : undefined;
    }
    let cx = x;
    hand.forEach((t) => {
      tile(st.sheets.hand, t === null ? 37 : tileIndex(t), cx, y, L.HW, L.HH);
      cx += L.HW;
    });
    if (drawn !== undefined && (drawn !== null || !shown)) {
      tile(st.sheets.hand, drawn === null ? 37 : tileIndex(drawn), cx + 10, y, L.HW, L.HH);
    }
  }

  // The melds under the hand, in the river's tiles; a closed kan shows its
  // two outer tiles as backs.
  function drawMelds(seat, x, y) {
    let cx = x;
    (seat.melds || []).forEach((m) => {
      const tiles = m.tiles || [];
      tiles.forEach((t, i) => {
        const back = m.type === "closed_kan" && (i === 0 || i === tiles.length - 1);
        tile(st.sheets.river, back ? 37 : tileIndex(t), cx, y, L.RW, L.RH);
        cx += L.RW;
      });
      cx += 8;
    });
  }

  // ------------------------------------------------------------ captions

  function lineText(l) {
    if (hidden()) return l.ptext === undefined ? l.text : l.ptext;
    return l.text;
  }
  function lineSpeech(l) {
    if (hidden()) return l.pspeech === undefined ? l.speech : l.pspeech;
    return l.speech;
  }
  function hidden() { return st.hide || st.status.public; }

  function addCaption(l) {
    const t = lineText(l);
    if (!t) return;
    const box = $("captions");
    const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
    const div = document.createElement("div");
    div.className = "cap p" + (l.prio || 0) + (l.old ? " old" : "");
    const time = document.createElement("time");
    time.textContent = l.at || "";
    const span = document.createElement("span");
    span.textContent = t;
    div.appendChild(time);
    div.appendChild(span);
    box.appendChild(div);
    while (box.children.length > MAX_LINES) box.removeChild(box.firstChild);
    if (atBottom) box.scrollTop = box.scrollHeight;
  }

  function renderCaptions() {
    $("captions").textContent = "";
    st.lines.forEach(addCaption);
    $("captions").scrollTop = $("captions").scrollHeight;
  }

  // ------------------------------------------------------------ voice

  // A queue read in turn. When it falls behind, the old small lines go
  // first: a win or a draw (prio 2) drops the smallest ones waiting, a big
  // moment (prio 3) every small one, so it is read next after the lines
  // that matter (never before the win that made it).
  const speech = {
    queue: [],
    speaking: false,
    voice: null,
    MAX: 4,
    STALE_MS: 20000,
  };
  const synth = window.speechSynthesis;

  function pickVoice() {
    if (!synth) return;
    const vs = synth.getVoices();
    speech.voice = vs.find((v) => /^ja(-|_|$)/i.test(v.lang) && v.localService) ||
                   vs.find((v) => /^ja(-|_|$)/i.test(v.lang)) || null;
    showVoice();
  }
  if (synth) {
    pickVoice();
    synth.onvoiceschanged = pickVoice;
  }

  function say(l) {
    if (!synth || !st.voiceOn || !speech.voice) return;
    const s = lineSpeech(l);
    if (!s) return;
    const item = { text: s, prio: l.prio || 0, at: Date.now() };
    if (item.prio >= 3) speech.queue = speech.queue.filter((q) => q.prio >= 2);
    else if (item.prio === 2) speech.queue = speech.queue.filter((q) => q.prio >= 1);
    speech.queue.push(item);
    while (speech.queue.length > speech.MAX) {
      let k = speech.queue.findIndex((q) => q.prio <= 1);
      if (k < 0) k = speech.queue.findIndex((q) => q.prio <= 2);
      if (k < 0) k = speech.queue.length - 1;
      speech.queue.splice(k, 1);
    }
    next();
  }

  function next() {
    if (speech.speaking || st.paused || !st.unlocked) return;
    const now = Date.now();
    speech.queue = speech.queue.filter((q) => q.prio >= 2 || now - q.at < speech.STALE_MS);
    const item = speech.queue.shift();
    if (!item) return;
    const u = new SpeechSynthesisUtterance(item.text);
    u.lang = "ja-JP";
    u.voice = speech.voice;
    u.rate = item.prio >= 3 ? 1.1 : 1.15;
    u.pitch = item.prio >= 3 ? 1.15 : 1.0;
    speech.speaking = true;
    const done = () => { speech.speaking = false; setTimeout(next, 120); };
    u.onend = done;
    u.onerror = done;
    synth.speak(u);
  }

  function showVoice() {
    const el = $("voice");
    if (!synth) { el.textContent = "声: このブラウザは読み上げ無し"; el.className = "item warn"; return; }
    if (!speech.voice) { el.textContent = "声: 日本語の声がありません"; el.className = "item warn"; return; }
    if (!st.voiceOn) { el.textContent = "声: 切 (M)"; el.className = "item"; return; }
    el.textContent = st.unlocked ? "声: 入 (" + speech.voice.name + ")" : "声: クリック待ち";
    el.className = "item on";
  }

  function unlock() {
    if (st.unlocked) return;
    st.unlocked = true;
    $("hint").hidden = true;
    // A first utterance inside the gesture opens the way on some browsers.
    if (synth && speech.voice && st.voiceOn) {
      const u = new SpeechSynthesisUtterance("実況を始めます");
      u.lang = "ja-JP";
      u.voice = speech.voice;
      speech.speaking = true;
      u.onend = u.onerror = () => { speech.speaking = false; next(); };
      synth.speak(u);
    }
    showVoice();
  }
  document.addEventListener("click", unlock);
  $("hint").addEventListener("keydown", (e) => { if (e.key === "Enter") unlock(); });

  // ------------------------------------------------------------ the bar

  function showBar() {
    const tables = st.status.tables || [];
    const sel = $("tables");
    const cur = tables.find((t) => t.id === st.table);
    $("tname").textContent = cur ? cur.name + " (" + cur.host + ")" : (tables.length ? "" : "卓を待っています");
    sel.hidden = tables.length < 2;
    sel.textContent = "";
    tables.forEach((t) => {
      const o = document.createElement("option");
      o.value = t.id;
      o.textContent = t.name + " (" + t.host + ")" + (t.gone ? " 不在" : "");
      if (t.id === st.table) o.selected = true;
      sel.appendChild(o);
    });
    const d = st.view && st.view.delay_s;
    $("delay").textContent = st.view ? (d ? "遅れ " + d + " 秒" : "遅れなし") : "";
    const mode = [];
    if (st.status.public) mode.push("手牌非公開");
    else if (st.hide) mode.push("手牌を隠す (H)");
    if (st.paused) mode.push("一時停止中 (Space)");
    $("mode").textContent = mode.join(" / ");
    $("mode").className = "item" + (st.paused ? " warn" : "");
    let conn = "";
    if (!st.connected) conn = "実況アプリとの接続が切れています (再接続を待っています)";
    else if (cur && cur.gone) conn = "ホストが見えません (戻るのを待っています)";
    $("conn").textContent = conn;
    $("conn").className = "item warn";
    showVoice();
  }

  $("tables").addEventListener("change", (e) => {
    st.table = e.target.value;
    const u = new URL(location.href);
    u.searchParams.set("table", st.table);
    history.replaceState(null, "", u);
    st.view = null;
    st.lines = [];
    renderCaptions();
    connect();
  });

  // ------------------------------------------------------------ keys

  document.addEventListener("keydown", (e) => {
    if (e.target && e.target.tagName === "SELECT") return;
    if (e.key === " ") {
      e.preventDefault();
      setPaused(!st.paused);
    } else if (e.key === "m" || e.key === "M") {
      st.voiceOn = !st.voiceOn;
      if (!st.voiceOn && synth) { synth.cancel(); speech.queue = []; speech.speaking = false; }
      unlock();
      showVoice();
    } else if (e.key === "h" || e.key === "H") {
      st.hide = !st.hide;
      if (synth) { synth.cancel(); speech.queue = []; speech.speaking = false; }
      renderCaptions();
      draw();
      showBar();
    } else {
      return;
    }
  });

  // Paused: what arrives is held; going on shows the newest table and the
  // held lines (only the newest big one is read).
  function setPaused(p) {
    st.paused = p;
    if (synth) { if (p) synth.pause(); else synth.resume(); }
    if (!p) {
      if (st.held.view) st.view = st.held.view;
      const held = st.held.lines;
      st.held = { view: null, lines: [] };
      held.forEach((l) => { st.lines.push(l); addCaption(l); });
      const big = held.filter((l) => (l.prio || 0) >= 3).pop();
      if (big) say(big);
      trimLines();
      draw();
      next();
    }
    showBar();
  }

  function trimLines() { while (st.lines.length > MAX_LINES) st.lines.shift(); }

  // ------------------------------------------------------------ events

  let es = null;
  function connect() {
    if (es) es.close();
    const url = "/events" + (st.table ? "?table=" + encodeURIComponent(st.table) : "");
    es = new EventSource(url);
    es.onopen = () => { st.connected = true; showBar(); };
    es.onerror = () => { st.connected = false; showBar(); };
    es.addEventListener("status", (e) => {
      st.status = JSON.parse(e.data);
      if (!st.table && st.status.tables.length) st.table = st.status.tables[0].id;
      showBar();
    });
    es.addEventListener("state", (e) => {
      const d = JSON.parse(e.data);
      if (st.table && d.table !== st.table) return;
      if (!st.table) st.table = d.table;
      if (st.paused) { st.held.view = d.view; return; }
      st.view = d.view;
      draw();
      showBar();
    });
    es.addEventListener("line", (e) => {
      const l = JSON.parse(e.data);
      if (st.table && l.table !== st.table) return;
      if (st.lines.some((x) => x.id === l.id)) return;
      if (st.paused && !l.old) { st.held.lines.push(l); return; }
      st.lines.push(l);
      trimLines();
      addCaption(l);
      if (!l.old) say(l);
    });
  }

  window.addEventListener("resize", () => draw());
  Promise.all([loadSheet("/tiles_hand.bmp", 42, 56), loadSheet("/tiles_river.bmp", 24, 32)])
    .then(([hand, river]) => { st.sheets = { hand: hand, river: river }; draw(); })
    .catch(() => { text("牌の画像を読めませんでした", 20, L.BAND + 40, 16, "#ff7b6b"); });
  draw();
  showBar();
  connect();
  // For a test or a tool driving the page.
  window.commentate = { state: st };
})();
