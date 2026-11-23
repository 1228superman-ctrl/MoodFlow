import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
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
  const [command, devkit, folderArg, requestPath] = process.argv.slice(2)
  if (command === 'check-dpapi') {
    const plaintext = 'simulated-non-credential'
    const encrypted = dpapi('protect', plaintext)
    if (encrypted.includes(plaintext) || dpapi('unprotect', encrypted).toString() !== plaintext) {
      throw new Error('DPAPI round trip failed')
    }
    console.log('PASS: Windows DPAPI CurrentUser round trip using a synthetic value')
    return
  }
  if (!['sign-in', 'analyze', 'disconnect', 'summarize'].includes(command) || !devkit || !folderArg
    || (command === 'summarize' && !requestPath)) {
    console.error('Usage: node ai/probe.mjs sign-in|analyze|disconnect|summarize <DevKit> <local data> [request.json]')
    process.exitCode = 1
    return
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
  async function infer(input, instructions) {
    const session = await client.getSession()
    if (!session.sharing) throw Object.assign(new Error(), { code: 'reauth_required' })
    const signal = AbortSignal.timeout(60000)
    const [model] = await client.listModels({ signal })
    if (!model) throw new Error('No available model')
    const response = await client.streamResponse({
      model: model.slug, signal, input, instructions,
    })
    return response.text
  }
  if (command === 'summarize') {
    const source = resolve(requestPath)
    const result = await summarizeDay(await readFile(source), infer)
    const destination = join(dirname(source), `moodflow-${result.day}-result-${randomUUID().slice(0, 8)}.json`)
    await writeNew(destination, result)
    console.log(JSON.stringify({ status: result.status, reason: result.reason, file: destination }))
    if (result.status !== 'completed') process.exitCode = 1
    return
  }
  const result = await runAnalysis(join(folder, 'requests'), async input => {
    return infer(input, '用两句中文说明虚构数据里的变化和一个可能的非情绪原因，不做医学诊断。')
  })
  console.log(JSON.stringify(result))
  if (result.status !== 'completed') process.exitCode = 1
}

export async function summarizeDay(bytes, infer) {
  if (bytes.length > 50_000) throw new Error('Invalid MoodFlow summary request')
  const request = JSON.parse(bytes.toString('utf8'))
  const { schema, id, day, eventCount, moodCounts, averageBpm, averageHrv, sleepHours } = request
  const moods = new Set(['愉快', '平静', '兴奋', '紧张', '低落', '疲惫'])
  const validCount = number => Number.isSafeInteger(number) && number >= 0
  const validMetric = (number, max) => number == null || (Number.isFinite(number) && number >= 0 && number <= max)
  if (schema !== 1 || typeof id !== 'string' || !/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(id)
    || typeof day !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(day) || !validCount(eventCount) || eventCount === 0
    || !moodCounts || Array.isArray(moodCounts) || typeof moodCounts !== 'object'
    || Object.entries(moodCounts).some(([label, count]) => !moods.has(label) || !validCount(count))
    || Object.values(moodCounts).reduce((sum, count) => sum + count, 0) > eventCount
    || !validMetric(averageBpm, 300) || !validMetric(averageHrv, 5000) || !validMetric(sleepHours, 24)) {
    throw new Error('Invalid MoodFlow summary request')
  }
  try {
    const text = await infer(JSON.stringify({ day, eventCount, moodCounts, averageBpm, averageHrv, sleepHours }),
      '用简洁中文总结当天的用户情绪标记和可用指标，给出一个温和的自我观察问题。区分已记录事实及可能解释，不推测缺失的数据或作医学诊断。')
    if (typeof text !== 'string' || !text.trim()) throw new Error('Empty completed response')
    return { schema, id, day, status: 'completed', summary: text.trim() }
  } catch (error) {
    return { schema, id, day, status: 'failed', reason: classify(error) }
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    const code = typeof error.code === 'string' && /^[\w.-]{1,80}$/.test(error.code) ? error.code : undefined
    console.error('Probe stopped.', JSON.stringify({ reason: classify(error), code, status: error.status }))
    process.exitCode = 1
  })
}
