import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { mkdir, open, rename, unlink } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const fixture = Object.freeze({
  source: 'simulation',
  samples: [
    { time: '08:45', heartRateBpm: 68, hrvSdnnMs: 45 },
    { time: '08:49', heartRateBpm: 95, hrvSdnnMs: 38 },
  ],
  sleepHours: 7,
  userLabel: '赶路，心情平静',
})

export function classify(error) {
  if (['subscription_sharing_usage_limit_exceeded', 'subscription_sharing_usage_unavailable',
    'rate_limit_exceeded', 'insufficient_quota'].includes(error.code) || error.status === 429) {
    return 'usage_limit'
  }
  if (['reauth_required', 'invalid_grant', 'invalid_token', 'permission_required',
    'not_connected', 'token_sharing_disabled', 'sharing_disabled', 'invalid_refresh_token',
    'token_expired', 'refresh_token_expired', 'refresh_token_invalidated',
    'chatpass_v2_scope_not_authorized', 'chatpass_v2_invalid_authorization_context'].includes(error.code)
    || [401, 403].includes(error.status)) return 'authorization'
  if (['ENETUNREACH', 'ECONNREFUSED', 'ENOTFOUND', 'network_error',
    'connection_error', 'request_timeout'].includes(error.code)
    || error.name === 'TimeoutError' || error.name === 'APIConnectionError') return 'offline'
  return 'other'
}

async function writeNew(path, value) {
  const handle = await open(path, 'wx', 0o600)
  try {
    await handle.writeFile(JSON.stringify(value, null, 2) + '\n')
    await handle.sync()
  } finally {
    await handle.close()
  }
}

export async function runAnalysis(folder, infer) {
  await mkdir(folder, { recursive: true })
  const id = randomUUID()
  const raw = join(folder, id + '.raw.json')
  const result = join(folder, id + '.result.json')
  await writeNew(raw, { id, createdAt: new Date().toISOString(), ...fixture })
  let state
  try {
    const text = await infer(JSON.stringify(fixture))
    if (typeof text !== 'string' || !text.trim()) throw new Error('Empty completed response')
    state = { id, status: 'completed', summary: text.trim() }
  } catch (error) {
    state = { id, status: 'failed', reason: classify(error) }
  }
  const temporary = result + '.tmp'
  try {
    await writeNew(temporary, state)
    await rename(temporary, result)
  } finally {
    await unlink(temporary).catch(error => {
      if (error.code !== 'ENOENT') throw error
    })
  }
  return state
}

function dpapi(operation, bytes) {
  const script = readFileSync(fileURLToPath(new URL('./dpapi.ps1', import.meta.url)), 'utf8')
  const command = `& { ${script} } -Operation ${operation}`
  const answer = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', command], {
    input: Buffer.from(bytes).toString('base64'), encoding: 'utf8', windowsHide: true, timeout: 15000,
  })
  if (answer.status !== 0 || !answer.stdout.trim()) throw new Error('Windows DPAPI is unavailable')
  return Buffer.from(answer.stdout.trim(), 'base64')
}

async function main() {
  const [command, devkit, folderArg] = process.argv.slice(2)
  if (command === 'check-dpapi') {
    const plaintext = 'simulated-non-credential'
    const encrypted = dpapi('protect', plaintext)
    if (encrypted.includes(plaintext) || dpapi('unprotect', encrypted).toString() !== plaintext) {
      throw new Error('DPAPI round trip failed')
    }
    console.log('PASS: Windows DPAPI CurrentUser round trip using a synthetic value')
    return
  }
  if (!['sign-in', 'analyze', 'disconnect'].includes(command) || !devkit || !folderArg) {
    throw new Error('Usage: node ai/probe.mjs sign-in|analyze|disconnect <DevKit directory> <local data directory>')
  }
  const { createChatGPT } = await import(pathToFileURL(resolve(devkit, 'packages/local/dist/index.js')))
  const folder = resolve(folderArg)
  const client = createChatGPT({
    appId: 'moodflow-validation',
    appName: 'MoodFlow Validation',
    redirectPort: 0,
    sendHostId: true,
    storageDir: join(folder, 'auth'),
    credentialEncryption: {
      id: 'windows-dpapi-current-user-v1',
      isAvailable: () => process.platform === 'win32',
      encrypt: text => dpapi('protect', text),
      decrypt: bytes => dpapi('unprotect', bytes).toString('utf8'),
    },
  })
  if (command === 'sign-in') {
    const session = await client.signIn({ signal: AbortSignal.timeout(240000) })
    const errorCode = session.error?.code
    console.log(JSON.stringify({ status: session.status, sharing: session.sharing, errorCode }))
    if (!session.sharing) process.exitCode = 1
    return
  }
  if (command === 'disconnect') {
    await client.disconnect()
    console.log('Local session disconnected.')
    return
  }
  const result = await runAnalysis(join(folder, 'requests'), async input => {
    const session = await client.getSession()
    if (!session.sharing) throw Object.assign(new Error(), { code: 'reauth_required' })
    const signal = AbortSignal.timeout(60000)
    const [model] = await client.listModels({ signal })
    if (!model) throw new Error('No available model')
    const response = await client.streamResponse({
      model: model.slug, signal, input,
      instructions: '用两句中文说明虚构数据里的变化和一个可能的非情绪原因，不做医学诊断。',
    })
    return response.text
  })
  console.log(JSON.stringify(result))
  if (result.status !== 'completed') process.exitCode = 1
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    const code = typeof error.code === 'string' && /^[\w.-]{1,80}$/.test(error.code) ? error.code : undefined
    console.error('Probe stopped.', JSON.stringify({ reason: classify(error), code, status: error.status }))
    process.exitCode = 1
  })
}
