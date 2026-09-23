# Before filing upstream

From the Kubernetes contributor guide (`kubernetes/community/contributors/guide`),
the `kubernetes/kubernetes` bug template, and the SIG OWNERS files. Read
2026-09-23.

## The issue

- [ ] **Reproduce it yourself** with `docs/minimal-repro.sh`, on your own
      machine, and keep the output. The security guide rejects AI-assisted
      reports the reporter has not reproduced and validated; moderation closes
      low-quality automated content. The reporter stands behind every claim and
      every code pointer.
- [ ] **Read the code pointers yourself** (the links in "Anything else") and be
      ready to explain them without help.
- [ ] **Edit the text into your own voice.** The draft is a starting point.
- [ ] **Search for duplicates again** on the day of filing:
      `is:issue exec truncat`, `kubectl cp unexpected EOF`, `cri-streaming`.
      Known and closed: #60140, #124571.
- [ ] **Not a security issue**, so the public tracker is correct. Say so in one
      line so nobody moves it to private disclosure.
- [ ] **Use the Bug Report form**: What happened / What did you expect / How can
      we reproduce it / Anything else / Kubernetes version / Cloud provider /
      OS version / Install tools / CRI and version / Related plugins. The
      template adds `kind/bug`.
- [ ] **Supported release.** Only N, N-1, N-2 are supported (1.35–1.37 today).
      The draft's headline numbers are from v1.37.0 with kubectl v1.37.0.
- [ ] **SIG labels** as a comment, each command on its own line at the start:

      /sig node
      /sig api-machinery
      /sig cli

      | component | SIG | OWNERS include |
      |---|---|---|
      | `k8s.io/cri-streaming` | node | dims, mikebrow, saschagrunert, aojea, seans3, liggitt |
      | `apimachinery` upgrade-aware proxy | api-machinery | |
      | `client-go` remotecommand, `kubectl exec` | cli | aojea, liggitt, seans3 |

- [ ] **Comment on #60140** with one line linking the new issue. That thread
      still has the audience.
- [ ] **Short AI note** in the issue, once you have reproduced it.

## The follow-up issues

- [ ] Only after the umbrella is triaged (`triage/accepted`) or a maintainer
      agrees with the split. Link the umbrella from each.

## Before any PR

- [ ] **CLA signed** with the email your commits use. The guide suggests a PR to
      `kubernetes-sigs/contributor-playground`.
- [ ] **One logical change per PR**, small. The streaming-server fix and the
      apiserver proxy fix are separate PRs.
- [ ] `make verify`, `make test`, `make test-integration` pass locally.
- [ ] **Tests** that fail without the fix. The streaming-server one can be a unit
      or integration test with a slow reader; no cluster needed.
- [ ] **PR description**: what, why, how it was tested; `fixes #N` in the body,
      never in commit messages; no `@mentions` in commit messages.
- [ ] **Release note** block filled in (user-visible behaviour change).
- [ ] **AI disclosure in the PR description**, e.g. "This PR was written in part
      with the assistance of generative AI." Mandatory.
- [ ] **No AI trailers** (`Co-authored-by`, `Assisted-by`, …) and no
      AI-written commit messages. Not allowed.
- [ ] **Answer reviews yourself, without AI tools.** PRs where the author does
      not engage directly are closed.
- [ ] **SIG Node** considers every kubelet/runtime change risky: show that
      interactive `exec -it`, `attach` and `port-forward` are unaffected.
