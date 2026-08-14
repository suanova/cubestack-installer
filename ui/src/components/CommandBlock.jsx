import { useState } from 'react'
import { useToast } from './Toast'
import { useI18n } from '../i18n'

export default function CommandBlock({ script, label }) {
  const { t } = useI18n()
  const toast = useToast()
  const [copied, setCopied] = useState(false)

  async function copy() {
    try {
      await navigator.clipboard.writeText(script)
    } catch {
      const ta = document.createElement('textarea')
      ta.value = script
      document.body.appendChild(ta)
      ta.select()
      document.execCommand('copy')
      document.body.removeChild(ta)
    }
    setCopied(true)
    toast(t('hosts.copied'))
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <div className="cmd-block">
      <div className="cmd-head">
        <span className="cmd-label">{label || t('hosts.cmdTitle')}</span>
        <button className="btn btn-ghost btn-sm" onClick={copy}>
          {copied ? '✓' : t('hosts.copy')}
        </button>
      </div>
      <pre className="cmd-pre"><code>{script}</code></pre>
    </div>
  )
}
