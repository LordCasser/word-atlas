/**
 * Pin bottom-anchored fixed UI to the VISUAL viewport.
 *
 * ArkWeb quirk (real devices): a page with a very tall scrollable area can
 * leave the LAYOUT viewport inflated (window.innerHeight > visualViewport.
 * height by the overhang). position:fixed;bottom:0 elements anchor to the
 * layout viewport, so the tabbar / sheets / palette end up partly off-screen
 * — the "bottom menu jumps on Atlas" bug. The visual viewport stays truthful,
 * so we publish the overhang as --vv-b and let fixed elements consume it.
 */

let started = false;

export function initVisualViewportInset(): () => void {
  if (started) return () => {};
  started = true;

  const root = document.documentElement;
  const apply = () => {
    const vv = window.visualViewport;
    if (!vv) return;
    const over = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
    root.style.setProperty("--vv-b", `${Math.round(over)}px`);
  };

  apply();
  window.visualViewport?.addEventListener("resize", apply);
  window.visualViewport?.addEventListener("scroll", apply);
  window.addEventListener("resize", apply);
  return () => {
    window.visualViewport?.removeEventListener("resize", apply);
    window.visualViewport?.removeEventListener("scroll", apply);
    window.removeEventListener("resize", apply);
  };
}
