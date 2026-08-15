/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        ink: {
          950: '#080a0f',
          900: '#0b0e14',
          850: '#0f131b',
          800: '#141924',
          750: '#1a202d',
          700: '#232a39',
          600: '#323b4d',
          500: '#4a5567',
        },
        mist: {
          400: '#7d8a9e',
          300: '#9aa7bb',
          200: '#c2ccdb',
          100: '#e6ecf5',
        },
        accent: {
          DEFAULT: '#00d4aa',
          soft: '#00d4aa22',
          dim: '#0b8f77',
        },
        danger: '#ff4d6d',
        warn: '#ffb020',
        info: '#3b9dff',
        violet: '#a97bff',
      },
      fontFamily: {
        sans: ['Inter', 'ui-sans-serif', 'system-ui', '-apple-system', 'Segoe UI', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      boxShadow: {
        panel: '0 1px 0 0 rgba(255,255,255,0.03) inset, 0 8px 24px -12px rgba(0,0,0,0.8)',
        glow: '0 0 24px -6px rgba(0,212,170,0.45)',
      },
      keyframes: {
        pulseRing: {
          '0%': { transform: 'scale(0.85)', opacity: '0.8' },
          '70%': { transform: 'scale(1.6)', opacity: '0' },
          '100%': { opacity: '0' },
        },
        slideUp: {
          from: { opacity: '0', transform: 'translateY(8px)' },
          to: { opacity: '1', transform: 'translateY(0)' },
        },
        shimmer: {
          '100%': { transform: 'translateX(100%)' },
        },
      },
      animation: {
        pulseRing: 'pulseRing 2s cubic-bezier(0.4,0,0.6,1) infinite',
        slideUp: 'slideUp 0.25s ease-out both',
        shimmer: 'shimmer 1.6s infinite',
      },
    },
  },
  plugins: [],
}
