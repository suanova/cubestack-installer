export default function Field({ label, error, action, ...props }) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      <span className={'field-input-wrap' + (action ? ' has-action' : '')}>
        <input className={'input' + (error ? ' input-error' : '')} {...props} />
        {action}
      </span>
      {error && <span className="field-error">{error}</span>}
    </label>
  )
}

export function Select({ label, error, children, ...props }) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      <select className={'input' + (error ? ' input-error' : '')} {...props}>
        {children}
      </select>
      {error && <span className="field-error">{error}</span>}
    </label>
  )
}

export function CheckboxCard({ label, sub, checked, onChange }) {
  return (
    <label className={'checkbox-card' + (checked ? ' checked' : '')}>
      <input type="checkbox" checked={checked} onChange={onChange} />
      <span className="cb-name">{label}</span>
      {sub && <span className="cb-sub">{sub}</span>}
    </label>
  )
}
