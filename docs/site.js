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

function setupTimelineDemo(demo) {
  const hoverArea = demo.closest(".timeline-demo");
  const preview = demo.querySelector(".timeline-demo-preview");
  const controls = demo.querySelector(".demo-levels");
  const buttons = [...controls.querySelectorAll("button")];
  const days = [
    ["Jan 31, 2025", "Jan 27–Feb 2, 2025", "January 2025", "2025", ["red", "yellow"]],
    ["Jan 30, 2025", "Jan 27–Feb 2, 2025", "January 2025", "2025", ["green"]],
    ["Jan 18, 2025", "Jan 13–19, 2025", "January 2025", "2025", ["blue", "pink"]],
    ["Dec 27, 2024", "Dec 23–29, 2024", "December 2024", "2024", ["yellow"]],
    ["Dec 12, 2024", "Dec 9–15, 2024", "December 2024", "2024", ["pink", "red"]],
    ["Nov 8, 2024", "Nov 4–10, 2024", "November 2024", "2024", ["green"]],
    ["Oct 24, 2024", "Oct 21–27, 2024", "October 2024", "2024", ["blue", "red"]],
    ["Sep 6, 2023", "Sep 4–10, 2023", "September 2023", "2023", ["pink", "yellow"]],
    ["Aug 18, 2022", "Aug 15–21, 2022", "August 2022", "2022", ["green", "blue", "pink"]],
    ["Jul 14, 2021", "Jul 12–18, 2021", "July 2021", "2021", ["blue", "green"]],
    ["Jun 8, 2020", "Jun 8–14, 2020", "June 2020", "2020", ["red"]],
  ];
  // Show the opening window at each scale. Older tiles enter from below as it widens.
  const levels = [
    Array.from({ length: 9 }, (_, index) => [index % 3, Math.floor(index / 3), 1, 1]),
    [[1, 0, 2, 2], [0, 0, 1, 1], [0, 1, 1, 1], [2, 2, 1, 1], [1, 2, 1, 1], [0, 2, 1, 1]],
    [[2, 0, 1, 1], [1, 0, 1, 1], [0, 0, 1, 1], [1, 1, 2, 2], [0, 1, 1, 1], [0, 2, 1, 1]],
    [[2, 0, 1, 1], [1, 0, 1, 1], [0, 0, 1, 1], [2, 1, 1, 1], [0, 1, 2, 2], [2, 2, 1, 1]],
    [[2, 0, 1, 1], [0, 0, 2, 2], [2, 1, 1, 1], [2, 2, 1, 1], [1, 2, 1, 1], [0, 2, 1, 1]],
  ];
  const lastLevel = levels.length - 1;
  const photos = days.flatMap(([day, week, month, year, tones]) => tones.map((tone) => ({
    periods: [day, week, month, year], tone
  })));
  const tiles = photos.map(({ tone }, index) => {
    const photo = document.createElement("div");
    const caption = document.createElement("span");
    const dateLabel = document.createElement("span");
    const countLabel = document.createElement("small");
    photo.className = "timeline-demo-photo";
    photo.dataset.tone = tone;
    photo.toggleAttribute("data-soft-tone", index >= 5);
    caption.className = "timeline-demo-caption";
    caption.append(dateLabel, countLabel);
    photo.append(caption);
    preview.append(photo);
    return { photo, caption, dateLabel, countLabel };
  });

  function render() {
    const placements = levels[level];
    const grouped = level > 0;
    const groups = new Map();
    photos.forEach(({ periods }, index) => {
      const group = grouped ? periods[level - 1] : index;
      if (!groups.has(group)) groups.set(group, []);
      groups.get(group).push(tiles[index]);
    });

    const unit = 100 / 3;
    const gap = grouped ? 1.25 : 0.65;
    preview.toggleAttribute("data-grouped", grouped);
    [...groups].forEach(([date, members], index) => {
      const visible = index < placements.length;
      const [column, row, columns] = placements[index] ?? [index % 3, 3, 1, 1];
      const side = columns * unit - gap * 2;
      members.forEach(({ photo, caption, dateLabel, countLabel }, member) => {
        // Members stay rendered and move behind their cover at the same destination.
        const showsCover = visible && member === 0;
        photo.style.left = `${column * unit + gap}%`;
        photo.style.top = `${row * unit + gap}%`;
        photo.style.width = `${side}%`;
        photo.style.height = `${side}%`;
        photo.toggleAttribute("data-cover", showsCover);
        caption.hidden = !grouped || !showsCover;
        dateLabel.textContent = grouped ? date : "";
        countLabel.textContent = members.length === 1 ? "1 item" : `${members.length} items`;
      });
    });

    buttons.forEach((button, index) => button.setAttribute("aria-pressed", String(index === level)));
    demo.style.setProperty("--zoom-level", level);
  }

  let level = 0;
  let direction = 1;
  let playbackTimer;
  let demoVisible = false;
  let hovered = matchMedia("(hover: hover)").matches && hoverArea.matches(":hover");

  function schedulePlayback(delay = 1100) {
    clearTimeout(playbackTimer);
    if (!demoVisible || hovered || controls.querySelector(":focus-visible") || document.hidden || reducedMotion.matches) return;
    playbackTimer = setTimeout(() => {
      if (level === 0) direction = 1;
      if (level === lastLevel) direction = -1;
      demo.toggleAttribute("data-autoplay", true);
      level += direction;
      render();
      const reachedEnd = level === 0 || level === lastLevel;
      schedulePlayback(reachedEnd ? 1850 : 1300);
    }, delay);
  }

  render();
  demo.hidden = false;
  hoverArea.addEventListener("pointerenter", (event) => {
    if (event.pointerType === "touch") return;
    hovered = true;
    schedulePlayback();
  });
  hoverArea.addEventListener("pointerleave", (event) => {
    if (event.pointerType === "touch") return;
    hovered = false;
    schedulePlayback();
  });
  controls.addEventListener("focusin", () => schedulePlayback());
  controls.addEventListener("focusout", () => queueMicrotask(() => schedulePlayback()));
  buttons.forEach((button, index) => {
    button.addEventListener("click", () => {
      demo.toggleAttribute("data-autoplay", false);
      level = index;
      render();
      schedulePlayback();
    });
  });
  new IntersectionObserver(([entry]) => {
    demoVisible = entry.intersectionRatio >= 0.5;
    schedulePlayback();
  }, { threshold: 0.5 }).observe(demo);
  document.addEventListener("visibilitychange", () => schedulePlayback());
  reducedMotion.addEventListener("change", () => schedulePlayback());
}

setupTimelineDemo(document.querySelector(".timeline-demo-interactive"));

const downloadQualities = {
  photo: ["Thumbnail", "Preview", "Full", "Original"],
  video: ["Playback", "Original"],
};

function setupWorkflowDemo(demo, index) {
  const controls = demo.querySelector(".demo-levels");
  const buttons = [...controls.querySelectorAll("button")];
  const note = demo.querySelector(".workflow-note");
  const saveForm = demo.querySelector(".quality-save");
  const quality = saveForm?.querySelector("select");
  const announcement = saveForm?.querySelector("output");
  const lastStep = buttons.length - 1;
  const resumeDelay = 1600 + index * 650;
  let step = 0;
  let direction = 1;
  let timer;
  let visible = false;
  let hovered = matchMedia("(hover: hover)").matches && demo.matches(":hover");

  function showStep(next) {
    step = next;
    const { step: state, note: description } = buttons[step].dataset;
    demo.dataset.step = state;
    controls.style.setProperty("--zoom-level", step);
    buttons.forEach((button, position) => button.setAttribute("aria-pressed", String(position === step)));
    note.textContent = description;

    if (saveForm) {
      const choices = downloadQualities[state];
      saveForm.removeAttribute("data-saved");
      announcement.textContent = "";
      saveForm.inert = !choices;
      if (choices) quality.replaceChildren(...choices.map((name) => new Option(name)));
    }
  }

  function schedule(delay = resumeDelay) {
    clearTimeout(timer);
    if (!visible || hovered || document.hidden || reducedMotion.matches || demo.querySelector(":focus-visible, .quality-save :focus")) return;
    timer = setTimeout(() => {
      if (step === 0) direction = 1;
      if (step === lastStep) direction = -1;
      showStep(step + direction);
      schedule(step === 0 || step === lastStep ? 4300 : 3300);
    }, delay);
  }

  controls.style.setProperty("--demo-count", buttons.length);
  controls.hidden = false;
  buttons.forEach((button, next) => {
    button.addEventListener("click", () => {
      if (next !== step) showStep(next);
      schedule(4300);
    });
  });
  saveForm?.addEventListener("submit", (event) => {
    event.preventDefault();
    saveForm.setAttribute("data-saved", "");
    note.textContent = `On Device · Sample ${demo.dataset.step} saved as ${quality.value}`;
    announcement.textContent = note.textContent;
  });
  demo.addEventListener("pointerenter", (event) => {
    if (event.pointerType === "touch") return;
    hovered = true;
    schedule();
  });
  demo.addEventListener("pointerleave", (event) => {
    if (event.pointerType === "touch") return;
    hovered = false;
    schedule();
  });
  demo.addEventListener("focusin", () => schedule());
  demo.addEventListener("focusout", () => queueMicrotask(() => schedule()));
  new IntersectionObserver(([entry]) => {
    visible = entry.intersectionRatio >= 0.5;
    schedule();
  }, { threshold: 0.5 }).observe(demo);
  document.addEventListener("visibilitychange", () => schedule());
  reducedMotion.addEventListener("change", () => schedule());
}

document.querySelectorAll("[data-workflow]").forEach(setupWorkflowDemo);
