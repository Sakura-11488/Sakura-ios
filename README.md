# Sakura iOS — historical source snapshot

This repository preserves an earlier **Next.js + Capacitor** version of Sakura, including an Xcode project and native iOS integrations. It is historical platform source, not the source of the current Expo website or evidence of a current App Store release.

Current shared application development belongs in [Sakura-11488/Sakura](https://github.com/Sakura-11488/Sakura). The live application is available at [sakuraonseeker.com/app/](https://sakuraonseeker.com/app/).

## What is in this checkout

| Path | Contents |
| --- | --- |
| `src/` | Earlier Next.js application |
| `ios/` | Capacitor iOS project and native plugins |
| `capacitor.config.ts` | Historical wrapper configuration |
| `backend/` | Earlier backend source |
| `programs/` | Earlier on-chain source |
| `.github/workflows/ios-build.yml` | Signing, archive, and optional TestFlight workflow |

The package manifest declares version `1.8.3`. That value and the presence of a workflow do not identify the current live release. Embedded program IDs or configuration also do not establish what is deployed.

## Build and release status

The existing scripts use Next.js, and Capacitor expects its historical web export. Their presence is not a claim that this snapshot builds successfully with today's toolchain or matches the current product. Dependencies, native integrations, signing, and device behavior need verification before any release.

The existing iOS workflow can use signing credentials, produce an IPA, and optionally upload to TestFlight. It can run manually or on selected source changes to `main`/`master`. Do not dispatch it as a documentation check. README-only changes are outside its configured push paths.

## Direction for future iOS work

1. Reconcile useful native integrations with the shared Expo application, preserving user data and web/native module boundaries.
2. Establish reproducible builds, supported toolchains, and checks on real devices.
3. Verify signing, installation, updates, recovery, and release provenance before distributing a new build.

Do not copy this retired UI over the current website. A platform release and a website release have separate verification and approval requirements.

## Related work

- [Sakura shared application](https://github.com/Sakura-11488/Sakura)
- [Website hosting](https://github.com/millw14/sakura-web)
- [Sakura Rooms and perps research](https://github.com/Sakura-11488/sakura-perps) — invite-only paper beta, no real funds
- [Desktop distribution documentation](https://github.com/Sakura-11488/Sakura-pc)

Existing [Copyright](COPYRIGHT.md), [Privacy](PRIVACY.md), and [Terms](TERMS.md) documents are retained without amendment. Their historical service descriptions are not a release manifest or a new license grant.
