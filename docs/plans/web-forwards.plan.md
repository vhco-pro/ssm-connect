---
status: complete
status_description: "Local implementation complete: make test passed with 165 tests in 28 suites; native arm64 Debug build and artifact checks passed. Native UI, live HTTP/websocket, PAC controls/outage and key cleanup exercised; cached-menu profile refresh fixed. Browser SSO user-confirmed on 2026-10-13; working-day/DCV observation in progress. Fresh-Mac acceptance remains unverified. No Git publication."
description: "Independent SSH-over-SSM SOCKS and local forwards in the native macOS app."
spec: docs/specs/web-forwards.spec.md
goal: "Open internal web applications locally without launching or disrupting DCV."
priority: high
created: 2026-10-12
slug: web-forwards
lifecycle: transactional
---

# Plan: Web Forwards

## Context

The reference script has proven SSH over SSM, EC2 Instance Connect, SOCKS, local forwards,
PAC routing, browser SSO and websocket delivery from this Mac. The user authorized implementation
before the working-day/DCV observation; neither that observation nor the built-app manual check
is considered passed. The existing specification remains canonical.

## Dependencies

- Existing SwiftUI application and SSMConnectKit package, macOS 14 minimum.
- Pinned AWS SDK's AWSEC2InstanceConnect product; no AWS CLI runtime dependency.
- Bundled checksum-verified Session Manager plugin, plus macOS ssh and ssh-keygen.
- A host supporting EC2 Instance Connect and SSH, and SendSSHPublicKey IAM permission.

## Scope

Implement WF-1 through WF-13 in the macOS app. Do not modify DCV connection states,
system proxy settings, the reference script, remote host configuration or production resources.
Do not introduce workflow configuration. Windows and host-side web application provisioning
remain out of scope.

## Design

- ConnectionProfile holds an optional WebForwardsConfiguration. Missing block preserves legacy
  behavior; a missing SOCKS port defaults to 1080, while explicit null disables SOCKS.
- SSMService starts AWS-StartSSHSession separately from its unchanged DCV method.
- InstanceConnectService sends a fresh ed25519 public key with explicit authenticated credentials.
- SSHTunnel builds a shell-quoted ProxyCommand and explicit IPv4 loopback forwards. The session
  response is passed only via AWS_SSM_START_SESSION_RESPONSE in the process environment.
- Reuse the existing generic process spawner, tunnel handle and port probe. Require SSH-owned
  listeners before declaring the connection on; never kill an unidentified port occupant.
- WebForwardsStateMachine reuses authentication, EC2 resolution/start and SSM readiness services,
  but owns its task, SSH handle and key independently. Three reconnect attempts use five-second
  backoff and fresh keys. Stop cancels the worker; quit cleans up both DCV and web connections.
- PAC files live in Application Support. Internal suffix branches have no DIRECT fallback.
- The editor validates ports, uniqueness, suffixes and SSH/host inputs. Menu actions independently
  toggle forwards, open configured local paths, copy the PAC URL and reveal its file.

## Acceptance Criteria

- AC-1: stored legacy profile decodes without web forwards.
- AC-2: pure argument builder emits loopback SOCKS/local forwards without a session token.
- AC-3: mocked key generation, authorization, session start and spawn execute in order;
  authorization errors name SendSSHPublicKey.
- AC-4: web forwards start without launching DCV; DCV disconnect leaves SSH active.
- AC-5: unexpected exit reconnects with a fresh key; user stop does not reconnect.
- AC-6: each PAC suffix routes only through SOCKS, never a DIRECT fallback.
- AC-7: native profile/menu and local-browser workflow exercised; SSO user-confirmed. Fresh-Mac setup and the exact no-DCV-at-any-point sequence remain unverified.

## Implementation Phases

1. Profile block and legacy/default decoding tests.
2. SSH-specific SSM session method, transport, key lifecycle, validation and PAC tests.
3. EC2 key authorization and independent supervision, with connection-order and reconnect tests.
4. Editor/menu wiring and multiple quit-handler support; DCV independence and environment tests.
5. Documentation, make test and a native Debug app build.

## Test Plan

Use the existing Swift Testing framework and local test doubles. Focused suites are
ConnectionProfileCodableTests, SSMServiceTests, SSHTunnelTests and WebForwardsStateMachineTests.
Verify real local key generation/permissions without AWS access. Final gate: make test and
xcodebuild of the generated app project. No live AWS or DCV session is required by automated tests.

Manual follow-up: configure the built app, connect without DCV, complete browser SSO through
its PAC, open a local forward, then run a working-day coexistence observation alongside DCV.

## Implementation Order

Follow the phases above, validating each touched slice before the next. Do not publish Git
changes or treat pending manual checks as evidence.

## File Reference Summary

- Models/ConnectionProfile.swift: optional configuration and forward records.
- Services/SSMProviding.swift and SSMService.swift: SSH session API.
- Services/InstanceConnectProviding.swift: AWS-backed key authorization.
- Tunnel/SSHTunnel.swift and PluginProcess.swift: arguments, environment, key lifecycle and PAC.
- StateMachine/WebForwardsStateMachine.swift: independent connection and reconnect worker.
- Settings/ProfileEditorValidation.swift and ProfileEditorView.swift: configuration and validation.
- App/MenuContentView.swift, AppDelegate.swift and SSMConnectApp.swift: UI and lifecycle wiring.
- Existing test directories contain profile, transport and supervision acceptance tests.

## Open Questions

No implementation decision is awaiting user input. Native app and live transport checks are
recorded in specification sections 3.4 and 3.5. Browser SSO through the app PAC is user-confirmed.
A fresh-Mac setup, the exact no-DCV-at-any-point sequence and full working-day/DCV result remain unverified.

Implementation evidence is recorded in specification section 3.3. Automated AC-1 through AC-6
pass; AC-7 is partially verified, with fresh-Mac setup and its exact no-DCV sequence still pending. The Debug artifact is at
`.build/DerivedData/Build/Products/Debug/SSMConnect.app`. Its signature, plist, bundled plugin
and compiled web-forward symbols were checked. The tracked package lockfile is unchanged.

Follow-up verification is recorded in specification section 3.5: live DCV disconnect left both
web paths healthy, and DCV was reconnected for an ongoing one-minute stability observer. The
eleven-minute checkpoint passed with twelve healthy samples and no gaps; a full working day has
not completed. Interactive browser SSO was confirmed by the user on 2026-10-13. Observation logs
stay private and outside the repository.