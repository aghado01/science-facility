Launch now follows the installed executable. Version lists are evidence, not a gate you have to bump before a live turn.

**Default:** omit `supported_versions` on the integration profile and `expected_version` on the host binding. Readiness records whatever `--version` (or the native stream) says. A Claude 2.1.232 box just runs.

**Optional pin:** if you _do_ set those fields, drift still fails closed. That path stays for fixtures and for anyone who wants a lock. Your configs will not use it.

**Adapter `verified_versions`:** still names what the fixture checked (`2.1.226`, `0.147.0`). It no longer blocks registry load or event projection. `assertApplicationVersion()` remains an explicit evidence query; live projection does not call it.

`NATIVE_APPLICATION_VERSION_MISMATCH` is unchanged: if one turn sees two different versions, that is still a real fault.

W2 profiles should ship with no version pins. Bounded fixtures can keep their labelled versions; live-verified claims just name the version that was observed.
