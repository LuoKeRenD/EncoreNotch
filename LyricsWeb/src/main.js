import { BackgroundRender, LyricPlayer, MeshGradientRenderer } from "@applemusic-like-lyrics/core";
import "@applemusic-like-lyrics/core/style.css";
import "./style.css";

function notifyNative(message) {
  window.webkit?.messageHandlers?.encoreNotch?.postMessage(message);
}

window.addEventListener("error", (event) => notifyNative({ type: "error", message: String(event.message) }));
window.addEventListener("unhandledrejection", (event) => notifyNative({ type: "error", message: String(event.reason) }));

const lyricsElement = document.getElementById("lyrics");
const plainElement = document.getElementById("plain");
const messageElement = document.getElementById("message");

const player = new LyricPlayer();
// Seeks are reported explicitly, so uneven delivery must not look like one.
player.setEnableAutoSeekDetection(false);
lyricsElement.appendChild(player.getElement());
player.addEventListener("line-click", (event) => {
  cancelScrollHold();
  notifyNative({ type: "seek", position: event.line.getLine().startTime });
});

// AMLL returns to the playing line 500 ms after scrolling stops, with no setting
// to change that, which is too soon to pick a line. Zero-distance wheel events
// keep its scroll interaction open for as long as the hold lasts.
const scrollHoldMs = 5000;
const scrollKeepAliveMs = 100;
let scrollHoldUntil = 0;
let scrollKeepAliveTimer = 0;

function cancelScrollHold() {
  clearTimeout(scrollKeepAliveTimer);
  scrollKeepAliveTimer = 0;
}

function keepScrollInteractionOpen() {
  if (performance.now() >= scrollHoldUntil) {
    scrollKeepAliveTimer = 0;
    player.resetScroll();
    return;
  }
  player.getElement().dispatchEvent(new WheelEvent("wheel", { deltaY: 0, cancelable: true }));
  scrollKeepAliveTimer = setTimeout(keepScrollInteractionOpen, scrollKeepAliveMs);
}

player.getElement().addEventListener(
  "wheel",
  (event) => {
    if (!event.isTrusted) return;
    scrollHoldUntil = performance.now() + scrollHoldMs;
    if (!scrollKeepAliveTimer) {
      scrollKeepAliveTimer = setTimeout(keepScrollInteractionOpen, scrollKeepAliveMs);
    }
  },
  { passive: true },
);

const background = BackgroundRender.new(MeshGradientRenderer);
background.setRenderScale(0.5);
background.setFPS(30);
document.getElementById("background").appendChild(background.getElement());

// Timing errors below this are noise from message delivery.
const ignoredErrorMs = 80;
// Larger differences are a real seek, which plays AMLL's jump animation.
const seekThresholdMs = 1000;
// Smaller corrections are eased in over about this long instead of jumping.
// AMLL's interlude dots animate straight from this clock, so a jump makes
// them stutter, and a step back would freeze them until time caught up.
const correctionMs = 400;

let anchorPosition = 0;
let anchorTime = performance.now();
let rate = 0;
let isPlaying = false;
let seekPending = false;
let pendingCorrection = 0;

function positionAt(now) {
  return anchorPosition + (isPlaying ? rate * (now - anchorTime) : 0);
}

function show(element) {
  for (const candidate of [lyricsElement, plainElement, messageElement]) {
    candidate.hidden = candidate !== element;
  }
}

// AMLL treats any backward step as a seek and drops the user's manual scroll,
// so a timing correction must never move the reported position backwards.
let reportedPosition = 0;

let lastFrame = performance.now();

function easeCorrection(elapsed) {
  if (pendingCorrection === 0) return;
  let step = pendingCorrection * Math.min(1, elapsed / correctionMs);
  if (isPlaying) {
    // Never run backwards: at most halve the clock's speed while catching up.
    step = Math.max(step, -0.5 * rate * elapsed);
  } else {
    step = pendingCorrection;
  }
  anchorPosition += step;
  pendingCorrection -= step;
  if (Math.abs(pendingCorrection) < 1) pendingCorrection = 0;
}

function frame(now) {
  easeCorrection(now - lastFrame);
  const position = positionAt(now);
  reportedPosition = seekPending ? position : Math.max(reportedPosition, position);
  player.setCurrentTime(reportedPosition, seekPending);
  seekPending = false;
  player.update(now - lastFrame);
  lastFrame = now;
  requestAnimationFrame(frame);
}

window.encoreNotch = {
  setLines(lines, positionMs) {
    cancelScrollHold();
    player.setLyricLines(lines, positionMs);
    anchorPosition = positionMs;
    anchorTime = performance.now();
    pendingCorrection = 0;
    reportedPosition = positionMs;
    player.update(0);
    background.setHasLyric(lines.length > 0);
    show(lyricsElement);
  },

  setPlain(text) {
    plainElement.textContent = text;
    plainElement.scrollTop = 0;
    player.setLyricLines([]);
    background.setHasLyric(false);
    show(plainElement);
  },

  setMessage(text) {
    messageElement.textContent = text;
    player.setLyricLines([]);
    background.setHasLyric(false);
    show(messageElement);
  },

  setPlayback({ position, rate: newRate, playing }) {
    const now = performance.now();
    const error = position - positionAt(now);
    const effectiveRate = playing ? newRate / 1000 : 0;
    const stateChanged = playing !== isPlaying || effectiveRate !== rate;

    if (stateChanged) {
      if (playing) {
        player.resume();
      } else {
        player.pause();
      }
    }
    const isSeek = Math.abs(error) >= seekThresholdMs;
    if (isSeek) {
      seekPending = true;
    }
    if (stateChanged || isSeek) {
      anchorPosition = position;
      anchorTime = now;
      pendingCorrection = 0;
    } else if (Math.abs(error) >= ignoredErrorMs) {
      pendingCorrection = error;
    }
    rate = effectiveRate;
    isPlaying = playing;
  },

  setAlbum(url) {
    return background.setAlbum(url);
  },
};

requestAnimationFrame(frame);
notifyNative({ type: "ready" });
