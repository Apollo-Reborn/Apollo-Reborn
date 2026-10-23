# iPad Layout beta invitation

The Interface switch keeps the existing `IPadPaneLayout` key and launch-time
installation contract. Its visible name is **iPad Layout**, with an inline Beta
badge. Turning it on or off still requires reopening Apollo.

The welcome card runs on supported iPads (iPadOS 18+) independently of the
layout gate. It waits for an active key window and for other launch modals to
finish. `IPadLayoutWelcomeSeen` is saved only after a real presentation commits.
Dismissal or **Try Later** leaves the layout off and does not repeat the prompt.
**Try Now** saves the layout choice and explains how to quit and reopen Apollo.
It never changes the running layout global or rebuilds the active hierarchy.

Already-enabled users and users who explicitly change the Interface switch
consume the invitation too: switching back must not invite them again.

## Debug replay

With FLEX Debugging enabled, Apollo Reborn's Advanced section has **Preview iPad
Layout Welcome**. It replays the card without clearing first-run history or
changing the layout just by opening it. The card's Try Now action remains real.

The simulator's existing scoped command bridge also accepts:

- `ipadwelcome`: replay the card.
- `ipadwelcomereset`: clear only the invitation marker for cold-launch QA.
  The real layout switch must be off to exercise an automatic first invitation.

Use the command file and notification configured for the target simulator;
do not use the global default pair when other Apollo sessions are running.

## Manual checks

- Unseen, layout off: cold launch shows one invitation after launch UI settles.
- Try Later or dismissal: layout stays off; subsequent launches stay quiet.
- Try Now: saved choice is on, current hierarchy is unchanged until reopening;
  reopening installs iPad Layout and does not repeat the invitation.
- Existing opt-in, manual opt-out, iPhone, unsupported iPadOS: no invitation.
- Debug replay, portrait, landscape, larger text: image, labels and both choices
  remain accessible; oversized content scrolls within the card.
