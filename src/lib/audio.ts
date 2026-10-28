import { duck } from "./sound";

let current: HTMLAudioElement | null = null;
let token = 0;

export function stopAudio() {
  token++;
  current?.pause();
  current = null;
  if ("speechSynthesis" in window) window.speechSynthesis.cancel();
}

/** Play a recording, falling back to the device voice. Resolves when playback ends. */
export async function play(url: string | null | undefined, text: string, accent: "uk" | "us" = "uk", rate = 1) {
  duck(true);
  try {
    return await speak(url, text, accent, rate);
  } finally {
    duck(false);
  }
}

/**
 * Device-TTS availability. Webviews without a speech engine (e.g. ArkWeb)
 * expose speechSynthesis but ship zero voices and silently drop utterances,
 * which made speak buttons feel dead. Probe voices once, bounded wait.
 */
let voicesProbe: Promise<boolean> | null = null;
function hasVoices(): Promise<boolean> {
  if (!("speechSynthesis" in window)) return Promise.resolve(false);
  if (speechSynthesis.getVoices().length > 0) return Promise.resolve(true);
  voicesProbe ??= new Promise<boolean>((resolve) => {
    const settle = (ok: boolean) => {
      speechSynthesis.onvoiceschanged = null;
      resolve(ok);
    };
    const timer = setTimeout(() => settle(speechSynthesis.getVoices().length > 0), 1500);
    speechSynthesis.onvoiceschanged = () => {
      clearTimeout(timer);
      settle(speechSynthesis.getVoices().length > 0);
    };
  });
  return voicesProbe;
}

async function speak(url: string | null | undefined, text: string, accent: "uk" | "us", rate: number) {
  stopAudio();
  const mine = ++token;
  if (url) {
    const a = new Audio(url);
    a.playbackRate = rate;
    current = a;
    try {
      await a.play();
      await new Promise<void>((r) => {
        a.onended = () => r();
        a.onpause = () => r();
      });
      return "recorded" as const;
    } catch {
      if (mine !== token) return "stopped" as const;
      current = null;
    }
  }
  if (!("speechSynthesis" in window)) return "unsupported" as const;
  if (!(await hasVoices())) return "unsupported" as const;
  const u = new SpeechSynthesisUtterance(text);
  u.lang = accent === "uk" ? "en-GB" : "en-US";
  u.rate = rate * 0.95;
  const voices = speechSynthesis.getVoices().filter((v) => v.lang.replace("_", "-") === u.lang);
  const best = voices.find((v) => /premium|enhanced|natural|google/i.test(v.name)) || voices[0];
  if (best) u.voice = best;
  await new Promise<void>((r) => {
    u.onend = () => r();
    u.onerror = () => r();
    speechSynthesis.speak(u);
  });
  return "device" as const;
}
