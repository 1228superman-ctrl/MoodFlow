import assert from 'node:assert/strict'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { runAnalysis } from './probe.mjs'

const failures = [
  ['usage_limit', { code: 'subscription_sharing_usage_limit_exceeded' }],
  ['offline', { code: 'ENETUNREACH' }],
  ['authorization', { status: 401, code: 'invalid_token' }],
]

for (const [reason, simulatedError] of failures) {
  test('T10 simulated ' + reason + ' preserves raw data and creates no summary', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'moodflow-'))
    try {
      let savedBeforeRequest
      const state = await runAnalysis(folder, async input => {
        const [raw] = await readdir(folder)
        assert.match(raw, /\.raw\.json$/)
        savedBeforeRequest = await readFile(join(folder, raw))
        assert.equal(JSON.parse(input).source, 'simulation')
        throw Object.assign(new Error('simulated provider failure'), simulatedError)
      })
      assert.deepEqual(state, { id: state.id, status: 'failed', reason })
      assert.deepEqual(await readFile(join(folder, state.id + '.raw.json')), savedBeforeRequest)
      const persisted = JSON.parse(await readFile(join(folder, state.id + '.result.json'), 'utf8'))
      assert.deepEqual(persisted, state)
      assert.equal(Object.hasOwn(persisted, 'summary'), false)
      assert.deepEqual((await readdir(folder)).sort(),
        [state.id + '.raw.json', state.id + '.result.json'].sort())
    } finally {
      await rm(folder, { recursive: true, force: true })
    }
  })
}
