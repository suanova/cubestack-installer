import { useCallback, useEffect, useState } from 'react'
import { hostApi } from '../api/client'
import CommandBlock from '../components/CommandBlock'
import Field from '../components/Field'
import Modal from '../components/Modal'
import { useToast } from '../components/Toast'
import { useAuth } from '../context/AuthContext'
import { useI18n } from '../i18n'

const emptyForm = { name: '', ip: '', ssh_user: 'ubuntu', ssh_port: '22', cpu_cores: '', memory_gb: '', disk_gb: '' }
const WIZARD_STEPS = [
  { key: 'info', labelKey: 'hosts.wizard.step1' },
  { key: 'ssh', labelKey: 'hosts.wizard.step2' },
  { key: 'deps', labelKey: 'hosts.wizard.step3' },
  { key: 'confirm', labelKey: 'hosts.wizard.step4' },
]

function parseReport(h) {
  if (!h.check_report) return null
  try {
    return JSON.parse(h.check_report)
  } catch {
    return null
  }
}

// 生成宿主机初始化 Shell 脚本:
// 第 1 步 ssh-copy-id 免密 -> 校验生效 -> 生效后才执行 libvirt 依赖安装等后续操作
function buildBootstrapScript(ip, sshUser, sshPort, t) {
  const p = sshPort || 22
  const u = sshUser || 'ubuntu'
  const host = u + '@' + ip
  const remote = (cmd) => 'ssh -p ' + p + ' ' + host + " '" + cmd + "'"
  const remoteBatch = 'ssh -p ' + p + ' -o BatchMode=yes -o ConnectTimeout=5 ' + host
  const ind = '  '
  return [
    t('hosts.sc.head'),
    '',
    t('hosts.sc.userCreate'),
    '',
    t('hosts.sc.step1'),
    'ssh-copy-id -i ~/.ssh/id_rsa.pub -p ' + p + ' ' + host,
    '',
    t('hosts.sc.step2'),
    'if ' + remoteBatch + " 'echo ok' >/dev/null 2>&1; then",
    ind + "echo '" + t('hosts.sc.ok') + "'",
    ind,
    ind + t('hosts.sc.step3'),
    ind + remote('cat /etc/os-release | grep PRETTY_NAME'),
    ind,
    ind + t('hosts.sc.step4'),
    ind + remote('sudo apt-get update && sudo apt-get install -y virtinst libvirt-clients qemu-utils qemu-system-x86 cloud-image-utils libvirt-daemon-system'),
    ind,
    ind + t('hosts.sc.step5'),
    ind + remote('sudo systemctl enable --now libvirtd'),
    ind,
    ind + t('hosts.sc.step6'),
    ind + remote('ls -l /dev/kvm'),
    ind,
    ind + t('hosts.sc.step7'),
    ind + remote('command -v mc >/dev/null 2>&1 || sudo wget -q -O /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc && sudo chmod +x /usr/local/bin/mc'),
    'else',
    ind + "echo '" + t('hosts.sc.fail') + "'",
    'fi',
    '',
  ].join('\n')
}

// 向导步骤②:仅免密配置(ssh-copy-id + 生效校验),依赖安装单独成步骤
function buildSshScript(ip, sshUser, sshPort, t) {
  const p = sshPort || 22
  const u = sshUser || 'ubuntu'
  const host = u + '@' + ip
  const remoteBatch = 'ssh -p ' + p + ' -o BatchMode=yes -o ConnectTimeout=5 ' + host
  const ind = '  '
  return [
    t('hosts.sc.head'),
    '',
    t('hosts.sc.userCreate'),
    '',
    t('hosts.sc.step1'),
    'ssh-copy-id -i ~/.ssh/id_rsa.pub -p ' + p + ' ' + host,
    '',
    t('hosts.sc.step2'),
    'if ' + remoteBatch + " 'echo ok' >/dev/null 2>&1; then",
    ind + "echo '" + t('hosts.sc.ok') + "'",
    'else',
    ind + "echo '" + t('hosts.sc.fail') + "'",
    ind + 'exit 1',
    'fi',
    '',
  ].join('\n')
}

// 向导步骤③:依赖安装(免密生效的前提下执行系统确认 / apt 安装 / libvirtd / /dev/kvm)
function buildDepsScript(ip, sshUser, sshPort, t) {
  const p = sshPort || 22
  const u = sshUser || 'ubuntu'
  const host = u + '@' + ip
  const remote = (cmd) => 'ssh -p ' + p + ' ' + host + " '" + cmd + "'"
  const remoteBatch = 'ssh -p ' + p + ' -o BatchMode=yes -o ConnectTimeout=5 ' + host
  const ind = '  '
  return [
    t('hosts.sc.head'),
    '',
    t('hosts.sc.step2'),
    'if ' + remoteBatch + " 'echo ok' >/dev/null 2>&1; then",
    ind + "echo '" + t('hosts.sc.ok') + "'",
    ind,
    ind + t('hosts.sc.step3'),
    ind + remote('cat /etc/os-release | grep PRETTY_NAME'),
    ind,
    ind + t('hosts.sc.step4'),
    ind + remote('sudo apt-get update && sudo apt-get install -y virtinst libvirt-clients qemu-utils qemu-system-x86 cloud-image-utils libvirt-daemon-system'),
    ind,
    ind + t('hosts.sc.step5'),
    ind + remote('sudo systemctl enable --now libvirtd'),
    ind,
    ind + t('hosts.sc.step6'),
    ind + remote('ls -l /dev/kvm'),
    ind,
    ind + t('hosts.sc.step7'),
    ind + remote('command -v mc >/dev/null 2>&1 || sudo wget -q -O /usr/local/bin/mc https://dl.min.io/client/mc/release/linux-amd64/mc && sudo chmod +x /usr/local/bin/mc'),
    'else',
    ind + "echo '" + t('hosts.sc.fail') + "'",
    'fi',
    '',
  ].join('\n')
}

export default function HostsPage() {
  const { token } = useAuth()
  const { t } = useI18n()
  const toast = useToast()

  const [hosts, setHosts] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [showWizard, setShowWizard] = useState(false)
  const [wiz, setWiz] = useState({
    step: 0,
    form: emptyForm,
    errors: {},
    sshCheck: { loading: false, state: null }, // null | ok | fail
    depCheck: { loading: false, data: null, error: '' },
    submitting: false,
    created: null, // 添加成功后保存返回的宿主机
  })
  const [checkingId, setCheckingId] = useState(null)
  const [deleting, setDeleting] = useState(null)
  const [report, setReport] = useState(null) // { host, data }
  const [cmdHost, setCmdHost] = useState(null) // 查看初始化命令的主机

  const load = useCallback(() => {
    setLoading(true)
    hostApi
      .list(token)
      .then(setHosts)
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false))
  }, [token])

  useEffect(() => {
    load()
  }, [load])

  // ---------- 向导 ----------
  const updateForm = (next) => {
    // 连接信息变化后,之前的验证结果不再有效
    setWiz((w) => ({
      ...w,
      form: next,
      errors: {},
      sshCheck: { loading: false, state: null },
      depCheck: { loading: false, data: null, error: '' },
    }))
  }

  const resetWizard = () => {
    setShowWizard(false)
    setWiz({ step: 0, form: emptyForm, errors: {}, sshCheck: { loading: false, state: null }, depCheck: { loading: false, data: null, error: '' }, submitting: false, created: null })
  }

  const buildPayload = (requireName) => {
    const fm = wiz.form
    return {
      name: (fm.name.trim() || (requireName ? '' : 'host-' + (fm.ip.trim() || 'unknown'))).slice(0, 80),
      ip: fm.ip.trim(),
      ssh_user: fm.ssh_user.trim() || 'root',
      ssh_port: parseInt(fm.ssh_port, 10) || 22,
      cpu_cores: fm.cpu_cores ? parseInt(fm.cpu_cores, 10) : null,
      memory_gb: fm.memory_gb ? parseInt(fm.memory_gb, 10) : null,
      disk_gb: fm.disk_gb ? parseInt(fm.disk_gb, 10) : null,
    }
  }

  const validateStepInfo = () => {
    const fm = wiz.form
    const errors = {}
    if (!fm.ip.trim()) errors.ip = t('hosts.wizard.errIp')
    else if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(fm.ip.trim())) errors.ip = t('hosts.wizard.errIpFormat')
    if (fm.name.trim().length < 2) errors.name = t('hosts.wizard.errName')
    return errors
  }

  const goNext = () => {
    if (wiz.step === 0) {
      const errors = validateStepInfo()
      if (Object.keys(errors).length) return setWiz((w) => ({ ...w, errors }))
      setWiz((w) => ({ ...w, step: 1 }))
    } else if (wiz.step < 3) {
      setWiz((w) => ({ ...w, step: w.step + 1 }))
    }
  }

  const goPrev = () => setWiz((w) => ({ ...w, step: Math.max(0, w.step - 1) }))

  function runSshVerify() {
    setWiz((w) => ({ ...w, sshCheck: { loading: true, state: null } }))
    hostApi
      .precheck(buildPayload(false), token)
      .then((h) => {
        const rep = parseReport(h)
        setWiz((w) => ({ ...w, sshCheck: { loading: false, state: h.status === 'online' ? 'ok' : 'fail', report: rep } }))
      })
      .catch((err) => setWiz((w) => ({ ...w, sshCheck: { loading: false, state: 'fail', error: err.message } })))
  }

  function runDepCheck() {
    setWiz((w) => ({ ...w, depCheck: { loading: true, data: null, error: '' } }))
    hostApi
      .precheck(buildPayload(false), token)
      .then((h) => setWiz((w) => ({ ...w, depCheck: { loading: false, data: { host: h, report: parseReport(h) }, error: '' } })))
      .catch((err) => setWiz((w) => ({ ...w, depCheck: { loading: false, data: null, error: err.message } })))
  }

  function submitAdd() {
    setWiz((w) => ({ ...w, submitting: true }))
    hostApi
      .create(buildPayload(true), token)
      .then((h) => {
        setHosts((list) => [...list, h])
        setWiz((w) => ({ ...w, submitting: false, created: h }))
      })
      .catch((err) => {
        toast(err.message, 'error')
        setWiz((w) => ({ ...w, submitting: false }))
      })
  }

  // ---------- 已有宿主机:环境检测 / 删除 ----------
  function doCheck(id) {
    setCheckingId(id)
    hostApi
      .check(id, token)
      .then((h) => {
        setHosts((list) => list.map((x) => (x.id === h.id ? h : x)))
        const data = parseReport(h)
        if (data) setReport({ host: h, data })
        const osLabel = h.os_ok === true ? t('hosts.osOk') : h.os_ok === false ? t('hosts.osFail') : t('hosts.osUnknown')
        const lvLabel = h.libvirt_ready === true ? t('hosts.libvirtOk') : h.libvirt_ready === false ? t('hosts.libvirtFail') : t('hosts.unk')
        toast(t('hosts.checkDone', { name: h.name, status: osLabel + ' · ' + lvLabel }), h.os_ok && h.libvirt_ready ? 'success' : 'error')
      })
      .catch((err) => toast(err.message, 'error'))
      .finally(() => setCheckingId(null))
  }

  function confirmDelete() {
    if (!deleting) return
    hostApi
      .remove(deleting.id, token)
      .then(() => {
        setHosts((list) => list.filter((h) => h.id !== deleting.id))
        toast(t('hosts.deleted', { name: deleting.name }))
        setDeleting(null)
      })
      .catch((err) => {
        toast(err.message, 'error')
        setDeleting(null)
      })
  }

  if (loading) {
    return (
      <div className="page-loader">
        <div className="spinner" />
      </div>
    )
  }

  const rd = report?.data

  return (
    <div>
      <div className="page-head">
        <div>
          <h1 className="page-title">{t('hosts.title')}</h1>
          <p className="page-desc">{t('hosts.desc')}</p>
        </div>
        <button className="btn btn-primary" onClick={() => setShowWizard(true)}>＋ {t('hosts.add')}</button>
      </div>

      {error && <div className="alert">{error}</div>}

      <div className="card">
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>{t('common.name')}</th>
                <th>{t('hosts.ip')}</th>
                <th>SSH</th>
                <th>{t('hosts.spec')}</th>
                <th>{t('hosts.envCol')}</th>
                <th>{t('common.status')}</th>
                <th className="th-actions">{t('common.actions')}</th>
              </tr>
            </thead>
            <tbody>
              {hosts.map((h) => (
                <tr key={h.id}>
                  <td>
                    <div className="user-cell">
                      <span className="avatar avatar-sm">{h.name.slice(0, 1).toUpperCase()}</span>
                      <div>
                        <div className="cell-name">
                          {h.name}
                          {h.is_demo && <span className="tag-demo">{t('common.demo')}</span>}
                        </div>
                        <div className="cell-sub">{t('common.id')} #{h.id}</div>
                      </div>
                    </div>
                  </td>
                  <td className="td-mono">{h.ip}</td>
                  <td className="td-mono td-muted">{h.ssh_user}@:{h.ssh_port}</td>
                  <td>
                    <div className="spec">
                      <span>{h.cpu_cores ? h.cpu_cores + ' CPU' : '-'}</span>
                      <span>{h.memory_gb ? h.memory_gb + ' GB' : '-'}</span>
                      <span>{h.disk_gb ? h.disk_gb + ' GB' : '-'}</span>
                    </div>
                  </td>
                  <td>
                    <div className="env-cell">
                      <span className={'badge ' + (h.os_ok === true ? 'badge-success' : h.os_ok === false ? 'badge-failed' : 'badge-muted')}>
                        {h.os_ok === true ? t('hosts.osOk') : h.os_ok === false ? t('hosts.osFail') : t('hosts.osUnknown')}
                      </span>
                      <span className={'badge ' + (h.libvirt_ready === true ? 'badge-success' : h.libvirt_ready === false ? 'badge-failed' : 'badge-muted')}>
                        {h.libvirt_ready === true ? t('hosts.libvirtOk') : h.libvirt_ready === false ? t('hosts.libvirtFail') : t('hosts.unk')}
                      </span>
                    </div>
                  </td>
                  <td>
                    <span className={'badge badge-' + (h.status === 'online' ? 'success' : h.status === 'offline' ? 'failed' : 'muted')}>
                      {h.status === 'online' ? t('status.online') : h.status === 'offline' ? t('status.offline') : t('status.unknown')}
                    </span>
                  </td>
                  <td>
                    <div className="td-actions">
                      <button className="btn btn-ghost btn-sm" disabled={checkingId === h.id} onClick={() => doCheck(h.id)}>
                        {checkingId === h.id ? t('hosts.envChecking') : t('hosts.envCheck')}
                      </button>
                      <button className="btn btn-ghost btn-sm" onClick={() => setCmdHost(h)}>
                        {t('hosts.cmdBtn')}
                      </button>
                      <button className="btn btn-danger btn-sm" onClick={() => setDeleting(h)}>
                        {t('common.delete')}
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
              {hosts.length === 0 && (
                <tr>
                  <td colSpan="7" className="td-empty">{t('hosts.empty')}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* ============ 添加宿主机向导 ============ */}
      {showWizard && (
        <Modal title={t('hosts.wizard.title')} onClose={resetWizard} width="720px">
          {wiz.created ? (
            /* ---------- 完成视图 ---------- */
            <div>
              <div className="wizard-done-ico">{wiz.created.status === 'online' ? '🎉' : '⚠️'}</div>
              <h3 className="modal-title" style={{ textAlign: 'center', marginBottom: 6 }}>{t('hosts.wizard.doneTitle')}</h3>
              <p className="modal-text" style={{ textAlign: 'center', marginBottom: 16 }}>{t('hosts.wizard.doneDesc', { name: wiz.created.name })}</p>
              {wiz.created.status === 'offline' && <div className="alert">{t('hosts.wizard.doneOffline')}</div>}
              <div className="modal-actions">
                <button className="btn btn-primary" onClick={resetWizard}>{t('hosts.wizard.close')}</button>
              </div>
            </div>
          ) : (
            <>
              <p className="cmd-note cmd-note-top">{t('hosts.wizard.intro')}</p>

              {/* 步骤指示器 */}
              <div className="wizard-steps">
                {WIZARD_STEPS.map((s, i) => (
                  <div key={s.key} className={'wizard-step' + (i === wiz.step ? ' active' : i < wiz.step ? ' done' : '')}>
                    <span className="wizard-step-dot">{i < wiz.step ? '✓' : String(i + 1)}</span>
                    <span className="wizard-step-label">{t(s.labelKey)}</span>
                  </div>
                ))}
              </div>

              <div className="wizard-body">
                {/* 步骤 1:连接信息 */}
                {wiz.step === 0 && (
                  <>
                    <p className="wizard-desc">{t('hosts.wizard.step1Desc')}</p>
                    <form onSubmit={(e) => { e.preventDefault(); goNext() }}>
                      <div className="grid-2">
                        <Field label={t('hosts.ip')} placeholder="192.168.10.13" value={wiz.form.ip} required
                          error={wiz.errors.ip}
                          onChange={(e) => updateForm({ ...wiz.form, ip: e.target.value })} />
                        <Field label={t('hosts.sshUser')} value={wiz.form.ssh_user}
                          onChange={(e) => updateForm({ ...wiz.form, ssh_user: e.target.value })} />
                      </div>
                      <div className="grid-2">
                        <Field label={t('hosts.sshPort')} value={wiz.form.ssh_port}
                          onChange={(e) => updateForm({ ...wiz.form, ssh_port: e.target.value })} />
                        <Field label={t('hosts.name')} placeholder="node3" value={wiz.form.name} required
                          error={wiz.errors.name}
                          onChange={(e) => updateForm({ ...wiz.form, name: e.target.value })} />
                      </div>
                      <div className="grid-3">
                        <Field label={t('hosts.cpu')} placeholder="-" value={wiz.form.cpu_cores}
                          onChange={(e) => updateForm({ ...wiz.form, cpu_cores: e.target.value })} />
                        <Field label={t('hosts.mem')} placeholder="-" value={wiz.form.memory_gb}
                          onChange={(e) => updateForm({ ...wiz.form, memory_gb: e.target.value })} />
                        <Field label={t('hosts.disk')} placeholder="-" value={wiz.form.disk_gb}
                          onChange={(e) => updateForm({ ...wiz.form, disk_gb: e.target.value })} />
                      </div>
                    </form>
                  </>
                )}

                {/* 步骤 2:免密配置 */}
                {wiz.step === 1 && (
                  <>
                    <p className="wizard-desc">{t('hosts.wizard.step2Title')}</p>
                    <p className="cmd-note">{t('hosts.wizard.step2Desc')}</p>
                    <CommandBlock script={buildSshScript(wiz.form.ip.trim(), wiz.form.ssh_user, wiz.form.ssh_port, t)} label={t('hosts.wizard.sshCmdLabel')} />
                    <p className="user-note">{t('hosts.userNote')}</p>
                    <div style={{ marginTop: 14 }}>
                      <button className="btn btn-ghost" disabled={wiz.sshCheck.loading} onClick={runSshVerify}>
                        {wiz.sshCheck.loading ? t('hosts.wizard.verifying') : '✓ ' + t('hosts.wizard.verify')}
                      </button>
                      <span className="cmd-note" style={{ marginLeft: 10 }}>{t('hosts.wizard.verifyHint')}</span>
                    </div>
                    {wiz.sshCheck.state && (
                      <div className={'verify-box verify-box-' + (wiz.sshCheck.state === 'ok' ? 'ok' : 'fail')}>
                        <span className="verify-ico">{wiz.sshCheck.state === 'ok' ? '✓' : '✗'}</span>
                        <div>
                          {wiz.sshCheck.state === 'ok' ? t('hosts.wizard.verifyOk') : (wiz.sshCheck.error || t('hosts.wizard.verifyFail'))}
                          {wiz.sshCheck.report?.simulated && <div className="report-detail">{t('hosts.simNote')}</div>}
                        </div>
                      </div>
                    )}
                  </>
                )}

                {/* 步骤 3:依赖安装 */}
                {wiz.step === 2 && (
                  <>
                    <p className="wizard-desc">{t('hosts.wizard.step3Title')}</p>
                    <p className="cmd-note">{t('hosts.wizard.step3Desc')}</p>
                    <CommandBlock script={buildDepsScript(wiz.form.ip.trim(), wiz.form.ssh_user, wiz.form.ssh_port, t)} label={t('hosts.wizard.depsCmdLabel')} />
                    <div style={{ marginTop: 14 }}>
                      <button className="btn btn-ghost" disabled={wiz.depCheck.loading} onClick={runDepCheck}>
                        {wiz.depCheck.loading ? t('hosts.wizard.depChecking') : '⚙ ' + t('hosts.wizard.depCheck')}
                      </button>
                    </div>
                    {wiz.depCheck.error && <div className="verify-box verify-box-fail"><span className="verify-ico">✗</span><span>{wiz.depCheck.error}</span></div>}
                    {wiz.depCheck.data && <EnvSummary report={wiz.depCheck.data.report} t={t} />}
                  </>
                )}

                {/* 步骤 4:确认添加 */}
                {wiz.step === 3 && (
                  <>
                    <p className="wizard-desc">{t('hosts.wizard.step4Desc')}</p>
                    <div className="wizard-summary">
                      <div className="wizard-summary-row"><span>{t('hosts.name')}</span><span>{wiz.form.name.trim() || '-'}</span></div>
                      <div className="wizard-summary-row"><span>{t('hosts.ip')}</span><span className="td-mono">{wiz.form.ip.trim()}</span></div>
                      <div className="wizard-summary-row"><span>SSH</span><span className="td-mono">{(wiz.form.ssh_user.trim() || 'root') + '@:' + (parseInt(wiz.form.ssh_port, 10) || 22)}</span></div>
                      <div className="wizard-summary-row"><span>{t('hosts.spec')}</span><span>{(wiz.form.cpu_cores || '-') + ' CPU · ' + (wiz.form.memory_gb || '-') + ' GB · ' + (wiz.form.disk_gb || '-') + ' GB'}</span></div>
                      <div className="wizard-summary-row">
                        <span>{t('hosts.wizard.sshState')}</span>
                        <span className={'wizard-state-chip ' + (wiz.sshCheck.state === 'ok' ? 'wizard-state-ok' : 'wizard-state-no')}>
                          {wiz.sshCheck.state === 'ok' ? '✓ ' + t('hosts.wizard.ready') : t('hosts.wizard.notReady')}
                        </span>
                      </div>
                      <div className="wizard-summary-row">
                        <span>{t('hosts.wizard.envState')}</span>
                        <span className={'wizard-state-chip ' + (wiz.depCheck.data?.host?.status === 'online' && wiz.depCheck.data?.host?.libvirt_ready ? 'wizard-state-ok' : 'wizard-state-no')}>
                          {wiz.depCheck.data ? '✓ ' + t('hosts.wizard.ready') : t('hosts.wizard.notReady')}
                        </span>
                      </div>
                    </div>
                    {(wiz.sshCheck.state !== 'ok') && <p className="cmd-note" style={{ marginTop: 10 }}>{t('hosts.wizard.skipVerify')}</p>}
                  </>
                )}
              </div>

              {/* 底部导航 */}
              <div className="wizard-foot">
                <span className="wizard-foot-left">{t('hosts.wizard.intro')}</span>
                <div className="wizard-foot-actions">
                  {wiz.step > 0 && (
                    <button className="btn btn-ghost" onClick={goPrev}>{t('hosts.wizard.prev')}</button>
                  )}
                  {wiz.step < 3 ? (
                    <button className="btn btn-primary" onClick={goNext}>{t('hosts.wizard.next')} →</button>
                  ) : (
                    <button className="btn btn-primary" disabled={wiz.submitting} onClick={submitAdd}>
                      {wiz.submitting ? t('hosts.wizard.adding') : t('hosts.wizard.submit')}
                    </button>
                  )}
                </div>
              </div>
            </>
          )}
        </Modal>
      )}

      {cmdHost && (
        <Modal title={t('hosts.cmdModalTitle', { name: cmdHost.name })} onClose={() => setCmdHost(null)} width="640px">
          <p className="cmd-note">{t('hosts.cmdHint')} · {t('hosts.cmdSudoNote')}</p>
          <CommandBlock script={buildBootstrapScript(cmdHost.ip, cmdHost.ssh_user, cmdHost.ssh_port, t)} />
          <p className="user-note">{t('hosts.userNote')}</p>
          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setCmdHost(null)}>{t('common.close')}</button>
          </div>
        </Modal>
      )}

      {report && rd && (
        <Modal title={t('hosts.envTitle') + ' · ' + report.host.name} onClose={() => setReport(null)} width="560px">
          {rd.simulated && <p className="alert alert-info">{t('hosts.simNote')}</p>}
          {rd.ssh === 'unreachable' && <p className="alert">{t('hosts.unreachable')}</p>}

          <div className="report-row">
            <span className="report-label">{t('hosts.os')}</span>
            <div className="report-value">
              <strong>{rd.os?.detected || '-'}</strong>
              <span className={'badge ' + (rd.os?.ok ? 'badge-success' : 'badge-failed')}>
                {rd.os?.ok ? t('hosts.osOk') : t('hosts.osFail')}
              </span>
            </div>
          </div>

          <div className="report-row">
            <span className="report-label">{t('hosts.deps')}</span>
            <div className="report-value">
              <div className="chip-row">
                {(rd.packages?.installed || []).map((b) => (
                  <span key={b} className="chip chip-ok">{b}</span>
                ))}
                {(rd.packages?.missing || []).map((b) => (
                  <span key={b} className="chip chip-bad">{b}</span>
                ))}
              </div>
              <span className={'badge ' + (rd.packages?.ok ? 'badge-success' : 'badge-failed')}>
                {rd.packages?.ok ? t('hosts.libvirtOk') : t('hosts.libvirtFail')}
              </span>
            </div>
          </div>

          <div className="report-row">
            <span className="report-label">{t('hosts.service')}</span>
            <div className="report-value">
              <span className={'badge ' + (rd.libvirtd?.active ? 'badge-success' : 'badge-failed')}>
                {rd.libvirtd?.active ? t('hosts.serviceActive') : t('hosts.serviceDown')}
              </span>
              <span className="report-detail">{rd.libvirtd?.detail}</span>
            </div>
          </div>

          <div className="report-row">
            <span className="report-label">{t('hosts.kvm')}</span>
            <div className="report-value">
              <span className={'badge ' + (rd.kvm?.present ? 'badge-success' : 'badge-failed')}>
                {rd.kvm?.present ? t('hosts.kvmYes') : t('hosts.kvmNo')}
              </span>
              <span className="report-detail">{rd.kvm?.detail}</span>
            </div>
          </div>

          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setReport(null)}>{t('common.close')}</button>
            <button className="btn btn-primary" onClick={() => doCheck(report.host.id)} disabled={checkingId === report.host.id}>
              {checkingId === report.host.id ? t('hosts.envChecking') : t('hosts.envCheck')}
            </button>
          </div>
        </Modal>
      )}

      {deleting && (
        <Modal title={t('hosts.deleteTitle')} onClose={() => setDeleting(null)}>
          <p className="modal-text">{t('hosts.deleteMsg', { name: deleting.name, ip: deleting.ip })}</p>
          <div className="modal-actions">
            <button className="btn btn-ghost" onClick={() => setDeleting(null)}>{t('common.cancel')}</button>
            <button className="btn btn-danger" onClick={confirmDelete}>{t('common.confirm')}</button>
          </div>
        </Modal>
      )}
    </div>
  )
}

// 环境预检结果摘要(向导步骤③内联展示)
function EnvSummary({ report, t }) {
  if (!report) return null
  const ok = report.os?.ok && report.packages?.ok && report.libvirtd?.active && report.kvm?.present
  return (
    <div className={'verify-box verify-box-' + (ok ? 'ok' : 'fail')}>
      <span className="verify-ico">{ok ? '✓' : '✗'}</span>
      <div style={{ flex: 1, minWidth: 0 }}>
        {ok
          ? t('hosts.wizard.depOk', { os: t('hosts.osOk'), lv: t('hosts.libvirtOk') })
          : t('hosts.wizard.depFail', { os: report.os?.ok ? t('hosts.osOk') : t('hosts.osFail'), lv: report.packages?.ok ? t('hosts.libvirtOk') : t('hosts.libvirtFail') })}
        {report.simulated && <div className="report-detail">{t('hosts.simNote')}</div>}
        <div className="report-row" style={{ marginTop: 8 }}>
          <span className="report-label">{t('hosts.os')}</span>
          <div className="report-value">
            <strong>{report.os?.detected || '-'}</strong>
            <span className={'badge ' + (report.os?.ok ? 'badge-success' : 'badge-failed')}>{report.os?.ok ? t('hosts.osOk') : t('hosts.osFail')}</span>
          </div>
        </div>
        <div className="report-row">
          <span className="report-label">{t('hosts.deps')}</span>
          <div className="report-value">
            <div className="chip-row">
              {(report.packages?.installed || []).map((b) => (
                <span key={b} className="chip chip-ok">{b}</span>
              ))}
              {(report.packages?.missing || []).map((b) => (
                <span key={b} className="chip chip-bad">{b}</span>
              ))}
            </div>
          </div>
        </div>
        <div className="report-row">
          <span className="report-label">{t('hosts.service')}</span>
          <div className="report-value">
            <span className={'badge ' + (report.libvirtd?.active ? 'badge-success' : 'badge-failed')}>
              {report.libvirtd?.active ? t('hosts.serviceActive') : t('hosts.serviceDown')}
            </span>
            <span className="report-detail">{report.libvirtd?.detail}</span>
          </div>
        </div>
        <div className="report-row">
          <span className="report-label">{t('hosts.kvm')}</span>
          <div className="report-value">
            <span className={'badge ' + (report.kvm?.present ? 'badge-success' : 'badge-failed')}>
              {report.kvm?.present ? t('hosts.kvmYes') : t('hosts.kvmNo')}
            </span>
            <span className="report-detail">{report.kvm?.detail}</span>
          </div>
        </div>
      </div>
    </div>
  )
}