Proposed tree: a core/ folder of small modules, not one nushell-mcp-core. NU_LIB_DIRS stays modules/, so imports are use core/census, later use core/capture. Overlay for the agent is unchanged.

mcp/nushell-mcp/
config.nu
modules/
core/
census/
mod.nu # NEW — pure in-hand; no par, no jobs
capture/ # later, with xq — not this cut
mod.nu
par/
mod.nu # use core/census [shape]
policy.json
jobs/
mod.nu # use core/census [shape "meta stamp"]; use par _
dataspection/
mod.nu # façade: export use core/census _; use jobs \*; use par ["par cap"]
xq/ # later
mod.nu
rg/ # later
mod.nu
gh/ # later
mod.nu
nu-skills/
nu-modules/
argx/ # unchanged
…

census/mod.nu is one module (one export set) because Nushell will not share private helpers across files. It therefore contains more than jobs needs: shape, shape each, meta, meta stamp, plus schema, spine, preview, page. That is packaging, not a claim that schema is a layer-wide primitive.

Who imports what

core/census core/capture (later)
▲ ▲ ▲ ▲ ▲
│ │ │ │ │
par jobs dataspection xq rg
▲ ▲ ▲
│ │ │
└──┬─┘ │
│ │
dataspection xq façade
▲
read

┌───────────────────┬─────────────────────────────────────────────────────┬─────────────────────────────────────────────────────┐
│ Module │ Module-scope use │ Exports │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ core/census │ nothing in-layer │ shape, shape each, schema, spine, preview, page, │
│ │ │ meta, meta stamp │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ par │ core/census [shape] │ par, par budget, par cap, par emit │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ jobs │ core/census [shape "meta stamp"], par _ │ jobs _ (and later jobs fetch) │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ dataspection │ export use core/census _, jobs _, par ["par cap"] │ same agent surface as today, plus read │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ core/capture ( │ nothing in-layer │ unbounded {stdout, stderr, exit_code, elapsed} │
│ later) │ │ │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ xq (later) │ core/capture, jobs _, par ["par cap"] │ --wrapped xq (quarantine) │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ rg (later) │ core/capture, core/census (spine/shape), jobs _, │ --wrapped rg │
│ │ par ["par cap"] │ │
├───────────────────┼─────────────────────────────────────────────────────┼─────────────────────────────────────────────────────┤
│ gh (later) │ xq (ordinary terminal), not capture │ identity + xq envelope │
└───────────────────┴─────────────────────────────────────────────────────┴─────────────────────────────────────────────────────┘

par / jobs never use dataspection. rg never use xq (the façade). That is the whole point of core/ as a folder.

Overlay (config.nu)

Still the MCP experience, not DI into definitions:

use nu-skills _
use nu-modules _
use par _
use jobs _
use dataspection \*

# later: use xq _; use rg _

Do not use core/census \* here. Agents keep:

use dataspection \*
$x | shape
$x | preview
$x | read

nu-modules will list core/census; document it as a dependency module, not an agent surface.

Why not a single nushell-mcp-core

The first cut is census/stamp. The next extract is process capture — a different core, same folder. One mod.nu named after the package would have to swallow both or be renamed on the second split.
