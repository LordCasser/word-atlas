import { duck } from "./sound";

declare global {
  interface Window {
    HarmonyShell?: {
      readBackup(): string;
      ttsSpeak(text: string, rate: number): string;
      ttsStop(): void;
    };
    __waTtsDone?: (id: string, ok: boolean) => void;
  }
}

let current: HTMLAudioElement | null = null;
let token = 0;

/**
 * Native TTS bridge (HarmonyOS HAP): request ids waiting for the shell to
 * report completion via window.__waTtsDone. A generous timeout backstops
 * missed callbacks so buttons never hang forever.
 */
const nativeWaiters = new Map<string, (ok: boolean) => void>();
let usingNative = false;

if (typeof window !== "undefined" && !window.__waTtsDone) {
  window.__waTtsDone = (id, ok) => {
    const waiter = nativeWaiters.get(id);
    if (waiter) {
      nativeWaiters.delete(id);
      waiter(ok);
    }
  };
}

async function nativeSpeak(text: string, rate: number): Promise<boolean> {
  const shell = window.HarmonyShell;
  if (!shell || typeof shell.ttsSpeak !== "function") return false;
  return new Promise<boolean>((resolve) => {
    let settled = false;
    let id = "";
    const finish = (ok: boolean) => {
      if (settled) return;
      settled = true;
      window.clearTimeout(timer);
      if (id) nativeWaiters.delete(id);
      resolve(ok);
    };
    const timer = window.setTimeout(() => finish(true), 20000);
    id = shell.ttsSpeak(text, rate);
    if (!id) {
      finish(false);
      return;
    }
    nativeWaiters.set(id, finish);
  });
}

export function stopAudio() {
  token++;
  if (usingNative) {
    usingNative = false;
    try {
      window.HarmonyShell?.ttsStop();
    } catch {
      /* bridge optional */
    }
  }
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
  // Native shell TTS first (HarmonyOS ArkWeb has no speechSynthesis voices).
  const shell = window.HarmonyShell;
  if (shell && typeof shell.ttsSpeak === "function") {
    usingNative = true;
    const ok = await nativeSpeak(text, rate);
    usingNative = false;
    if (mine !== token) return "stopped" as const;
    if (ok) return "device" as const;
    // Engine unavailable → fall through; the voiceless-synth check below
    // reports "unsupported" so the button can explain itself.
  }
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
