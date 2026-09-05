import { test } from 'node:test'
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

// Node strips types; it does not check them. This suite is the only thing that makes the
// annotations in this package load-bearing rather than decorative. It runs before there is
// any engine code to check, on purpose -- so no module is ever written unchecked.

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const tscBin = join(packageRoot, 'deps', 'node_modules', 'typescript', 'bin', 'tsc')

test('the pinned typescript is reachable under deps', () => {
  assert.ok(
    existsSync(tscBin),
    `${tscBin} is absent.\n` +
      'The dependency payload lives in deps/node_modules. Run brewery/node/restore-node.ps1 to restore it.',
  )
})

test('src and tests typecheck clean under the pinned tsconfig', () => {
  const result = spawnSync(process.execPath, [tscBin, '--noEmit', '--pretty', 'false'], {
    cwd: packageRoot,
    encoding: 'utf8',
  })

  assert.equal(result.error, undefined, `could not run tsc: ${String(result.error)}`)

  const diagnostics = `${result.stdout}${result.stderr}`.trim()
  assert.equal(
    result.status,
    0,
    diagnostics.length > 0
      ? `tsc --noEmit reported errors:\n${diagnostics}`
      : `tsc --noEmit exited ${String(result.status)} with no diagnostics`,
  )
})
