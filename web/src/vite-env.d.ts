/// <reference types="vite/client" />

// noVNC est publié en JavaScript pur : on décrit juste ce qu'on utilise.
declare module '@novnc/novnc/lib/rfb' {
  export default class RFB extends EventTarget {
    constructor(
      target: HTMLElement,
      url: string,
      options?: {
        credentials?: { password?: string; username?: string; target?: string }
        shared?: boolean
        repeaterID?: string
        wsProtocols?: string[]
      },
    )
    scaleViewport: boolean
    resizeSession: boolean
    background: string
    viewOnly: boolean
    disconnect(): void
    focus(): void
    blur(): void
    sendCtrlAltDel(): void
    sendKey(keysym: number, code?: string, down?: boolean): void
    machineReboot(): void
    clipboardPasteFrom(text: string): void
  }
}
