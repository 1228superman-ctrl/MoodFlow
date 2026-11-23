import test from 'node:test'
import assert from 'node:assert/strict'
import { summarizeDay } from './probe.mjs'

const fixture = {
  schema: 1,
  id: '905371CF-9ED7-40FA-8C80-CF72DBB99CF6',
  day: '2026-11-23',
  eventCount: 2,
  moodCounts: { 平静: 1, 紧张: 1 },
  averageBpm: 70,
  recording: 'private-audio',
  coordinates: [10, 20],
}
const bytes = value => Buffer.from(JSON.stringify(value))

test('summary forwards only reviewed aggregate fields and returns the matching task', async () => {
  const result = await summarizeDay(bytes(fixture), async input => {
    assert.deepEqual(JSON.parse(input), { day: fixture.day, eventCount: 2, moodCounts: fixture.moodCounts, averageBpm: 70 })
    return '模拟完成事件。'
  })
  assert.deepEqual(result, { schema: 1, id: fixture.id, day: fixture.day, status: 'completed', summary: '模拟完成事件。' })
})

test('quota failure creates a retryable result without a summary', async () => {
  const original = bytes(fixture)
  const result = await summarizeDay(original, async () => {
    throw Object.assign(new Error('simulated'), { code: 'subscription_sharing_usage_limit_exceeded' })
  })
  assert.deepEqual(result, { schema: 1, id: fixture.id, day: fixture.day, status: 'failed', reason: 'usage_limit' })
  assert.deepEqual(original, bytes(fixture))
})

test('invalid and empty results cannot be imported as completed summaries', async () => {
  await assert.rejects(summarizeDay(bytes({ ...fixture, moodCounts: { 平静: 3 } }), async () => 'unexpected'))
  const result = await summarizeDay(bytes(fixture), async () => ' ')
  assert.equal(result.status, 'failed')
  assert.equal(Object.hasOwn(result, 'summary'), false)
})
