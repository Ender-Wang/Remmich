const source = document.querySelector("#source-url");
const copy = document.querySelector("#copy-source");
const status = document.querySelector("#copy-status");

if (navigator.clipboard?.writeText) {
  copy.hidden = false;
  copy.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(source.value);
      status.textContent = "Source URL copied.";
    } catch {
      source.focus();
      source.select();
      status.textContent = "Copy the selected URL.";
    }
  });
}

async function showLatestRelease() {
  const version = document.querySelector(".release-version");
  try {
    const response = await fetch("https://api.github.com/repos/Ender-Wang/Remmich/releases/latest");
    if (!response.ok) return;
    const { tag_name: tag } = await response.json();
    if (typeof tag !== "string" || !tag) return;

    version.textContent = tag;
  } catch {
    // The Latest release button remains available if the version lookup fails.
  }
}

showLatestRelease();

const showcase = document.querySelector(".hero-showcase");
const stage = showcase.querySelector(".hero-art");
const shots = Array.from(stage.querySelectorAll(".hero-phone"));
const shotLabel = showcase.querySelector("#hero-shot-label");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");

let current = 0;
let timer;
let hovering = matchMedia("(hover: hover)").matches && stage.matches(":hover");
let inView = false;
let advancing = false;

function shouldRotate() {
  return inView && !hovering && !reducedMotion.matches && !document.hidden;
}

function scheduleRotation(delay = 3200) {
  clearTimeout(timer);
  if (shouldRotate()) timer = setTimeout(advance, delay);
}

function updateVisibility() {
  document.documentElement.toggleAttribute("data-motion-paused", document.hidden);
  scheduleRotation();
}

async function advance() {
  if (advancing || !shouldRotate()) return;
  advancing = true;
  clearTimeout(timer);

  const nextIndex = (current + 1) % shots.length;
  const front = shots[nextIndex];
  const back = shots[(nextIndex + 1) % shots.length];
  try {
    if (!back.hasAttribute("src")) back.src = back.dataset.src;
    await Promise.all([front.decode(), back.decode()]);
    if (!shouldRotate()) return;

    stage.querySelector('[data-position="leaving"]')?.removeAttribute("data-position");
    shots[current].dataset.position = "leaving";
    shots[current].setAttribute("aria-hidden", "true");
    front.dataset.position = "front";
    front.removeAttribute("aria-hidden");
    back.dataset.position = "back";
    current = nextIndex;
    shotLabel.textContent = front.dataset.label;
  } catch {
    // Keep the last complete pair visible if a preview image fails to load.
  } finally {
    advancing = false;
    scheduleRotation();
  }
}

stage.addEventListener("pointerenter", (event) => {
  if (event.pointerType !== "mouse") return;
  hovering = true;
  scheduleRotation();
});
stage.addEventListener("pointerleave", (event) => {
  if (event.pointerType !== "mouse") return;
  hovering = false;
  scheduleRotation(800);
});
new IntersectionObserver(([entry]) => {
  inView = entry.isIntersecting && entry.intersectionRatio >= 0.3;
  scheduleRotation();
}, { threshold: 0.3 }).observe(stage);
reducedMotion.addEventListener("change", () => scheduleRotation());
document.addEventListener("visibilitychange", updateVisibility);
document.documentElement.setAttribute("data-motion-ready", "");
updateVisibility();
