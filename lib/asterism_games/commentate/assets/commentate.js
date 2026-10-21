// The commentary page (asterism-games commentate mahjong; README
// "Commentary"). It listens to /events (Server-Sent Events): "status" (the
// tables, whether the hands are hidden for everybody), "state" (a table's
// spectate view) and "line" (a line of commentary). It draws the table in
// the canvas with the tile sheets of Family mruby's mahjong app, shows the
// lines as captions and says them: VOICEVOX's character (fixed phrases as
// WAV files, the rest synthesised) when the command found the engine, else
// the browser's speech synthesis.
// The AI's one-liners (l.ai) come after the fixed lines, marked "AI" in
// the captions, and are the first to go when the voice falls behind.
// The sound of Family mruby's mahjong app (README "The sound"): its BGM
// for the scene ("state"'s bgm) and its effects for each step ("state"'s
// sounds), files made with the app's own APU (/sounds/, sounds.json),
// played with Web Audio beside the voice; the BGM goes down while the
// voice speaks.
// Keys: Space pause, M voice, B BGM (off, low, mid, high), E effects,
// H hide the hands. URL parameters: table=<id>, hands=0 (hidden), voice=0,
// obs=1 (no bar, a transparent background).
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
    held: { view: null, lines: [], bgm: null },
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
    if (l.ai) {
      div.className += " ai";
      const mark = document.createElement("b");
      mark.className = "aimark";
      mark.textContent = "AI";
      div.appendChild(mark);
    }
    div.appendChild(span);
    box.appendChild(div);
    while (box.children.length > MAX_LINES) box.removeChild(box.firstChild);
    if (atBottom) box.scrollTop = box.scrollHeight;
  }

  function renderCaptions() {
    $("captions").textContent = "";
    st.lines.forEach((l) => { if (!l.pending) addCaption(l); });
    $("captions").scrollTop = $("captions").scrollHeight;
  }

  // ------------------------------------------------------------ voice

  // One queue for every line said, read in turn. A line with VOICEVOX's
  // sound (l.voice, the status says the engine) plays its fixed phrases
  // first (WAV files made on this machine) and then the rest of the line
  // (synthesised meanwhile: its WAV is fetched as soon as the line is
  // queued); without it the browser's own voice reads the line. The
  // caption comes up when its voice starts. When the queue falls behind,
  // the old small lines go first: a win or a draw (prio 2) drops the
  // smallest ones waiting, a big moment (prio 3) every small one, so it is
  // said next after the lines that matter (never before the win that made
  // it). An AI's line ranks below every fixed line (prio -1 here): it
  // waits behind them (the fixed lines of its own scene come first, a win
  // and the lead changing hands can take 20 s), and is dropped when a new
  // scene comes (a riichi, a win, a draw; a round's start waits behind
  // it), when the queue is full (first), or after AI_STALE_MS. The command already
  // dropped an answer that came late. What was played is logged in
  // window.commentate.played.
  const speech = {
    queue: [],
    speaking: false,
    current: null,        // the item being said
    audio: null,          // the Audio playing, if any
    voice: null,          // the browser's Japanese voice
    MAX: 4,
    STALE_MS: 20000,
    AI_STALE_MS: 40000,
  };
  const played = [];
  const synth = window.speechSynthesis;

  function vv() { return st.status.voice && st.status.voice.engine === "voicevox" ? st.status.voice : null; }
  function canSpeak() { return !!(vv() || (synth && speech.voice)); }

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

  function log(kind, item, src) {
    const e = { t: Date.now(), kind: kind, id: item ? item.line.id : null, prio: item ? item.prio : null, src: src };
    played.push(e);
    if (played.length > 500) played.shift();
    if (window.console) console.log("voice", kind, e.id, src, e.t);
  }

  // Queues the line's voice; false when nothing is said (the caption then
  // comes up at once).
  function say(l) {
    if (!st.voiceOn || !st.unlocked || !canSpeak()) return false;
    const s = lineSpeech(l);
    if (!s) return false;
    const item = { line: l, text: s, prio: l.ai ? -1 : (l.prio || 0), at: Date.now() };
    const v = l.voice;
    if (vv() && v) {
      item.clips = v.clips || [];
      const live = hidden() && v.plive !== undefined ? v.plive : v.live;
      if (live) {
        item.ctl = window.AbortController ? new AbortController() : null;
        item.blob = fetch(live, item.ctl ? { signal: item.ctl.signal } : {})
          .then((r) => (r.ok ? r.blob() : Promise.reject(new Error("HTTP " + r.status))));
        item.blob.catch(() => {});
        item.live = live;
      }
    }
    l.pending = true;
    if (item.prio >= 3) drop((q) => q.prio >= 0 && q.prio < 2, "big");
    else if (item.prio === 2) drop((q) => q.prio === 0, "win");
    // A new scene (a riichi, a win, a draw, the lead changing hands) lets
    // a waiting AI line go: it spoke of the one before. A round's start
    // (the oorasu too) waits behind it.
    if (item.prio >= 2 && l.type !== "round_start") drop((q) => q.prio < 0, "scene");
    speech.queue.push(item);
    while (speech.queue.length > speech.MAX) {
      let k = speech.queue.findIndex((q) => q.prio < 0);
      if (k < 0) k = speech.queue.findIndex((q) => q.prio <= 1);
      if (k < 0) k = speech.queue.findIndex((q) => q.prio <= 2);
      if (k < 0) k = speech.queue.length - 1;
      dropAt(k, "full");
    }
    next();
    return true;
  }

  // Lines left unsaid still get their captions.
  // why: big (a prio 3 came), win (a prio 2 came), full, stale, cut.
  function dropAt(k, why) {
    const item = speech.queue.splice(k, 1)[0];
    if (!item) return;
    if (item.ctl) item.ctl.abort();
    log("drop", item, (why || "") + ": " + item.text);
    showLine(item.line);
  }
  function drop(pred, why) {
    for (let k = speech.queue.length - 1; k >= 0; k--) if (pred(speech.queue[k])) dropAt(k, why);
  }

  function showLine(l) {
    if (!l.pending) return;
    l.pending = false;
    addCaption(l);
  }

  function next() {
    if (speech.speaking || st.paused || !st.unlocked) return;
    const now = Date.now();
    drop((q) => q.prio >= 0 && q.prio < 2 && now - q.at >= speech.STALE_MS, "stale");
    drop((q) => q.prio < 0 && now - q.at >= speech.AI_STALE_MS, "stale");
    const item = speech.queue.shift();
    if (!item) return;
    speech.speaking = true;
    speech.current = item;
    sound.duck();
    showLine(item.line);
    sayItem(item).then(() => {
      if (speech.current !== item) return;   // cut off (M, H)
      speech.current = null;
      speech.speaking = false;
      sound.duck();
      setTimeout(next, 120);
    });
  }

  async function sayItem(item) {
    await sound.afterJingle();
    if (speech.current !== item) return;
    if (item.clips || item.blob) {
      for (const c of item.clips || []) {
        if (speech.current !== item) return;
        log("clip", item, c);
        await playUrl(c);
      }
      if (!item.blob || speech.current !== item) return;
      let url = null;
      try {
        url = URL.createObjectURL(await item.blob);
      } catch (e) {
        log("live-failed", item, item.live);
        if (synth && speech.voice) await speak(item, item.text);
        return;
      }
      if (speech.current !== item) return;
      log("live", item, item.live);
      await playUrl(url);
      URL.revokeObjectURL(url);
      return;
    }
    await speak(item, item.text);
  }

  function playUrl(url) {
    return new Promise((resolve) => {
      const a = new Audio(url);
      speech.audio = a;
      const done = () => { if (speech.audio === a) speech.audio = null; resolve(); };
      a.onended = done;
      a.onerror = done;
      a.play().catch(done);
    });
  }

  function speak(item, text) {
    return new Promise((resolve) => {
      if (!synth || !speech.voice) return resolve();
      log("speech", item, text);
      const u = new SpeechSynthesisUtterance(text);
      u.lang = "ja-JP";
      u.voice = speech.voice;
      u.rate = item && item.prio >= 3 ? 1.1 : 1.15;
      u.pitch = item && item.prio >= 3 ? 1.15 : 1.0;
      u.onend = resolve;
      u.onerror = resolve;
      synth.speak(u);
    });
  }

  // Stops what is being said and empties the queue (M, H); the captions
  // of what was waiting come up.
  function cut() {
    if (synth) synth.cancel();
    if (speech.audio) { speech.audio.pause(); speech.audio = null; }
    drop(() => true, "cut");
    speech.current = null;
    speech.speaking = false;
    sound.duck();
  }

  function showVoice() {
    const el = $("voice");
    const v = vv();
    const credit = $("credit");
    credit.textContent = v ? v.credit : "";
    credit.hidden = !v;
    const note = !v && st.status.voice && st.status.voice.note === "missing" ? "VOICEVOX が見つからない (無料のアプリ VOICEVOX を入れて起動すると、ずんだもんの声になる): ブラウザの声で読む / " : "";
    let what;
    if (v) what = "VOICEVOX " + v.speaker + " (" + v.style + ")";
    else if (!synth) { el.textContent = "声: " + note + "このブラウザは読み上げ無し"; el.className = "item warn"; return; }
    else if (!speech.voice) { el.textContent = "声: " + note + "日本語の声がありません"; el.className = "item warn"; return; }
    else what = speech.voice.name;
    if (!st.voiceOn) { el.textContent = "声: " + note + "切 (M)"; el.className = "item"; return; }
    el.textContent = "声: " + note + (st.unlocked ? "入 (" + what + ")" : "クリック待ち");
    el.className = "item on";
  }

  function unlock() {
    if (st.unlocked) return;
    st.unlocked = true;
    $("hint").hidden = true;
    sound.start();
    // A first sound inside the gesture opens the way on some browsers.
    const v = vv();
    if (st.voiceOn && canSpeak()) {
      const item = { line: { id: 0 }, prio: 1, at: Date.now() };
      speech.speaking = true;
      speech.current = item;
      sound.duck();
      const p = v && v.start ? (log("clip", item, v.start), playUrl(v.start)) : speak(item, "実況を始めます");
      p.then(() => {
        if (speech.current !== item) return;
        speech.current = null;
        speech.speaking = false;
        sound.duck();
        next();
      });
    }
    showVoice();
  }
  document.addEventListener("click", unlock);
  $("hint").addEventListener("keydown", (e) => { if (e.key === "Enter") unlock(); });

  // The AI's one-liners: on (the model, today's money and the limit),
  // over the limit, or off and why.
  function showAI() {
    const el = $("ai");
    const a = st.status.ai;
    if (!a) { el.textContent = ""; return; }
    const usd = (x) => "$" + Number(x || 0).toFixed(x >= 1 ? 2 : 4);
    const money = "今日 " + usd(a.usd) + " / 上限 $" + Number(a.limit_usd || 0).toFixed(2);
    if (a.state === "on") { el.textContent = "AI: " + a.model + " / " + money; el.className = "item on"; }
    else if (a.state === "fake") { el.textContent = "AI: 偽物 (API なし) / " + money; el.className = "item on"; }
    else if (a.state === "over") { el.textContent = "AI: 今日の上限に達した (" + money + "): 決まりの実況だけ"; el.className = "item warn"; }
    else {
      const why = { no_key: "キーなし", no_gem: "anthropic の gem なし", off: "--ai off" }[a.note] || a.note || "";
      el.textContent = "AI: off (" + why + ")";
      el.className = "item";
    }
  }

  // ------------------------------------------------------------ the app's sound

  // The BGM and the effects of Family mruby's mahjong app, as files made
  // with its APU (sounds.json lists them: the effects' priorities and
  // channels, the tunes' loops, the app's BGM levels and scenes). Web Audio,
  // after the first click (the browser's autoplay rule): the BGM is the
  // scene's tune from its start, its loop repeated without a seam; the
  // levels are the app's (off, low, mid, high: low by default, as the
  // app's), and while the voice speaks the BGM is at DUCK of its level
  // (the effects stay as they are). An effect plays at once, beside the
  // voice (not in its queue), and claims the APU channels it uses as the
  // app's do: one of a higher priority still sounding on them keeps them
  // (the new one is left out when it gets none), otherwise the older
  // sounds on them stop. A voice that would start on top of a jingle
  // waits for most of it (at most JINGLE_WAIT_MS). B and E switch, and the
  // page remembers both (localStorage).
  const sound = {
    ctx: null,
    manifest: null,
    buffers: {},          // file => AudioBuffer (or a Promise of one)
    bgmLevel: null,
    seOn: true,
    scene: "lobby",
    bgm: null,            // {key, src, gain} playing
    bgmGain: null,
    seGain: null,
    ducked: false,
    duckTimer: null,
    holders: [null, null, null, null],   // per APU channel: {pri, until, src}
    jingleUntil: 0,
    paused: false,
    log: [],
    DUCK: 0.5,
    JINGLE_WAIT_MS: 600,
    STORE: "asterism-games.commentate.",
  };

  sound.note = function (kind, name) {
    const e = { t: Date.now(), kind: kind, name: name };
    sound.log.push(e);
    if (sound.log.length > 500) sound.log.shift();
    if (window.console) console.log("sound", kind, name, e.t);
  };

  function stored(key) {
    try { return window.localStorage.getItem(sound.STORE + key); } catch (e) { return null; }
  }
  function store(key, value) {
    try { window.localStorage.setItem(sound.STORE + key, String(value)); } catch (e) { /* not kept */ }
  }

  sound.levels = function () { return (sound.manifest && sound.manifest.bgm_levels) || [0, 0.3, 0.55, 1]; };
  sound.names = function () { return (sound.manifest && sound.manifest.bgm_names) || ["切", "小", "中", "大"]; };

  sound.load = function () {
    const lv = parseInt(stored("bgm"), 10);
    sound.bgmLevel = lv >= 0 && lv <= 3 ? lv : null;
    sound.seOn = stored("se") !== "0";
    fetch("/sounds/sounds.json").then((r) => (r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status))))
      .then((m) => {
        sound.manifest = m;
        if (sound.bgmLevel === null || sound.bgmLevel >= m.bgm_levels.length) sound.bgmLevel = m.bgm_default;
        sound.show();
        if (sound.ctx) { sound.preload(); sound.applyBgm(); }
      })
      .catch(() => { sound.manifest = null; sound.show(); });
    sound.show();
  };

  // The first click: the context, the two volumes, the effects' files.
  sound.start = function () {
    if (sound.ctx) return;
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { sound.show(); return; }
    // 24 kHz is plenty for the APU's sound (15.72 kHz) and halves what the
    // decoded tunes take; a browser that will not have it gets its own rate.
    try { sound.ctx = new AC({ sampleRate: 24000 }); } catch (e) { sound.ctx = new AC(); }
    sound.bgmGain = sound.ctx.createGain();
    sound.bgmGain.gain.value = sound.bgmVolume();
    sound.bgmGain.connect(sound.ctx.destination);
    sound.seGain = sound.ctx.createGain();
    sound.seGain.connect(sound.ctx.destination);
    if (sound.ctx.state === "suspended") sound.ctx.resume().catch(() => {});
    if (sound.manifest) { sound.preload(); sound.applyBgm(); }
    sound.show();
  };

  sound.buffer = function (file) {
    const b = sound.buffers[file];
    if (b) return b instanceof Promise ? b : Promise.resolve(b);
    const p = fetch("/sounds/" + file)
      .then((r) => (r.ok ? r.arrayBuffer() : Promise.reject(new Error("HTTP " + r.status))))
      .then((data) => new Promise((resolve, reject) => sound.ctx.decodeAudioData(data, resolve, reject)))
      .then((buf) => { sound.buffers[file] = buf; return buf; })
      .catch((e) => { delete sound.buffers[file]; sound.note("failed", file); throw e; });
    sound.buffers[file] = p;
    return p;
  };

  sound.preload = function () {
    Object.keys(sound.manifest.effects).forEach((n) => sound.buffer(sound.manifest.effects[n].file).catch(() => {}));
  };

  sound.bgmVolume = function () {
    const v = sound.levels()[sound.bgmLevel || 0] || 0;
    return sound.ducked ? v * sound.DUCK : v;
  };

  sound.setScene = function (scene) {
    if (scene === sound.scene) return;
    sound.scene = scene;
    sound.applyBgm();
  };

  // The tune of the scene, or none (off, the end of a game, paused).
  sound.applyBgm = function () {
    const m = sound.manifest;
    if (!sound.ctx || !m) return;
    let key = m.scenes[sound.scene] || null;
    if (!key && sound.scene === "tense") key = m.scenes.play || null;
    if (!sound.bgmLevel || sound.paused) key = null;
    const cur = sound.bgm;
    if (cur && cur.key === key) return;
    if (cur) {
      const t = sound.ctx.currentTime;
      cur.gain.gain.setTargetAtTime(0, t, 0.03);
      cur.src.stop(t + 0.2);
      sound.bgm = null;
    }
    if (!key) return;
    const tune = m.tunes[key];
    const want = { key: key, src: null, gain: null };
    sound.bgm = want;
    sound.buffer(tune.file).then((buf) => {
      if (sound.bgm !== want) return;
      const src = sound.ctx.createBufferSource();
      src.buffer = buf;
      src.loop = true;
      src.loopStart = tune.loop_start;
      src.loopEnd = tune.loop_start + tune.loop_s;
      const g = sound.ctx.createGain();
      src.connect(g);
      g.connect(sound.bgmGain);
      src.start();
      want.src = src;
      want.gain = g;
      sound.note("bgm", key);
    }).catch(() => { if (sound.bgm === want) sound.bgm = null; });
  };

  // An effect of the app (name: sounds.json's effects), delay ms from now.
  sound.effect = function (name, delay) {
    if (!sound.ctx || !sound.seOn || sound.paused || !sound.manifest) return;
    const e = sound.manifest.effects[name];
    if (!e) return;
    const go = () => {
      if (!sound.seOn || sound.paused) return;
      sound.buffer(e.file).then((buf) => sound.play(name, e, buf)).catch(() => {});
    };
    if (delay > 0) setTimeout(go, delay); else go();
  };

  sound.play = function (name, e, buf) {
    const now = Date.now();
    const free = e.channels.filter((ch) => {
      const h = sound.holders[ch];
      return !h || h.until <= now || e.priority >= h.pri;
    });
    if (!free.length) { sound.note("left out", name); return; }
    const src = sound.ctx.createBufferSource();
    src.buffer = buf;
    src.connect(sound.seGain);
    const until = now + buf.duration * 1000;
    free.forEach((ch) => {
      const h = sound.holders[ch];
      if (h && h.until > now && h.src !== src) {
        try { h.src.stop(); } catch (x) { /* ended */ }
      }
      sound.holders[ch] = { pri: e.priority, until: until, src: src };
    });
    src.start();
    if (e.priority >= 3) sound.jingleUntil = Math.max(sound.jingleUntil, until);
    sound.note("sfx", name);
  };

  // Resolves when a voice may start: after most of a sounding jingle.
  sound.afterJingle = function () {
    const wait = Math.min(sound.JINGLE_WAIT_MS, sound.jingleUntil - Date.now() - 120);
    return wait > 0 ? new Promise((resolve) => setTimeout(resolve, wait)) : Promise.resolve();
  };

  // The BGM down while the voice speaks; up again a moment after it stops
  // (not between two lines).
  sound.duck = function () {
    const on = speech.speaking;
    if (on) {
      if (sound.duckTimer) { clearTimeout(sound.duckTimer); sound.duckTimer = null; }
      if (!sound.ducked) { sound.ducked = true; sound.volume(0.05); sound.note("duck", "down"); }
    } else if (sound.ducked && !sound.duckTimer) {
      sound.duckTimer = setTimeout(() => {
        sound.duckTimer = null;
        if (speech.speaking) return;
        sound.ducked = false;
        sound.volume(0.25);
        sound.note("duck", "up");
      }, 600);
    }
  };

  sound.volume = function (tc) {
    if (!sound.bgmGain) return;
    const t = sound.ctx.currentTime;
    sound.bgmGain.gain.cancelScheduledValues(t);
    sound.bgmGain.gain.setTargetAtTime(sound.bgmVolume(), t, tc || 0.05);
  };

  sound.cycleBgm = function () {
    const n = sound.levels().length;
    sound.bgmLevel = ((sound.bgmLevel || 0) + 1) % n;
    store("bgm", sound.bgmLevel);
    sound.volume(0.05);
    sound.applyBgm();
    sound.show();
  };

  sound.toggleSe = function () {
    sound.seOn = !sound.seOn;
    store("se", sound.seOn ? 1 : 0);
    if (!sound.seOn) {
      sound.holders.forEach((h) => { if (h) { try { h.src.stop(); } catch (x) { /* ended */ } } });
      sound.holders = [null, null, null, null];
    }
    sound.show();
  };

  sound.pause = function (p) {
    sound.paused = p;
    if (!sound.ctx) return;
    if (p) sound.ctx.suspend().catch(() => {});
    else sound.ctx.resume().catch(() => {});
  };

  sound.show = function () {
    const b = $("bgm");
    const e = $("se");
    const credit = $("bgmcredit");
    if (!sound.manifest) {
      b.textContent = "BGM: なし";
      b.className = "item";
      e.textContent = "";
      credit.hidden = true;
      return;
    }
    const lv = sound.bgmLevel || 0;
    const wait = st.unlocked ? "" : " (クリック待ち)";
    b.textContent = "BGM " + sound.names()[lv] + " [B]" + (lv ? wait : "");
    b.className = "item btn" + (lv ? " on" : "");
    e.textContent = "効果音 " + (sound.seOn ? "入" : "切") + " [E]";
    e.className = "item btn" + (sound.seOn ? " on" : "");
    credit.hidden = !lv;
  };
  $("bgm").addEventListener("click", () => sound.cycleBgm());
  $("se").addEventListener("click", () => sound.toggleSe());

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
    showAI();
    sound.show();
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
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === " ") {
      e.preventDefault();
      setPaused(!st.paused);
    } else if (e.key === "m" || e.key === "M") {
      st.voiceOn = !st.voiceOn;
      if (!st.voiceOn) cut();
      unlock();
      showVoice();
    } else if (e.key === "b" || e.key === "B") {
      sound.cycleBgm();
      unlock();
    } else if (e.key === "e" || e.key === "E") {
      sound.toggleSe();
      unlock();
    } else if (e.key === "h" || e.key === "H") {
      st.hide = !st.hide;
      cut();
      renderCaptions();
      draw();
      showBar();
      connect();   // the server learns it: the AI gets no hands meanwhile
    } else {
      return;
    }
  });

  // Paused: what arrives is held; going on shows the newest table and the
  // held lines (only the newest big one is read).
  function setPaused(p) {
    st.paused = p;
    if (synth) { if (p) synth.pause(); else synth.resume(); }
    if (speech.audio) { if (p) speech.audio.pause(); else speech.audio.play().catch(() => {}); }
    sound.pause(p);
    if (!p) {
      if (st.held.view) st.view = st.held.view;
      if (st.held.bgm) sound.setScene(st.held.bgm);
      const held = st.held.lines;
      st.held = { view: null, lines: [], bgm: null };
      const big = held.filter((l) => (l.prio || 0) >= 3).pop();
      held.forEach((l) => { st.lines.push(l); if (l !== big) addCaption(l); });
      if (big && !say(big)) addCaption(big);
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
    const q = [];
    if (st.table) q.push("table=" + encodeURIComponent(st.table));
    if (st.hide) q.push("hide=1");
    const url = "/events" + (q.length ? "?" + q.join("&") : "");
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
      if (st.paused) { st.held.view = d.view; st.held.bgm = d.bgm; return; }
      st.view = d.view;
      sound.setScene(d.bgm || "lobby");
      (d.sounds || []).forEach((x) => sound.effect(x[0], x[1]));
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
      if (l.old || !say(l)) addCaption(l);
    });
  }

  window.addEventListener("resize", () => draw());
  Promise.all([loadSheet("/tiles_hand.bmp", 42, 56), loadSheet("/tiles_river.bmp", 24, 32)])
    .then(([hand, river]) => { st.sheets = { hand: hand, river: river }; draw(); })
    .catch(() => { text("牌の画像を読めませんでした", 20, L.BAND + 40, 16, "#ff7b6b"); });
  draw();
  showBar();
  connect();
  sound.load();
  // For a test or a tool driving the page.
  window.commentate = { state: st, played: played, speech: speech, sound: sound };
})();
